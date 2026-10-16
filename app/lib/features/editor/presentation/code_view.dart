import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/styles/vs.dart';
import 'package:re_highlight/styles/vs2015.dart';

import '../../../core/theme.dart';
import '../domain/editor_language.dart';
import 'find_bar.dart';

/// The default shortcuts plus the VS Code habits re_editor lacks: Ctrl+Y (redo) and Ctrl+H (replace).
/// Ctrl+F, Ctrl+S, Ctrl+Z, Ctrl+Shift+Z, Tab / Shift+Tab and Alt+Up / Down are already in the defaults.
class EditorShortcuts extends CodeShortcutsActivatorsBuilder {
  const EditorShortcuts();
  static const _defaults = DefaultCodeShortcutsActivatorsBuilder();

  @override
  List<ShortcutActivator>? build(CodeShortcutType type) {
    final base = _defaults.build(type);
    return switch (type) {
      CodeShortcutType.redo => [...?base, const SingleActivator(LogicalKeyboardKey.keyY, control: true)],
      CodeShortcutType.replace => [...?base, const SingleActivator(LogicalKeyboardKey.keyH, control: true)],
      _ => base,
    };
  }
}

/// The shared code surface (proposal 60): highlighting by [language], line numbers, folding,
/// current-line highlight, find / replace and, on a phone, a Select all / Undo / Redo / Find row.
/// The editor screen drives it writable; the file-diff screen read-only. The caller owns [controller]
/// (build it with [codeController]).
class CodeView extends StatefulWidget {
  const CodeView({
    super.key,
    required this.controller,
    required this.language,
    this.readOnly = false,
    this.line,
    this.onSave,
    this.findController,
  });
  final CodeLineEditingController controller;
  final String language;
  final bool readOnly;

  /// 1-based line to put the cursor on and scroll to when the view first shows.
  final int? line;
  final VoidCallback? onSave;

  /// Pass one to drive find from outside (an app bar button); otherwise the view makes its own.
  final CodeFindController? findController;

  @override
  State<CodeView> createState() => _CodeViewState();
}

/// Phones (and tablets) get the on-screen action row and selection menu; desktop has keys and a mouse.
bool get phoneToolbar => defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;

/// A buffer for [text]; keeps the file's CRLF line endings so a save doesn't rewrite every line.
CodeLineEditingController codeController(String text) => CodeLineEditingController.fromText(
      text,
      CodeLineOptions(lineBreak: text.contains('\r\n') ? TextLineBreak.crlf : TextLineBreak.lf),
    );

class _CodeViewState extends State<CodeView> {
  late final CodeScrollController _scroll = CodeScrollController();
  CodeFindController? _ownFind;
  late final CodeFindController _find = widget.findController ?? (_ownFind = CodeFindController(widget.controller));

  bool get _phone => phoneToolbar;

  @override
  void initState() {
    super.initState();
    final line = widget.line;
    if (line != null && line >= 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final c = widget.controller;
        final i = (line - 1).clamp(0, c.lineCount - 1);
        c.selection = CodeLineSelection.collapsed(index: i, offset: 0);
        c.makeCursorCenterIfInvisible();
      });
    }
  }

  @override
  void dispose() {
    _ownFind?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final hl = dark ? vs2015Theme : vsTheme;
    final root = hl['root']!;
    final mode = modeFor(widget.language);
    final numberStyle = TextStyle(fontFamily: AppTheme.monoFontFamily, fontSize: 12, height: 1.4, color: dark ? const Color(0xFF858585) : const Color(0xFF237893));
    final editor = CodeEditor(
      controller: widget.controller,
      scrollController: _scroll,
      findController: _find,
      readOnly: widget.readOnly,
      wordWrap: false,
      style: CodeEditorStyle(
        fontFamily: AppTheme.monoFontFamily,
        fontSize: 13,
        fontHeight: 1.4,
        textColor: root.color,
        backgroundColor: root.backgroundColor,
        cursorColor: dark ? const Color(0xFFAEAFAD) : const Color(0xFF000000),
        cursorLineColor: dark ? const Color(0x33FFFFFF) : const Color(0x22000000),
        selectionColor: dark ? const Color(0xFF264F78) : const Color(0xFFADD6FF),
        codeTheme: mode == null ? null : CodeHighlightTheme(languages: {widget.language: mode.themeMode}, theme: hl),
      ),
      indicatorBuilder: (context, editing, chunk, notifier) => Row(children: [
        DefaultCodeLineNumber(controller: editing, notifier: notifier, textStyle: numberStyle, focusedTextStyle: numberStyle.copyWith(color: root.color)),
        DefaultCodeChunkIndicator(width: 20, controller: chunk, notifier: notifier),
      ]),
      findBuilder: (context, controller, readOnly) => EditorFindBar(controller: controller, readOnly: readOnly),
      shortcutsActivatorsBuilder: const EditorShortcuts(),
      shortcutOverrideActions: {
        CodeShortcutSaveIntent: CallbackAction<CodeShortcutSaveIntent>(onInvoke: (_) {
          if (!widget.readOnly) widget.onSave?.call();
          return null;
        }),
      },
      toolbarController: _phone ? _mobileToolbar() : const _ContextMenu(),
    );
    return Column(children: [
      Expanded(child: editor),
      if (_phone) _KeyRow(controller: widget.controller, find: _find, readOnly: widget.readOnly),
    ]);
  }

  /// Long-press selection menu on a phone (Cut / Copy / Paste / Select all).
  SelectionToolbarController _mobileToolbar() => MobileSelectionToolbarController(
        builder: ({required context, required anchors, required controller, required onDismiss, required onRefresh}) =>
            AdaptiveTextSelectionToolbar.buttonItems(anchors: anchors, buttonItems: [
          if (!widget.readOnly && !controller.selection.isCollapsed)
            ContextMenuButtonItem(type: ContextMenuButtonType.cut, onPressed: () { controller.cut(); onRefresh(); }),
          if (!controller.selection.isCollapsed) ContextMenuButtonItem(type: ContextMenuButtonType.copy, onPressed: () { controller.copy(); onRefresh(); }),
          if (!widget.readOnly) ContextMenuButtonItem(type: ContextMenuButtonType.paste, onPressed: () { controller.paste(); onRefresh(); }),
          ContextMenuButtonItem(type: ContextMenuButtonType.selectAll, onPressed: () { controller.selectAll(); onRefresh(); }),
        ]),
      );
}

/// Right-click menu on desktop.
class _ContextMenu implements SelectionToolbarController {
  const _ContextMenu();

  @override
  void hide(BuildContext context) {}

  @override
  void show({
    required BuildContext context,
    required CodeLineEditingController controller,
    required TextSelectionToolbarAnchors anchors,
    Rect? renderRect,
    required LayerLink layerLink,
    required ValueNotifier<bool> visibility,
  }) {
    showMenu<void>(
      context: context,
      position: RelativeRect.fromSize(anchors.primaryAnchor & const Size(150, 0), MediaQuery.sizeOf(context)),
      items: [
        PopupMenuItem<void>(onTap: controller.cut, child: const Text('Cut')),
        PopupMenuItem<void>(onTap: controller.copy, child: const Text('Copy')),
        PopupMenuItem<void>(onTap: controller.paste, child: const Text('Paste')),
      ],
    );
  }
}

/// Phone toolbar: the actions a soft keyboard has no keys for.
class _KeyRow extends StatelessWidget {
  const _KeyRow({required this.controller, required this.find, required this.readOnly});
  final CodeLineEditingController controller;
  final CodeFindController find;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: SizedBox(
        height: 44,
        child: ValueListenableBuilder<CodeLineEditingValue>(
          valueListenable: controller,
          builder: (context, _, _) => Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            IconButton(tooltip: 'Select all', icon: const Icon(Icons.select_all), onPressed: controller.selectAll),
            if (!readOnly) IconButton(tooltip: 'Undo', icon: const Icon(Icons.undo), onPressed: controller.canUndo ? controller.undo : null),
            if (!readOnly) IconButton(tooltip: 'Redo', icon: const Icon(Icons.redo), onPressed: controller.canRedo ? controller.redo : null),
            IconButton(tooltip: 'Find', icon: const Icon(Icons.search), onPressed: find.findMode),
          ]),
        ),
      ),
    );
  }
}

/// [CodeView] over a fixed [text], read-only: for screens that only show a file. [path] picks the language.
class ReadOnlyCodeView extends StatefulWidget {
  const ReadOnlyCodeView({super.key, required this.text, required this.path, this.line});
  final String text;
  final String path;
  final int? line;

  @override
  State<ReadOnlyCodeView> createState() => _ReadOnlyCodeViewState();
}

class _ReadOnlyCodeViewState extends State<ReadOnlyCodeView> {
  late final CodeLineEditingController _controller = codeController(widget.text);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CodeView(controller: _controller, language: languageFor(widget.path), readOnly: true, line: widget.line);
}
