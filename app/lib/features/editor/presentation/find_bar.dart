import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';

import '../../../core/spacing.dart';

const _rowHeight = 40.0;
const _panelWidth = 400.0;

/// Find / replace bar over a [CodeFindController] (`CodeEditor.findBuilder`): case and regex toggles,
/// previous / next, and, when the editor is writable, replace and replace all.
class EditorFindBar extends StatelessWidget implements PreferredSizeWidget {
  const EditorFindBar({super.key, required this.controller, required this.readOnly});
  final CodeFindController controller;
  final bool readOnly;

  bool get _replace => !readOnly && (controller.value?.replaceMode ?? false);

  @override
  Size get preferredSize => Size.fromHeight(controller.value == null ? 0 : (_replace ? 2 : 1) * _rowHeight);

  @override
  Widget build(BuildContext context) {
    final v = controller.value;
    if (v == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final result = v.result == null ? (v.option.pattern.isEmpty ? '' : 'none') : '${v.result!.index + 1}/${v.result!.matches.length}';
    // The fields hold focus while the bar is open, where Ctrl+H would otherwise delete a character.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyH, control: true): controller.replaceMode,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): controller.findMode,
        const SingleActivator(LogicalKeyboardKey.escape): controller.close,
      },
      child: Align(
      alignment: Alignment.topRight,
      child: Material(
        color: scheme.surfaceContainerHigh,
        elevation: 1,
        child: SizedBox(
          width: _panelWidth,
          height: preferredSize.height,
          child: Column(children: [
            SizedBox(
              height: _rowHeight,
              child: Row(children: [
                Expanded(child: _field(context, controller.findInputController, controller.findInputFocusNode, 'Find')),
                _toggle(context, 'Aa', 'Match case', v.option.caseSensitive, controller.toggleCaseSensitive),
                _toggle(context, '.*', 'Regex', v.option.regex, controller.toggleRegex),
                SizedBox(width: 44, child: Text(result, textAlign: TextAlign.center, style: Theme.of(context).textTheme.labelSmall)),
                _icon(Icons.arrow_upward, 'Previous', v.result == null ? null : controller.previousMatch),
                _icon(Icons.arrow_downward, 'Next', v.result == null ? null : controller.nextMatch),
                // Same as Ctrl+H, for the phone (no keyboard shortcut there).
                if (!readOnly)
                  _icon(Icons.find_replace, _replace ? 'Hide replace' : 'Show replace', controller.toggleMode),
                _icon(Icons.close, 'Close', controller.close),
              ]),
            ),
            if (_replace)
              SizedBox(
                height: _rowHeight,
                child: Row(children: [
                  Expanded(child: _field(context, controller.replaceInputController, controller.replaceInputFocusNode, 'Replace')),
                  _icon(Icons.done, 'Replace', v.result == null ? null : controller.replaceMatch),
                  _icon(Icons.done_all, 'Replace All', v.result == null ? null : controller.replaceAllMatches),
                ]),
              ),
          ]),
        ),
      ),
    ));
  }

  Widget _field(BuildContext context, TextEditingController c, FocusNode f, String hint) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.xs, vertical: Spacing.xs),
        child: TextField(
          controller: c,
          focusNode: f,
          maxLines: 1,
          style: Theme.of(context).textTheme.bodyMedium,
          decoration: InputDecoration(hintText: hint, isDense: true, border: const OutlineInputBorder(), contentPadding: const EdgeInsets.all(Spacing.sm)),
        ),
      );

  Widget _toggle(BuildContext context, String label, String tip, bool on, VoidCallback onTap) => Tooltip(
        message: tip,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.xs, vertical: Spacing.sm),
            child: Text(label, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: on ? FontWeight.w700 : FontWeight.w400, color: on ? Theme.of(context).colorScheme.primary : null)),
          ),
        ),
      );

  Widget _icon(IconData icon, String tip, VoidCallback? onPressed) => IconButton(
        icon: Icon(icon, size: 16),
        tooltip: tip,
        onPressed: onPressed,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(width: 32, height: 32),
        padding: EdgeInsets.zero,
      );
}
