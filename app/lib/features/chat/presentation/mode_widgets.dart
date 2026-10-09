import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/spacing.dart';
import '../domain/chat_message.dart';
import '../domain/session_mode.dart';

/// Composer chip showing the session's mode (proposal 25); tap opens the picker.
/// Plan is tinted so a session that can't run anything yet is hard to miss.
class ModeChip extends StatelessWidget {
  const ModeChip({super.key, required this.mode, required this.onTap});
  final SessionMode mode;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isPlan = mode == SessionMode.plan;
    return ActionChip(
      avatar: Icon(mode.icon, size: 16, color: isPlan ? scheme.onTertiaryContainer : null),
      label: Text(mode.label),
      backgroundColor: isPlan ? scheme.tertiaryContainer : null,
      visualDensity: VisualDensity.compact,
      tooltip: 'Session mode',
      onPressed: onTap,
    );
  }
}

/// Bottom-sheet mode picker. Returns the chosen mode, or null if dismissed.
/// Only [available] modes are offered (a native session has no Plan).
Future<SessionMode?> showModePicker(
  BuildContext context, {
  required SessionMode current,
  required List<SessionMode> available,
}) {
  return showModalBottomSheet<SessionMode>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final m in available)
            ListTile(
              leading: Icon(m.icon),
              title: Text(m.label),
              subtitle: Text(m.description),
              trailing: m == current ? const Icon(Icons.check) : null,
              onTap: () => Navigator.of(ctx).pop(m),
            ),
        ],
      ),
    ),
  );
}

/// Plan approval card (proposal 25): the model finished planning and called
/// ExitPlanMode. Nothing has run — approving lets it start, in the chosen mode;
/// "Keep planning" sends optional feedback and the model revises.
class ExitPlanCard extends StatefulWidget {
  const ExitPlanCard({
    super.key,
    required this.dialog,
    required this.onApprove,
    required this.onKeepPlanning,
  });
  final UserDialog dialog;

  /// Approve and continue in [SessionMode.auto] or [SessionMode.ask].
  final void Function(SessionMode mode) onApprove;
  final void Function(String? feedback) onKeepPlanning;

  @override
  State<ExitPlanCard> createState() => _ExitPlanCardState();
}

class _ExitPlanCardState extends State<ExitPlanCard> {
  final _feedback = TextEditingController();
  bool _revising = false;

  @override
  void dispose() {
    _feedback.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final plan = widget.dialog.plan;
    return Material(
      color: scheme.tertiaryContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(Spacing.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(SessionMode.plan.icon, size: 18, color: scheme.onTertiaryContainer),
                const SizedBox(width: 8),
                Text(
                  'Plan ready — nothing has run yet',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(color: scheme.onTertiaryContainer),
                ),
              ]),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.4),
                child: SingleChildScrollView(
                  child: SelectableText(
                    plan.isEmpty ? '(empty plan)' : plan,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onTertiaryContainer),
                  ),
                ),
              ),
              if (_revising) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _feedback,
                  autofocus: true,
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    hintText: 'What should change? (optional)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 4, children: [
                if (!_revising) ...[
                  FilledButton.icon(
                    icon: Icon(SessionMode.auto.icon, size: 18),
                    label: const Text('Approve · auto-allow'),
                    onPressed: () {
                      HapticFeedback.mediumImpact();
                      widget.onApprove(SessionMode.auto);
                    },
                  ),
                  OutlinedButton.icon(
                    icon: Icon(SessionMode.ask.icon, size: 18),
                    label: const Text('Approve · ask each'),
                    onPressed: () => widget.onApprove(SessionMode.ask),
                  ),
                  TextButton(onPressed: () => setState(() => _revising = true), child: const Text('Keep planning')),
                ] else ...[
                  FilledButton(
                    onPressed: () => widget.onKeepPlanning(_feedback.text),
                    child: const Text('Send feedback'),
                  ),
                  TextButton(onPressed: () => setState(() => _revising = false), child: const Text('Back')),
                ],
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
