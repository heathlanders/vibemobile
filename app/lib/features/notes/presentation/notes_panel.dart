import 'package:flutter/material.dart';

import '../../../core/platform.dart';
import '../../../core/providers.dart';
import '../../../core/spacing.dart';
import '../../../core/token_store.dart';
import '../../../core/widgets.dart';
import '../../chat/presentation/chat_screen.dart';
import '../../sessions/data/session_api.dart';
import '../../sessions/domain/session.dart';
import '../../sessions/presentation/model_picker.dart';
import '../data/note_api.dart';
import '../domain/note.dart';

/// Opens a project's notes / TODO list (proposal 31): a bottom sheet on mobile,
/// a dialog on desktop.
Future<void> showProjectNotes(BuildContext context, Creds creds, Project project) {
  final panel = NotesPanel(creds: creds, project: project);
  if (isMobile) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        // Lift above the keyboard.
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: SizedBox(height: MediaQuery.sizeOf(ctx).height * 0.7, child: panel),
      ),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(child: SizedBox(width: 480, height: 600, child: panel)),
  );
}

class NotesPanel extends StatefulWidget {
  const NotesPanel({super.key, required this.creds, required this.project});
  final Creds creds;
  final Project project;

  @override
  State<NotesPanel> createState() => _NotesPanelState();
}

class _NotesPanelState extends State<NotesPanel> {
  late final NoteApi _api = NoteApi(dioFor(widget.creds));
  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  List<Note>? _notes;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final notes = await _api.list(widget.project.id);
      if (mounted) setState(() => _notes = notes);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  // Open items first, done at the bottom (matches the server's order).
  List<Note> _sorted(List<Note> l) => [...l.where((n) => !n.done), ...l.where((n) => n.done)];

  void _fail(Object e) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Note not saved: $e')));
  }

  Future<void> _add() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    _inputFocus.requestFocus(); // keep capturing
    try {
      final n = await _api.create(widget.project.id, text);
      if (mounted) setState(() => _notes = _sorted([...?_notes, n]));
    } catch (e) {
      _input.text = text; // give the text back
      _fail(e);
    }
  }

  // Optimistic edit; reverts on failure.
  Future<void> _update(Note n, {String? text, bool? done}) async {
    final before = _notes;
    setState(() => _notes = _sorted([for (final x in _notes!) x.id == n.id ? x.copyWith(text: text, done: done) : x]));
    try {
      await _api.update(n.id, text: text, done: done);
    } catch (e) {
      if (mounted) setState(() => _notes = before);
      _fail(e);
    }
  }

  Future<void> _delete(Note n) async {
    final before = _notes;
    setState(() => _notes = _notes!.where((x) => x.id != n.id).toList());
    try {
      await _api.delete(n.id);
    } catch (e) {
      if (mounted) setState(() => _notes = before);
      _fail(e);
    }
  }

  /// Proposal 57: a new chat in this project, its composer pre-filled with the open
  /// notes. Nothing is sent until the user sends it.
  Future<void> _buildInChat() async {
    final open = (_notes ?? const <Note>[]).where((n) => !n.done).toList();
    if (open.isEmpty) return;
    final sessions = SessionApi(dioFor(widget.creds));
    final choice = await chooseModel(context, sessions);
    if (choice == null || !mounted) return;
    try {
      final s = await sessions.create(widget.project.id, kind: 'claude', model: choice.id);
      if (!mounted) return;
      final nav = Navigator.of(context);
      nav.pop(); // close the notes sheet / dialog
      nav.push(sharedAxisRoute(ChatScreen(creds: widget.creds, session: s, initialDraft: buildNotesPrompt(open))));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not start a chat: $e')));
    }
  }

  Future<void> _edit(Note n) async {
    final ctrl = TextEditingController(text: n.text);
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit note'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: null,
          maxLength: 4000,
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Save')),
        ],
      ),
    );
    ctrl.dispose();
    final t = text?.trim();
    if (t != null && t.isNotEmpty && t != n.text) await _update(n, text: t);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Spacing.lg, Spacing.sm, Spacing.sm, 0),
        child: Row(children: [
          Expanded(
            child: Text('Notes · ${widget.project.label}',
                style: theme.textTheme.titleMedium, overflow: TextOverflow.ellipsis),
          ),
          TextButton.icon(
            icon: const Icon(Icons.play_arrow_outlined, size: 18),
            label: const Text('Build in chat'),
            onPressed: (_notes ?? const <Note>[]).any((n) => !n.done) ? _buildInChat : null,
          ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: TextField(
          controller: _input,
          focusNode: _inputFocus,
          maxLength: 4000,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _add(),
          decoration: InputDecoration(
            hintText: 'Add an idea or TODO…',
            counterText: '',
            border: const OutlineInputBorder(),
            isDense: true,
            suffixIcon: IconButton(tooltip: 'Add', icon: const Icon(Icons.add), onPressed: _add),
          ),
        ),
      ),
      Expanded(child: _body(theme)),
    ]);
  }

  Widget _body(ThemeData theme) {
    if (_error != null) return ErrorBody(message: _error!);
    final notes = _notes;
    if (notes == null) return const SkeletonList(rows: 4);
    if (notes.isEmpty) {
      return const EmptyState(
        icon: Icons.sticky_note_2_outlined,
        title: 'No notes yet',
        hint: 'Jot down ideas and TODOs for this project.',
      );
    }
    return ListView.builder(
      itemCount: notes.length,
      itemBuilder: (context, i) {
        final n = notes[i];
        final row = ListTile(
          dense: true,
          leading: Checkbox(value: n.done, onChanged: (v) => _update(n, done: v ?? false)),
          title: Text(
            n.text,
            style: n.done
                ? TextStyle(decoration: TextDecoration.lineThrough, color: theme.colorScheme.onSurfaceVariant)
                : null,
          ),
          onTap: () => _edit(n),
          trailing: isMobile
              ? null
              : IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline, size: 18), onPressed: () => _delete(n)),
        );
        if (!isMobile) return row;
        return Dismissible(
          key: ValueKey(n.id),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: Spacing.lg),
            color: theme.colorScheme.errorContainer,
            child: Icon(Icons.delete_outline, color: theme.colorScheme.onErrorContainer),
          ),
          onDismissed: (_) => _delete(n),
          child: row,
        );
      },
    );
  }
}
