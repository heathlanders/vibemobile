import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/spacing.dart';
import '../../../core/theme.dart';
import '../../../core/token_store.dart';
import '../../update/domain/update_info.dart';
import '../data/admin_api.dart';

/// "Pair a new device" (ADR 0029): mints a one-time code on the server and
/// shows it with the three setup steps, so a new phone or PC needs nothing
/// from the server's terminal.
class PairDeviceDialog extends StatefulWidget {
  const PairDeviceDialog({super.key, required this.creds, required this.api});
  final Creds creds;
  final AdminApi api;

  @override
  State<PairDeviceDialog> createState() => _PairDeviceDialogState();
}

class _PairDeviceDialogState extends State<PairDeviceDialog> {
  ({String code, DateTime expiresAt})? _code;
  Object? _error;
  Timer? _tick;

  String get _server => Uri.parse(widget.creds.baseUrl).replace(path: '').toString();
  String get _dl => downloadUrl(widget.creds.baseUrl, '').toString();

  @override
  void initState() {
    super.initState();
    _mint();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _mint() async {
    setState(() {
      _code = null;
      _error = null;
    });
    try {
      final c = await widget.api.pairingCode();
      if (mounted) setState(() => _code = c);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _copy(String text, String what) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$what copied')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final c = _code;
    final left = c?.expiresAt.difference(DateTime.now()) ?? Duration.zero;
    final expired = c != null && left.isNegative;

    Widget step(String n, String text, {String? copy, String? what}) => Padding(
          padding: const EdgeInsets.only(bottom: Spacing.sm),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: Spacing.xl, child: Text(n, style: theme.textTheme.titleSmall)),
            Expanded(child: SelectableText(text)),
            if (copy != null)
              IconButton(
                tooltip: 'Copy ${what ?? ''}'.trim(),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.copy_outlined, size: 18),
                onPressed: () => _copy(copy, what ?? 'Text'),
              ),
          ]),
        );

    final Widget code;
    if (_error != null) {
      code = Text('Could not get a code: $_error', style: TextStyle(color: theme.colorScheme.error));
    } else if (c == null) {
      code = const Center(child: CircularProgressIndicator());
    } else {
      code = Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          SelectableText(
            c.code,
            style: theme.textTheme.displaySmall?.copyWith(
              fontFamily: AppTheme.monoFontFamily,
              color: expired ? theme.colorScheme.onSurfaceVariant : null,
              decoration: expired ? TextDecoration.lineThrough : null,
            ),
          ),
          IconButton(tooltip: 'Copy code', icon: const Icon(Icons.copy_outlined), onPressed: () => _copy(c.code, 'Code')),
        ]),
        Text(
          expired
              ? 'Expired'
              : 'Single use · expires in ${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')}',
          style: muted,
        ),
      ]);
    }

    return AlertDialog(
      title: const Text('Pair a new device'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            code,
            const SizedBox(height: Spacing.lg),
            step('1', 'Install Tailscale on the new device and sign in to the same account.'),
            step('2', 'Windows, in PowerShell:\nirm ${_dl}install.ps1 | iex',
                copy: 'irm ${_dl}install.ps1 | iex', what: 'Command'),
            step('', 'Android: open $_dl in the browser and tap the APK.', copy: _dl, what: 'Link'),
            step('3', 'In the app, enter $_server and the code above.', copy: _server, what: 'Address'),
          ]),
        ),
      ),
      actions: [
        if (expired || _error != null) TextButton(onPressed: _mint, child: const Text('New code')),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
      ],
    );
  }
}
