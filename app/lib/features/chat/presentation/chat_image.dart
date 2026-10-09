import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/platform.dart';
import '../../../core/providers.dart';
import '../../../core/spacing.dart';
import '../../../core/token_store.dart';

/// Where a chat image comes from (proposal 33). Both are bearer-gated daemon
/// routes: a stored attachment (user upload / tool result), or an image file in
/// the session's project that Claude mentioned.
sealed class ChatImageSource {
  const ChatImageSource();
  String get path; // daemon route, relative to Creds.baseUrl
  String get fileName;
}

class AttachmentImage extends ChatImageSource {
  const AttachmentImage(this.id);
  final String id;
  @override
  String get path => '/attachments/$id';
  @override
  String get fileName => id;
}

class SessionFileImage extends ChatImageSource {
  const SessionFileImage(this.sessionId, this.filePath);
  final String sessionId;
  final String filePath;
  @override
  String get path => '/sessions/$sessionId/image?path=${Uri.encodeQueryComponent(filePath)}';
  @override
  String get fileName => filePath.split('/').last;
}

Widget _network(Creds creds, ChatImageSource s, {double? size, BoxFit fit = BoxFit.cover, ImageErrorWidgetBuilder? onError}) =>
    Image.network(
      // Paired URLs may end in '/'; '//attachments/…' 404s on the daemon.
      '${creds.baseUrl.replaceFirst(RegExp(r'/+$'), '')}${s.path}',
      headers: {'authorization': 'Bearer ${creds.token}'},
      width: size,
      height: size,
      fit: fit,
      errorBuilder: onError,
    );

/// A wrap of tappable thumbnails; tap opens [ImageViewerScreen] on that image.
/// [hideOnError] drops a thumb that fails to load (a mentioned path that isn't a
/// real image in the project) instead of showing a broken-image tile.
class ChatImageStrip extends StatelessWidget {
  const ChatImageStrip({
    super.key,
    required this.creds,
    required this.sources,
    this.size = 140,
    this.hideOnError = false,
    this.alignment = WrapAlignment.start,
  });
  final Creds creds;
  final List<ChatImageSource> sources;
  final double size;
  final bool hideOnError;
  final WrapAlignment alignment;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 6,
        runSpacing: 6,
        alignment: alignment,
        children: [
          for (var i = 0; i < sources.length; i++)
            GestureDetector(
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => ImageViewerScreen(creds: creds, sources: sources, initialIndex: i),
              )),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(Radii.sm),
                child: _network(
                  creds,
                  sources[i],
                  size: size,
                  onError: (_, _, _) => hideOnError
                      ? const SizedBox.shrink()
                      : Container(width: size, height: size, color: Colors.black12, child: const Icon(Icons.broken_image_outlined)),
                ),
              ),
            ),
        ],
      );
}

/// Fullscreen, swipeable, pinch-zoomable view of chat images. Share on mobile;
/// save to Downloads on desktop.
class ImageViewerScreen extends StatefulWidget {
  const ImageViewerScreen({super.key, required this.creds, required this.sources, this.initialIndex = 0});
  final Creds creds;
  final List<ChatImageSource> sources;
  final int initialIndex;

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<ImageViewerScreen> {
  late final PageController _pages = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _export() async {
    final messenger = ScaffoldMessenger.of(context);
    final s = widget.sources[_index];
    try {
      final res = await dioFor(widget.creds).get<List<int>>(s.path, options: Options(responseType: ResponseType.bytes));
      if (res.statusCode != 200 || res.data == null) throw Exception('HTTP ${res.statusCode}');
      var name = s.fileName;
      if (!name.contains('.')) name = '$name.${(res.headers.value('content-type') ?? 'image/png').split('/').last}';
      final dir = isMobile ? await getTemporaryDirectory() : (await getDownloadsDirectory() ?? await getTemporaryDirectory());
      final file = File('${dir.path}${Platform.pathSeparator}$name');
      await file.writeAsBytes(res.data!);
      if (isMobile) {
        await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
      } else {
        messenger.showSnackBar(SnackBar(content: Text('Saved to ${file.path}')));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not export image: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.sources.length;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(n > 1 ? '${_index + 1} / $n' : widget.sources[_index].fileName),
        actions: [
          IconButton(
            tooltip: isMobile ? 'Share' : 'Save to Downloads',
            icon: Icon(isMobile ? Icons.share_outlined : Icons.download_outlined),
            onPressed: _export,
          ),
        ],
      ),
      body: PageView.builder(
        controller: _pages,
        itemCount: n,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (_, i) => InteractiveViewer(
          maxScale: 8,
          child: Center(
            child: _network(
              widget.creds,
              widget.sources[i],
              fit: BoxFit.contain,
              onError: (_, _, _) => const Icon(Icons.broken_image_outlined, color: Colors.white54, size: 48),
            ),
          ),
        ),
      ),
    );
  }
}
