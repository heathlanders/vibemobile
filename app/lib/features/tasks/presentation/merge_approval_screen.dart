import 'package:flutter/material.dart';

import '../../../core/spacing.dart';
import '../data/task_api.dart';
import '../domain/merge_item.dart';

/// Opens the approval screen for a queue item (ADR 0032 §6). Completes with true
/// once an action ran (or was attempted), so the caller re-reads the queue.
Future<bool?> showMergeApproval(BuildContext context, TaskApi api, MergeItem item, {String? taskTitle}) =>
    Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => MergeApprovalScreen(api: api, item: item, taskTitle: taskTitle),
      ),
    );

class MergeApprovalScreen extends StatefulWidget {
  const MergeApprovalScreen({super.key, required this.api, required this.item, this.taskTitle});
  final TaskApi api;
  final MergeItem item;
  final String? taskTitle;

  @override
  State<MergeApprovalScreen> createState() => _MergeApprovalScreenState();
}

class _MergeApprovalScreenState extends State<MergeApprovalScreen> {
  bool _busy = false;

  Future<void> _run(String failed, Future<Object?> Function() fn) async {
    setState(() => _busy = true);
    try {
      await fn();
    } catch (e) {
      if (mounted) {
        final msg = '$e'.replaceFirst('Exception: ', '');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$failed: $msg')));
      }
    }
    if (mounted) {
      Navigator.pop(context, true); // the caller re-reads the queue either way
    }
  }

  Future<void> _reject() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reject this merge?'),
        content: const Text('The task goes back to its author. Nothing is merged.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reject')),
        ],
      ),
    );
    if (ok == true) {
      await _run('Could not reject', () => widget.api.reject(widget.item.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final r = item.result;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tested = item.testedSha;
    final approvable = item.state == 'awaiting_approval' && tested != null && tested.length == 40;

    Widget section(String title, Widget child) => Padding(
      padding: const EdgeInsets.only(top: Spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Spacing.xs),
          child,
        ],
      ),
    );

    Widget mono(String text, {double? maxHeight}) => Container(
      width: double.infinity,
      constraints: BoxConstraints(maxHeight: maxHeight ?? double.infinity),
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
      child: SingleChildScrollView(
        reverse: true, // the tail is what matters
        child: SelectableText(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
      ),
    );

    final (String, Color) testLine = switch (r) {
      MergeResult(untested: true) => ('Untested: no test command is set. Nothing checked this change.', scheme.error),
      MergeResult(timedOut: true) => ('Tests timed out', scheme.error),
      MergeResult(testOk: true) => ('Tests passed', Colors.green),
      MergeResult(testOk: false) => ('Tests failed (exit ${r.testExit ?? '?'})', scheme.error),
      _ => ('No test result yet', scheme.onSurfaceVariant),
    };

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.taskTitle ?? 'Merge'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: Spacing.md),
            child: Center(child: MergeBadge(item: item)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(Spacing.lg),
        children: [
          Text('Into ${item.target}', style: theme.textTheme.titleMedium),
          const SizedBox(height: Spacing.xs),
          SelectableText(
            '${shortSha(item.targetSha)}..${shortSha(tested)}',
            style: const TextStyle(fontFamily: 'monospace'),
          ),
          if (item.attempt > 1) Text('Attempt ${item.attempt}', style: theme.textTheme.bodySmall),
          if (item.state == 'bounced') ...[
            section('Bounced', Text(r.reason ?? 'No reason given', style: TextStyle(color: scheme.error))),
          ] else ...[
            const SizedBox(height: Spacing.md),
            Container(
              padding: const EdgeInsets.all(Spacing.sm),
              decoration: BoxDecoration(
                color: testLine.$2.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                border: r.untested ? Border.all(color: testLine.$2) : null,
              ),
              child: Row(
                children: [
                  Icon(r.untested ? Icons.warning_amber_rounded : Icons.science_outlined, color: testLine.$2),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: Text(
                      testLine.$1,
                      style: TextStyle(color: testLine.$2, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (r.commits.isNotEmpty) section('Commits · ${r.commits.length}', Text(r.commits.join('\n'))),
          if (r.diffstat.isNotEmpty) section('Diffstat', mono(r.diffstat)),
          if (r.output.isNotEmpty)
            section(item.state == 'bounced' ? 'Output' : 'Test output', mono(r.output, maxHeight: 280)),
          if ((r.notes ?? '').isNotEmpty) section('Notes', Text(r.notes!)),
          const SizedBox(height: Spacing.lg),
          if (approvable)
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(onPressed: _busy ? null : _reject, child: const Text('Reject')),
                ),
                const SizedBox(width: Spacing.md),
                Expanded(
                  child: FilledButton(
                    // Always the item's own full tested_sha, never typed input.
                    onPressed: _busy
                        ? null
                        : () => _run('Could not approve', () => widget.api.approve(item.id, tested)),
                    child: const Text('Approve'),
                  ),
                ),
              ],
            ),
          if (item.state == 'queued') OutlinedButton(onPressed: _busy ? null : _reject, child: const Text('Reject')),
          if (item.state == 'bounced') ...[
            FilledButton(
              onPressed: _busy || !item.canRequeue
                  ? null
                  : () => _run('Could not requeue', () => widget.api.requeue(item.id)),
              child: const Text('Requeue'),
            ),
            if (!item.canRequeue)
              Padding(
                padding: const EdgeInsets.only(top: Spacing.xs),
                child: Text(
                  'Bounced $maxMergeAttempts times. Reset the task to ready and dispatch it again.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// Small state badge for a task row; tap opens the approval screen.
class MergeBadge extends StatelessWidget {
  const MergeBadge({super.key, required this.item, this.onTap});
  final MergeItem item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (item.state) {
      'merged' => Colors.green,
      'bounced' => scheme.error,
      'awaiting_approval' => scheme.tertiary,
      _ => scheme.primary,
    };
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)),
        child: Text(mergeStateLabel(item.state), style: TextStyle(fontSize: 12, color: color)),
      ),
    );
  }
}
