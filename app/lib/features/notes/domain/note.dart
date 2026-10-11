/// A project note / TODO item (proposal 31): short text with a done checkbox.
class Note {
  Note({required this.id, required this.projectId, required this.text, this.done = false});

  final String id;
  final String projectId;
  final String text;
  final bool done;

  Note copyWith({String? text, bool? done}) =>
      Note(id: id, projectId: projectId, text: text ?? this.text, done: done ?? this.done);

  factory Note.fromJson(Map<String, dynamic> j) => Note(
        id: j['id'] as String,
        projectId: j['project_id'] as String,
        text: j['text'] as String,
        done: j['done'] == true,
      );
}

/// The draft for "Build in chat" (proposal 57): the open notes as a work list, with
/// the inbox workflow (capture in docs, build, tick off). The user edits it before sending.
String buildNotesPrompt(Iterable<Note> open) {
  final items = open.map((n) => '- ${n.text.trim().replaceAll('\n', '\n  ')}').join('\n');
  return 'Build these open notes from this project\'s Notes. For each one: capture it in the '
      'project\'s docs (a Proposal or Milestone), implement and test it, then tick it off with '
      'resolve_note.\n\n$items';
}
