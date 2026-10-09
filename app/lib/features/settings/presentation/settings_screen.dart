import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_log.dart';
import '../../../core/chat_settings.dart';
import '../../../core/providers.dart';
import '../../../core/spacing.dart';
import '../../../core/theme_controller.dart';
import '../../../core/token_store.dart';
import '../../../core/widgets.dart';
import '../../chat/domain/session_mode.dart';
import '../../sessions/data/session_api.dart';
import '../../sessions/data/task_model_prefs.dart';
import '../../sessions/domain/task_profile.dart';
import '../../sessions/presentation/model_picker.dart';
import '../../system/presentation/system_screen.dart';
import 'audit_log_screen.dart';
import 'devices_screen.dart';
import '../../schedules/presentation/schedules_screen.dart';
import 'server_settings_screen.dart';

/// App settings: connection info, appearance, and a confirmed sign-out.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key, required this.creds});
  final Creds creds;

  Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text('You’ll need to pair this device again to reconnect.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Sign out')),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(tokenStoreProvider).clear();
    ref.invalidate(credsProvider); // app root routes back to pairing
    if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  Future<void> _copyLogs(BuildContext context) async {
    final log = await AppLog.read();
    await Clipboard.setData(ClipboardData(text: log));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(log.isEmpty ? 'Log is empty' : 'Copied ${log.length} chars of log')),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = ref.watch(themeModeProvider) == ThemeMode.dark;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const _SectionHeader('Connection'),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('Daemon'),
            subtitle: Text(creds.baseUrl),
          ),
          const _SectionHeader('Claude chat'),
          // Mode a NEW Claude session starts in (proposal 25). Existing sessions
          // keep their own mode — change it from the chip in the chat.
          ListTile(
            leading: Icon(ref.watch(defaultSessionModeProvider).icon),
            title: const Text('Default mode for new sessions'),
            subtitle: Text(ref.watch(defaultSessionModeProvider).description),
            trailing: DropdownButton<SessionMode>(
              value: ref.watch(defaultSessionModeProvider),
              underline: const SizedBox.shrink(),
              items: [
                for (final m in SessionMode.values) DropdownMenuItem(value: m, child: Text(m.label)),
              ],
              onChanged: (m) {
                if (m != null) ref.read(defaultSessionModeProvider.notifier).set(m);
              },
            ),
          ),
          _TaskModels(creds: creds),
          const _SectionHeader('Server'),
          ListTile(
            leading: const Icon(Icons.rule_folder_outlined),
            title: const Text('Session rules & storage'),
            subtitle: const Text('What every session is told about disk space, and the disk limits'),
            onTap: () => Navigator.of(context).push(sharedAxisRoute(ServerSettingsScreen(creds: creds))),
          ),
          ListTile(
            leading: const Icon(Icons.schedule_outlined),
            title: const Text('Scheduled tasks'),
            subtitle: const Text('Prompts the server runs on its own, on a timetable'),
            onTap: () => Navigator.of(context).push(sharedAxisRoute(SchedulesScreen(creds: creds))),
          ),
          const _SectionHeader('Security'),
          ListTile(
            leading: const Icon(Icons.devices_other_outlined),
            title: const Text('Paired devices'),
            subtitle: const Text('Revoke a lost or unused device'),
            onTap: () => Navigator.of(context).push(sharedAxisRoute(DevicesScreen(creds: creds))),
          ),
          ListTile(
            leading: const Icon(Icons.monitor_heart_outlined),
            title: const Text('Server health'),
            subtitle: const Text('CPU, memory, disks, GPU and services'),
            onTap: () => Navigator.of(context).push(sharedAxisRoute(SystemScreen(creds: creds))),
          ),
          ListTile(
            leading: const Icon(Icons.receipt_long_outlined),
            title: const Text('Audit log'),
            subtitle: const Text('Every permission decision and lifecycle event'),
            onTap: () => Navigator.of(context).push(sharedAxisRoute(AuditLogScreen(creds: creds))),
          ),
          ListTile(
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('Copy logs'),
            subtitle: const Text('This device’s error log, for bug reports'),
            onTap: () => _copyLogs(context),
          ),
          const _SectionHeader('Appearance'),
          SwitchListTile(
            secondary: const Icon(Icons.dark_mode_outlined),
            title: const Text('Dark theme'),
            value: isDark,
            onChanged: (_) => ref.read(themeModeProvider.notifier).toggle(),
          ),
          const Divider(),
          ListTile(
            leading: Icon(Icons.logout, color: scheme.error),
            title: Text('Sign out', style: TextStyle(color: scheme.error)),
            onTap: () => _signOut(context, ref),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Spacing.lg, Spacing.lg, Spacing.lg, Spacing.xs),
      child: Text(
        text.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.primary),
      ),
    );
  }
}

/// What each kind of work is best started on (docs/WORKFLOW.md, agent setup): judgment-heavy work
/// on the strongest model, defined implementation on Sonnet, quick questions on Haiku.
@visibleForTesting
String taskModelHint(TaskKind k) => switch (k) {
      TaskKind.plan => 'Opus',
      TaskKind.review => 'Opus',
      TaskKind.implement => 'Sonnet',
      TaskKind.quick => 'Haiku',
    };

/// Model per task (ADR 0016 follow-up): a prompt that starts a new session
/// preselects the model mapped to the kind of work it reads as.
class _TaskModels extends StatefulWidget {
  const _TaskModels({required this.creds});
  final Creds creds;

  @override
  State<_TaskModels> createState() => _TaskModelsState();
}

class _TaskModelsState extends State<_TaskModels> {
  final _models = <TaskKind, ({String id, String label})?>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    for (final k in TaskKind.values) {
      _models[k] = await TaskModelPrefs.get(k);
    }
    if (mounted) setState(() {});
  }

  Future<void> _pick(TaskKind k) async {
    final c = await chooseModel(context, SessionApi(dioFor(widget.creds)), title: 'Model for ${k.label}');
    if (c == null) return;
    final id = c.id;
    await TaskModelPrefs.set(k, id == null ? null : (id: id, label: c.label ?? id));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      leading: const Icon(Icons.tune),
      title: const Text('Main model per task'),
      subtitle: const Text('Prompts that start a chat preselect these. Helpers inside a chat are the server\'s agents.'),
      children: [
        for (final k in TaskKind.values)
          ListTile(
            contentPadding: const EdgeInsets.only(left: Spacing.xl * 2, right: Spacing.md),
            title: Text(k.label),
            subtitle: Text(_models[k]?.label ?? 'Server default · suggested: ${taskModelHint(k)}'),
            onTap: () => _pick(k),
            trailing: _models[k] == null
                ? null
                : IconButton(
                    tooltip: 'Clear',
                    icon: const Icon(Icons.clear),
                    onPressed: () async {
                      await TaskModelPrefs.set(k, null);
                      await _load();
                    },
                  ),
          ),
      ],
    );
  }
}
