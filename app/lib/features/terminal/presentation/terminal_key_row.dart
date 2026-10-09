import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../../../core/spacing.dart';
import '../domain/ctrl_latch.dart';

/// Keys a phone keyboard doesn't have — Esc, Tab, arrows, sticky Ctrl and the
/// punctuation that's buried on the symbols page. Built on xterm's own `keyInput`, so
/// application-cursor mode and the like behave exactly as for a hardware keyboard.
class TerminalKeyRow extends StatelessWidget {
  const TerminalKeyRow({super.key, required this.terminal, required this.ctrl});

  final Terminal terminal;
  final CtrlLatch ctrl;

  void _key(TerminalKey k) {
    final held = ctrl.armed; // Ctrl+arrow, Ctrl+Tab… via the key row
    ctrl.clear();
    terminal.keyInput(k, ctrl: held);
  }

  void _text(String s) {
    ctrl.clear();
    terminal.textInput(s);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget btn(String label, VoidCallback onTap, {String? tip, Key? key}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          child: Tooltip(
            message: tip ?? label,
            child: Material(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(Radii.sm),
              child: InkWell(
                key: key,
                borderRadius: BorderRadius.circular(Radii.sm),
                onTap: onTap,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
                  child: Center(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Text(label))),
                ),
              ),
            ),
          ),
        );

    return Material(
      color: scheme.surfaceContainerLow,
      child: SizedBox(
        height: 44,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
          children: [
            btn('Esc', () => _key(TerminalKey.escape)),
            btn('Tab', () => _key(TerminalKey.tab)),
            ListenableBuilder(
              listenable: ctrl,
              builder: (_, _) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                child: Material(
                  color: ctrl.armed ? scheme.primary : scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(Radii.sm),
                  child: InkWell(
                    key: const Key('ctrl'),
                    borderRadius: BorderRadius.circular(Radii.sm),
                    onTap: ctrl.toggle,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text('Ctrl', style: TextStyle(color: ctrl.armed ? scheme.onPrimary : null)),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            btn('←', () => _key(TerminalKey.arrowLeft), tip: 'Left'),
            btn('↑', () => _key(TerminalKey.arrowUp), tip: 'Up'),
            btn('↓', () => _key(TerminalKey.arrowDown), tip: 'Down'),
            btn('→', () => _key(TerminalKey.arrowRight), tip: 'Right'),
            btn('Home', () => _key(TerminalKey.home)),
            btn('End', () => _key(TerminalKey.end)),
            btn('PgUp', () => _key(TerminalKey.pageUp)),
            btn('PgDn', () => _key(TerminalKey.pageDown)),
            for (final ch in const ['|', '~', '/', '-', '_', '\\', '`', '*', '&', '<', '>'])
              btn(ch, () => _text(ch)),
          ],
        ),
      ),
    );
  }
}
