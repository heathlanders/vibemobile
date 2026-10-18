import 'package:flutter/material.dart';

import '../../../core/spacing.dart';
import '../../sessions/domain/session.dart';
import '../data/task_api.dart';
import '../domain/merge_item.dart';

/// View/edit the project's merge test command (ADR 0032).
Future<void> showProjectSettings(BuildContext context, TaskApi api, Project project) => showDialog<void>(
  context: context,
  builder: (_) => ProjectSettingsDialog(api: api, project: project),
);

class ProjectSettingsDialog extends StatefulWidget {
  const ProjectSettingsDialog({super.key, required this.api, required this.project});
  final TaskApi api;
  final Project project;

  @override
  State<ProjectSettingsDialog> createState() => _ProjectSettingsDialogState();
}

class _ProjectSettingsDialogState extends State<ProjectSettingsDialog> {
  final _cmd = TextEditingController();
  bool _loaded = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.api
        .getProjectSettings(widget.project.id)
        .then((argv) {
          if (!mounted) return;
          setState(() {
            _cmd.text = testCommandText(argv);
            _loaded = true;
          });
        })
        .catchError((Object e) {
          if (mounted) {
            setState(() {
              _error = '$e'.replaceFirst('Exception: ', '');
              _loaded = true;
            });
          }
        });
  }

  @override
  void dispose() {
    _cmd.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.api.putProjectSettings(widget.project.id, testCommand: parseTestCommand(_cmd.text));
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$e'.replaceFirst('Exception: ', ''); // the daemon's 400 message
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Project settings'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _cmd,
              enabled: _loaded && !_saving,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'Test command',
                hintText: 'pnpm test',
                helperMaxLines: 4,
                helperText:
                    'Split on spaces, no shell. First word one of: ${allowedTestRunners.join(' ')}. '
                    'Empty = merges reach approval marked untested.',
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: Spacing.sm),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _loaded && !_saving ? _save : null, child: const Text('Save')),
      ],
    );
  }
}
