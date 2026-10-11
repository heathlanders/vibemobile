import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/spacing.dart';
import 'update_controller.dart';

/// Wraps the signed-in shell: checks for updates on launch/resume and asks
/// "Update now?" in a dialog when one is found.
class UpdateHost extends ConsumerStatefulWidget {
  const UpdateHost({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<UpdateHost> createState() => _UpdateHostState();
}

class _UpdateHostState extends ConsumerState<UpdateHost> with WidgetsBindingObserver {
  // Desktop apps stay open for days and rarely see a "resumed" event, so also
  // re-check hourly while running.
  Timer? _hourly;
  bool _asking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Ask once per newly found update; Later (dismiss) and Settings' "Check for updates" re-arm it.
    ref.listenManual(updateProvider.select((s) => s.visible), (was, now) {
      if (now && was != true) _ask();
    });
    Future.microtask(() => ref.read(updateProvider.notifier).check());
    _hourly = Timer.periodic(const Duration(hours: 1), (_) => ref.read(updateProvider.notifier).check());
  }

  @override
  void dispose() {
    _hourly?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) ref.read(updateProvider.notifier).check();
  }

  Future<void> _ask() async {
    if (_asking || !mounted) return;
    _asking = true;
    await showDialog<void>(context: context, barrierDismissible: false, builder: (_) => const UpdateDialog());
    _asking = false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class UpdateDialog extends ConsumerWidget {
  const UpdateDialog({super.key});

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
      text = info.notes.isEmpty ? 'Update now?' : '${info.notes}\n\nUpdate now?';
    }

    return AlertDialog(
      title: Text('Update ${info.version} available'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(text),
        if (busy) Padding(padding: const EdgeInsets.only(top: Spacing.md), child: LinearProgressIndicator(value: s.progress)),
      ]),
      actions: [
        if (!busy)
          TextButton(
            onPressed: () {
              ctl.dismiss();
              Navigator.pop(context);
            },
            child: const Text('Later'),
          ),
        if (!busy && s.manualWindows)
          FilledButton(
            onPressed: () async {
              final u = await ctl.manualUrl();
              if (u != null) await launchUrl(u, mode: LaunchMode.externalApplication);
            },
            child: const Text('Download'),
          )
        else if (!busy)
          FilledButton(
            onPressed: () async {
              await ctl.install();
              // Installer handed off: close. Otherwise stay open to show the error (Retry) or Download.
              final after = ref.read(updateProvider);
              if (context.mounted && after.error == null && !after.manualWindows) Navigator.pop(context);
            },
            child: Text(s.error != null ? 'Retry' : 'Update now'),
          ),
      ],
    );
  }
}
