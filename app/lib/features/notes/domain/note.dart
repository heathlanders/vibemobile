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
