import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../../core/providers.dart';
import '../../../core/reconnect.dart';
import '../../../core/spacing.dart';
import '../../../core/theme.dart';
import '../../../core/token_store.dart';
import '../../sessions/data/session_api.dart';
import '../../sessions/domain/session.dart';
import '../../../core/platform.dart';
import 'terminal_key_row.dart';
import 'terminal_session_controller.dart';

/// A live, reconnecting terminal for one session. The session lives in tmux on
/// the server (ADR 0004); a dropped socket detaches and the controller reattaches
/// to the SAME id, so the shell survives WiFi↔cellular roams. Close = DELETE the
/// session (the only thing that kills it).
class TerminalScreen extends ConsumerStatefulWidget {
  const TerminalScreen({super.key, required this.creds, required this.session, this.url, this.onClose});

  final Creds creds;
  final Session session;

  /// Desktop workspace tab (ADR 0015): called after Close instead of popping.
  final VoidCallback? onClose;

  /// Attach somewhere other than `/pty/<id>` — the TUI of a CLI session running
  /// on the server (ttyUrl, ADR 0012). Such a view has no Close: leaving just
  /// detaches, and the session belongs to the CLI, not to us.
  final Uri? url;

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen> {
  late final TerminalSessionController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TerminalSessionController(
      url: widget.url ?? ptyUrl(widget.creds.baseUrl, widget.session.id),
      token: widget.creds.token,
    )..onAuthFailed = _onAuthFailed;
    _controller.start();
  }

  Future<void> _onAuthFailed() async {
    await ref.read(tokenStoreProvider).clear();
    ref.invalidate(credsProvider); // app root routes back to pairing
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  Future<void> _close() async {
    try {
      await SessionApi(dioFor(widget.creds)).delete(widget.session.id);
    } catch (_) {
      // best-effort; the row may already be gone (DELETE is idempotent server-side)
    }
    if (!mounted) return;
    final onClose = widget.onClose;
    onClose != null ? onClose() : Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.session.label),
        actions: [
          if (widget.url == null)
            IconButton(
              tooltip: 'Close session',
              icon: const Icon(Icons.close),
              onPressed: _close,
            ),
        ],
      ),
      body: Column(
        children: [
          _StatusBanner(controller: _controller),
          Expanded(
            child: TerminalView(
              _controller.terminal,
              textStyle: const TerminalStyle(fontFamily: AppTheme.monoFontFamily),
            ),
          ),
          if (isMobile) TerminalKeyRow(terminal: _controller.terminal, ctrl: _controller.ctrl),
        ],
      ),
    );
  }
}

/// Thin reactive strip showing connection state (live / reconnecting / ended).
class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.controller});
  final TerminalSessionController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final colors = Theme.of(context).extension<AppColors>()!;
        final (String text, Color bg, bool spin) = switch (controller.state) {
          ConnState.connecting => ('Connecting…', colors.connConnecting, true),
          ConnState.live => ('Live', scheme.primaryContainer, false),
          ConnState.reconnecting => ('Reconnecting…', colors.connReconnecting, true),
          ConnState.ended => ('Session ended', colors.connEnded, false),
          ConnState.authFailed => ('Auth expired — re-pairing', colors.connAuthFailed, false),
        };
        if (controller.state == ConnState.live) return const SizedBox(height: 0);
        return Container(
          width: double.infinity,
          color: bg,
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: Spacing.md),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (spin)
                const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
              if (spin) const SizedBox(width: 8),
              Text(text),
            ],
          ),
        );
      },
    );
  }
}
