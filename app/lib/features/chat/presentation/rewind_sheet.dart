import 'package:flutter/material.dart';

import '../../../core/providers.dart';
import '../../../core/spacing.dart';
import '../../../core/token_store.dart';
import '../data/rewind_api.dart';

/// "Rewind files to here" (ADR 0023). Dry-runs first and shows exactly which files
/// would change; only an explicit tap on the button rewinds for real.
Future<void> showRewindSheet(
  BuildContext context, {
  required Creds creds,
  required String sessionId,
  required String messageId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => RewindSheet(api: RewindApi(dioFor(creds)), sessionId: sessionId, messageId: messageId),
  );
}

/// One-line, user-facing wording for a failed rewind call.
@visibleForTesting
String rewindErrorText(RewindResult r) {
  switch (r.statusCode) {
    case 403:
      return 'Rewind refused: it would touch files outside the project.';
    case 404:
      return 'Cannot rewind to this message (no checkpoint — older turns can\'t be rewound).';
    case 409:
      return r.error ?? 'Busy — wait for the turn to finish, then try again.';
    default:
      return r.error ?? 'Rewind failed (${r.statusCode}).';
  }
}

class RewindSheet extends StatefulWidget {
  const RewindSheet({super.key, required this.api, required this.sessionId, required this.messageId});

  final RewindApi api;
  final String sessionId;
  final String messageId;

  @override
  State<RewindSheet> createState() => _RewindSheetState();
}

class _RewindSheetState extends State<RewindSheet> {
  RewindResult? _preview;
  String? _error;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await widget.api.rewind(widget.sessionId, widget.messageId, dryRun: true);
      if (!mounted) return;
      setState(() {
        if (r.canRewind) {
          _preview = r;
        } else {
          _error = rewindErrorText(r);
        }
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not reach the server.');
    }
  }

  Future<void> _confirm() async {
    setState(() => _working = true);
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    try {
      final r = await widget.api.rewind(widget.sessionId, widget.messageId, dryRun: false);
      if (!mounted) return;
      if (r.canRewind) {
        nav.pop();
        final n = r.files.length;
        final skipped = (r.skippedLinks ?? 0) > 0 ? ' (${r.skippedLinks} skipped: links)' : '';
        messenger.showSnackBar(SnackBar(content: Text('Rewound $n file${n == 1 ? '' : 's'}$skipped')));
      } else {
        setState(() {
          _working = false;
          _error = rewindErrorText(r);
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _working = false;
          _error = 'Could not reach the server.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = _preview;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Spacing.lg, 0, Spacing.lg, Spacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Rewind files to here', style: theme.textTheme.titleMedium),
            const SizedBox(height: Spacing.xs),
            Text(
              'Undoes this message\'s file changes and everything after. The conversation is kept.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: Spacing.md),
            if (_error != null)
              Text(_error!, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error))
            else if (p == null)
              const LinearProgressIndicator()
            else if (p.files.isEmpty)
              Text('No tracked file changes to undo.', style: theme.textTheme.bodyMedium)
            else ...[
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final f in p.files)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(f, style: theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace')),
                      ),
                  ],
                ),
              ),
              if (p.insertions != null || p.deletions != null)
                Padding(
                  padding: const EdgeInsets.only(top: Spacing.xs),
                  child: Text('+${p.insertions ?? 0} / −${p.deletions ?? 0} lines', style: theme.textTheme.labelSmall),
                ),
            ],
            const SizedBox(height: Spacing.sm),
            Text(
              'Changes made by shell commands (Bash) are not tracked and won\'t be undone.',
              style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: Spacing.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: _working ? null : () => Navigator.pop(context), child: const Text('Cancel')),
                const SizedBox(width: Spacing.sm),
                FilledButton(
                  onPressed: (p == null || p.files.isEmpty || _working) ? null : _confirm,
                  child: Text(_working ? 'Rewinding…' : (p == null ? 'Rewind' : 'Rewind ${p.files.length} ${p.files.length == 1 ? 'file' : 'files'}')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
