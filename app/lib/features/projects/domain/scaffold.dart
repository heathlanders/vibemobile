import 'dart:convert';

/// One file in a scaffold: a project-relative path and its body. `{{project_name}}`
/// and `{{date}}` in the body are substituted by the daemon on create.
class ScaffoldFile {
  const ScaffoldFile({required this.path, required this.body});
  final String path;
  final String body;

  factory ScaffoldFile.fromJson(Map<String, dynamic> j) =>
      ScaffoldFile(path: j['path'] as String, body: j['body'] as String);

  Map<String, dynamic> toJson() => {'path': path, 'body': body};
}

/// A foundation template: a named set of files applied to a new project dir
/// (proposal 17). The multi-file analogue of a prompt. Named `ProjectScaffold`
/// to avoid clashing with Flutter's `Scaffold` widget.
class ProjectScaffold {
  const ProjectScaffold({
    required this.id,
    required this.name,
    this.description,
    this.files = const [],
  });

  final String id;
  final String name;
  final String? description;
  final List<ScaffoldFile> files;

  factory ProjectScaffold.fromJson(Map<String, dynamic> j) {
    final raw = (j['files_json'] as String?) ?? '[]';
    final list = (jsonDecode(raw) as List<dynamic>)
        .map((e) => ScaffoldFile.fromJson(e as Map<String, dynamic>))
        .toList();
    return ProjectScaffold(
      id: j['id'] as String,
      name: j['name'] as String,
      description: j['description'] as String?,
      files: list,
    );
  }
}
