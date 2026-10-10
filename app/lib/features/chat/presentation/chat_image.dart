import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/platform.dart';
import '../../../core/providers.dart';
import '../../../core/spacing.dart';
import '../../../core/token_store.dart';
import '../../../core/widgets.dart';
import '../domain/chat_message.dart';
import '../domain/image_paths.dart';

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
  @override
  bool operator ==(Object other) => other is AttachmentImage && other.id == id;
  @override
  int get hashCode => Object.hash(AttachmentImage, id);
}

class SessionFileImage extends ChatImageSource {
  const SessionFileImage(this.sessionId, this.filePath);
  final String sessionId;
  final String filePath;
  @override
  String get path => '/sessions/$sessionId/image?path=${Uri.encodeQueryComponent(filePath)}';
  @override
  String get fileName => filePath.split('/').last;
  @override
  bool operator ==(Object other) => other is SessionFileImage && other.sessionId == sessionId && other.filePath == filePath;
  @override
  int get hashCode => Object.hash(sessionId, filePath);
}

/// Every image in a conversation, in chat order, each once. Mirrors what the
/// chat rows render: user + tool-result attachments, and image paths a finished
/// assistant reply mentions.
List<ChatImageSource> galleryFromMessages(List<ChatMessage> messages, String sessionId) {
  final out = <ChatImageSource>{};
  for (final m in messages) {
    switch (m.role) {
      case ChatRole.user || ChatRole.tool:
        out.addAll([for (final id in m.images) AttachmentImage(id)]);
      case ChatRole.assistant:
        if (!m.streaming) out.addAll([for (final p in extractImagePaths(m.text)) SessionFileImage(sessionId, p)]);
      default:
    }
  }
  return out.toList();
}

/// The conversation's images, so a tap on any chat image opens the viewer over
/// all of them. Provided once around the message list.
class ChatGallery extends InheritedWidget {
  const ChatGallery({super.key, required this.sources, required super.child});
  final List<ChatImageSource> sources;

  @override
  bool updateShouldNotify(ChatGallery old) => !listEquals(old.sources, sources);
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
              onTap: () {
                final all = context.getInheritedWidgetOfExactType<ChatGallery>()?.sources;
                final at = all?.indexOf(sources[i]) ?? -1;
                Navigator.of(context).push(sharedAxisRoute<void>(
                  at >= 0
                      ? ImageViewerScreen(creds: creds, sources: all!, initialIndex: at)
                      : ImageViewerScreen(creds: creds, sources: sources, initialIndex: i),
                ));
              },
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

/// Fullscreen slideshow of chat images: swipe, arrow buttons / keys, thumbnail
/// strip, pinch-zoom. Escape or a tap outside the image closes. Share on mobile;
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

  static const double _thumb = 56;

  final ScrollController _thumbs = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealThumb());
  }

  @override
  void dispose() {
    _pages.dispose();
    _thumbs.dispose();
    super.dispose();
  }

  void _go(int i) {
    if (i < 0 || i >= widget.sources.length) return;
    _pages.animateToPage(i, duration: Motion.base, curve: Motion.enter);
  }

  void _revealThumb() {
    if (!_thumbs.hasClients) return;
    final pos = _thumbs.position;
    final centre = _index * (_thumb + Spacing.sm) + _thumb / 2 - pos.viewportDimension / 2;
    _thumbs.animateTo(centre.clamp(0.0, pos.maxScrollExtent), duration: Motion.base, curve: Motion.enter);
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

  Widget _arrow(IconData icon, String tooltip, VoidCallback? onPressed) => IconButton(
        tooltip: tooltip,
        icon: Icon(icon),
        color: Colors.white,
        style: IconButton.styleFrom(backgroundColor: Colors.black54),
        onPressed: onPressed,
      );

  @override
  Widget build(BuildContext context) {
    final n = widget.sources.length;
    final primary = Theme.of(context).colorScheme.primary;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).maybePop(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _go(_index - 1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _go(_index + 1),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
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
          body: Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    PageView.builder(
                      controller: _pages,
                      itemCount: n,
                      onPageChanged: (i) {
                        setState(() => _index = i);
                        _revealThumb();
                      },
                      // Tap outside the image closes; the image absorbs its own taps.
                      itemBuilder: (_, i) => GestureDetector(
                        onTap: () => Navigator.of(context).maybePop(),
                        child: InteractiveViewer(
                          maxScale: 8,
                          child: Center(
                            child: GestureDetector(
                              onTap: () {},
                              child: _network(
                                widget.creds,
                                widget.sources[i],
                                fit: BoxFit.contain,
                                onError: (_, _, _) => const Icon(Icons.broken_image_outlined, color: Colors.white54, size: 48),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (n > 1 && _index > 0)
                      Positioned(
                        left: Spacing.sm,
                        top: 0,
                        bottom: 0,
                        child: Center(child: _arrow(Icons.chevron_left, 'Previous', () => _go(_index - 1))),
                      ),
                    if (n > 1 && _index < n - 1)
                      Positioned(
                        right: Spacing.sm,
                        top: 0,
                        bottom: 0,
                        child: Center(child: _arrow(Icons.chevron_right, 'Next', () => _go(_index + 1))),
                      ),
                  ],
                ),
              ),
              if (n > 1)
                SafeArea(
                  top: false,
                  child: SizedBox(
                    height: _thumb + 2 * Spacing.sm,
                    child: ListView.separated(
                      controller: _thumbs,
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: Spacing.sm),
                      itemCount: n,
                      separatorBuilder: (_, _) => const SizedBox(width: Spacing.sm),
                      itemBuilder: (_, i) => GestureDetector(
                        key: ValueKey('viewer-thumb-$i'),
                        onTap: () => _go(i),
                        child: AnimatedContainer(
                          duration: Motion.fast,
                          width: _thumb,
                          height: _thumb,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(Radii.sm),
                            border: Border.all(color: i == _index ? primary : Colors.transparent, width: 2),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(Radii.sm),
                            child: _network(
                              widget.creds,
                              widget.sources[i],
                              size: _thumb,
                              onError: (_, _, _) => const Icon(Icons.broken_image_outlined, color: Colors.white54),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
