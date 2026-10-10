import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/spacing.dart';
import 'update_controller.dart';

/// Wraps the signed-in shell: checks for updates on launch/resume and shows a
/// dismissible strip above it. [child] keeps its place in the tree either way.
class UpdateHost extends ConsumerStatefulWidget {
  const UpdateHost({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<UpdateHost> createState() => _UpdateHostState();
}

class _UpdateHostState extends ConsumerState<UpdateHost> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future.microtask(() => ref.read(updateProvider.notifier).check());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) ref.read(updateProvider.notifier).check();
  }

  @override
  Widget build(BuildContext context) {
    final visible = ref.watch(updateProvider.select((s) => s.visible));
    return Column(children: [
      if (visible) const Material(child: SafeArea(bottom: false, child: UpdateBanner())),
      // The banner already sits under the status bar; don't pad it twice.
      Expanded(child: MediaQuery.removePadding(context: context, removeTop: visible, child: widget.child)),
    ]);
  }
}

class UpdateBanner extends ConsumerWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(updateProvider);
    final info = s.info;
    if (info == null) return const SizedBox.shrink();
    final ctl = ref.read(updateProvider.notifier);
    final busy = s.progress != null;

    final String text;
    if (s.manualWindows) {
      text = r'Move the app to %LOCALAPPDATA%\VibeMobile to enable 1-click updates';
    } else if (s.error != null) {
      text = s.error!;
    } else {
      text = 'Update ${info.version} available${info.notes.isEmpty ? '' : ' - ${info.notes}'}';
    }

    return MaterialBanner(
      content: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(text, maxLines: 3, overflow: TextOverflow.ellipsis),
        if (busy) Padding(padding: const EdgeInsets.only(top: Spacing.sm), child: LinearProgressIndicator(value: s.progress)),
      ]),
      actions: [
        if (!busy) TextButton(onPressed: ctl.dismiss, child: const Text('Dismiss')),
        if (!busy && s.manualWindows)
          TextButton(
            onPressed: () async {
              final u = await ctl.manualUrl();
              if (u != null) await launchUrl(u, mode: LaunchMode.externalApplication);
            },
            child: const Text('Download'),
          )
        else if (!busy)
          TextButton(onPressed: ctl.install, child: Text(s.error != null ? 'Retry' : 'Update')),
      ],
    );
  }
}
