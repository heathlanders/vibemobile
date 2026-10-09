import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform.dart';
import '../../../core/providers.dart';
import '../../../core/spacing.dart';
import '../../notifications/data/push_service.dart';
import '../data/auth_api.dart';

/// First-run onboarding: enter the daemon URL + a one-time pairing code, exchange
/// it for a device token, store it. On success invalidates [credsProvider] so the
/// app root re-routes to the session list.
class PairingScreen extends ConsumerStatefulWidget {
  const PairingScreen({super.key});

  @override
  ConsumerState<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends ConsumerState<PairingScreen> {
  /// Known daemon URLs offered in the dropdown. The field stays editable, so
  /// new tailnets can still be typed in by hand.
  static const _presetUrls = <String>[
    'https://box.tailnet.ts.net/',
  ];

  final _baseUrl = TextEditingController(text: _presetUrls.first);
  final _code = TextEditingController();
  final _deviceName = TextEditingController(text: isMobile ? 'phone' : 'desktop');
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _baseUrl.dispose();
    _code.dispose();
    _deviceName.dispose();
    super.dispose();
  }

  Future<void> _pair() async {
    final baseUrl = _baseUrl.text.trim();
    final code = _code.text.trim();
    final name = _deviceName.text.trim();
    if (baseUrl.isEmpty || code.isEmpty || name.isEmpty) {
      setState(() => _error = 'All fields are required.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final token = await AuthApi.pair(baseUrl: baseUrl, code: code, deviceName: name);
      await ref.read(tokenStoreProvider).save(baseUrl, token);
      unawaited(PushService.registerToken()); // ADR 0013: now paired, the daemon can wake us
      ref.invalidate(credsProvider); // → app root routes to the session list
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pair this device')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Spacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownMenu<String>(
                controller: _baseUrl,
                initialSelection: _presetUrls.first,
                requestFocusOnTap: true,
                enableFilter: false,
                expandedInsets: EdgeInsets.zero,
                keyboardType: TextInputType.url,
                label: const Text('Daemon URL'),
                hintText: 'https://machine.tailnet.ts.net',
                onSelected: (v) {
                  if (v != null) _baseUrl.text = v;
                },
                dropdownMenuEntries: [
                  for (final u in _presetUrls) DropdownMenuEntry(value: u, label: u),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _code,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Pairing code',
                  hintText: 'XXXX-XXXX  (npm run pair:new)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _deviceName,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Device name',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                icon: _busy
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.link),
                label: Text(_busy ? 'Pairing…' : 'Pair'),
                onPressed: _busy ? null : _pair,
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
