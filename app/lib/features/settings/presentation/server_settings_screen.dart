import 'package:flutter/material.dart';

import '../../../core/providers.dart';
import '../../../core/spacing.dart';
import '../../../core/token_store.dart';
import '../../../core/widgets.dart';
import '../../system/presentation/system_screen.dart';
import '../data/server_settings_api.dart';

/// Session rules & storage (ADR 0026): what every session is told about where data may
/// live, when the server warns about a full disk, and when it refuses new work.
class ServerSettingsScreen extends StatefulWidget {
  const ServerSettingsScreen({super.key, required this.creds, this.api});
  final Creds creds;

  /// Tests inject a fake; production builds one from [creds].
  final ServerSettingsApi? api;

  @override
  State<ServerSettingsScreen> createState() => _ServerSettingsScreenState();
}

class _ServerSettingsScreenState extends State<ServerSettingsScreen> {
  late final ServerSettingsApi _api = widget.api ?? ServerSettingsApi(dioFor(widget.creds));
  ServerSettings? _s;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await _api.fetch();
      if (mounted) setState(() => _s = s);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _save(Map<String, Object?> values) async {
    setState(() => _saving = true);
    try {
      final s = await _api.update(values);
      if (mounted) setState(() => _s = s);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _editNumber(String key, String title, String suffix) async {
    final def = _s![key]!;
    final value = await showDialog<num>(
      context: context,
      builder: (_) => NumberSettingDialog(title: title, setting: def, suffix: suffix),
    );
    if (value != null) await _save({key: value});
  }

  Future<void> _editRules() async {
    final text = await Navigator.of(context).push<String?>(
      sharedAxisRoute(RulesEditScreen(setting: _s!['rules.text']!)),
    );
    // '' is a real value (rules off in effect); the screen pops `null`-as-reset via '\u0000reset'.
    if (text == null) return;
    await _save({'rules.text': text == RulesEditScreen.resetToken ? null : text});
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Session rules & storage')),
      body: s == null
          ? (_error != null
              ? ErrorBody(message: _error!)
              : const Center(child: CircularProgressIndicator()))
          : ListView(children: [
              if (_saving) const LinearProgressIndicator(minHeight: 2),
              const _Header('Session rules'),
              SwitchListTile(
                secondary: const Icon(Icons.rule_outlined),
                title: const Text('Send rules to every session'),
                subtitle: const Text(
                  'Added to the system prompt of every chat started from this app, in every project. '
                  'Applies to sessions started after the change.',
                ),
                value: s.rulesEnabled,
                onChanged: _saving ? null : (v) => _save({'rules.enabled': v}),
              ),
              ListTile(
                enabled: s.rulesEnabled,
                leading: const Icon(Icons.edit_note_outlined),
                title: const Text('Rules text'),
                subtitle: Text(
                  s.rulesText.trim().isEmpty ? 'Empty — nothing is sent' : s.rulesText,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: s['rules.text']!.isDefault ? null : const Chip(label: Text('edited'), visualDensity: VisualDensity.compact),
                onTap: _saving ? null : _editRules,
              ),
              const _Header('Disk'),
              ListTile(
                leading: const Icon(Icons.notifications_active_outlined),
                title: const Text('Warn when a disk is fuller than'),
                subtitle: const Text('Sends a push once per cooldown while it stays over'),
                trailing: Text('${s.alertPercent.round()}%', style: theme.textTheme.titleMedium),
                onTap: _saving ? null : () => _editNumber('disk.alert_percent', 'Warn when a disk is fuller than', '%'),
              ),
              ListTile(
                leading: const Icon(Icons.block_outlined),
                title: const Text('Refuse new sessions below'),
                subtitle: const Text('Free space where the project lives. 0 turns the guard off.'),
                trailing: Text(s.minFreeGb == 0 ? 'off' : '${_fmt(s.minFreeGb)} GB', style: theme.textTheme.titleMedium),
                onTap: _saving ? null : () => _editNumber('disk.min_free_gb', 'Refuse new sessions below', 'GB free'),
              ),
              ListTile(
                leading: const Icon(Icons.folder_special_outlined),
                title: const Text('Warn when daemon data passes'),
                subtitle: const Text('Chat transcripts, rewind backups, the database and worktrees. 0 turns it off.'),
                trailing: Text(s.daemonDataAlertGb == 0 ? 'off' : '${_fmt(s.daemonDataAlertGb)} GB', style: theme.textTheme.titleMedium),
                onTap: _saving ? null : () => _editNumber('disk.daemon_data_alert_gb', 'Warn when daemon data passes', 'GB'),
              ),
              ListTile(
                leading: const Icon(Icons.storage_outlined),
                title: const Text('Disk usage'),
                subtitle: const Text('Every monitored drive, live'),
                onTap: () => Navigator.of(context).push(sharedAxisRoute(SystemScreen(creds: widget.creds))),
              ),
              Padding(
                padding: const EdgeInsets.all(Spacing.lg),
                child: Text(
                  'Rules are advice to the model, not a lock — the real limits are the redirected cache '
                  'folders, the file-scope check in Auto mode, and the free-space guard above.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ]),
    );
  }

  static String _fmt(num n) => n == n.roundToDouble() ? '${n.round()}' : n.toStringAsFixed(1);
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(Spacing.lg, Spacing.lg, Spacing.lg, Spacing.xs),
        child: Text(text.toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}

/// Checks [raw] against a numeric [setting]'s own limits. Returns the number, or an
/// error message. Pure → tested; the daemon re-validates, this just saves a round trip.
@visibleForTesting
({num? value, String? error}) parseSettingNumber(String raw, ServerSetting setting) {
  final v = num.tryParse(raw.trim());
  if (v == null) return (value: null, error: 'Enter a number');
  if (setting.type == 'int' && v != v.roundToDouble()) return (value: null, error: 'Whole numbers only');
  final lo = setting.min, hi = setting.max;
  if (lo != null && v < lo) return (value: null, error: 'At least $lo');
  if (hi != null && v > hi) return (value: null, error: 'At most $hi');
  return (value: v, error: null);
}

class NumberSettingDialog extends StatefulWidget {
  const NumberSettingDialog({super.key, required this.title, required this.setting, required this.suffix});
  final String title;
  final ServerSetting setting;
  final String suffix;

  @override
  State<NumberSettingDialog> createState() => _NumberSettingDialogState();
}

class _NumberSettingDialogState extends State<NumberSettingDialog> {
  late final _c = TextEditingController(text: '${widget.setting.value}');
  String? _error;

  void _submit() {
    final r = parseSettingNumber(_c.text, widget.setting);
    if (r.error != null) {
      setState(() => _error = r.error);
    } else {
      Navigator.pop(context, r.value);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: TextField(
          controller: _c,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(suffixText: widget.suffix, errorText: _error, helperText: 'Default ${widget.setting.defaultValue}'),
          onSubmitted: (_) => _submit(),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          if (!widget.setting.isDefault)
            TextButton(onPressed: () => Navigator.pop(context, widget.setting.defaultValue as num), child: const Text('Default')),
          FilledButton(onPressed: _submit, child: const Text('Save')),
        ],
      );
}

/// Edit the rules text. Pops the new text, or [resetToken] to restore the default.
class RulesEditScreen extends StatefulWidget {
  const RulesEditScreen({super.key, required this.setting});
  final ServerSetting setting;
  static const resetToken = '\u0000reset';

  @override
  State<RulesEditScreen> createState() => _RulesEditScreenState();
}

class _RulesEditScreenState extends State<RulesEditScreen> {
  late final _c = TextEditingController(text: widget.setting.value as String);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final max = widget.setting.maxLen ?? 4000;
    final over = _c.text.length > max;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Rules text'),
        actions: [
          TextButton(
            onPressed: widget.setting.isDefault && _c.text == widget.setting.defaultValue
                ? null
                : () => Navigator.pop(context, RulesEditScreen.resetToken),
            child: const Text('Reset'),
          ),
          TextButton(onPressed: over ? null : () => Navigator.pop(context, _c.text), child: const Text('Save')),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(Spacing.md),
        child: TextField(
          controller: _c,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            hintText: 'What every session should know…',
            counterText: '${_c.text.length} / $max',
            errorText: over ? 'Too long — the limit is $max characters' : null,
          ),
        ),
      ),
    );
  }
}
