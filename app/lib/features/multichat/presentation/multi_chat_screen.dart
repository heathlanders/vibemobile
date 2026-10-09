import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../core/reconnect.dart';
import '../../../core/spacing.dart';
import '../../../core/token_store.dart';
import '../../../core/widgets.dart';
import '../../chat/data/transcript_cache.dart';
import '../../chat/presentation/chat_controller_pool.dart';
import '../../chat/presentation/chat_screen.dart';
import '../../chat/presentation/chat_session_controller.dart';
import '../../sessions/data/session_api.dart';
import '../../notifications/data/push_service.dart';
import '../../sessions/domain/session.dart';
import '../data/multi_chat_prefs.dart';
import 'session_tile.dart';

/// Grid shape for [n] tiles (proposal 19): fills the viewport exactly, biased to
/// taller cells in portrait and wider cells in landscape. Pure → unit-tested.
@visibleForTesting
(int cols, int rows) gridDims(int n, bool landscape) {
  if (n <= 1) return (1, 1);
  if (n == 2) return landscape ? (2, 1) : (1, 2);
  if (n <= 4) return (2, 2);
  return landscape ? (3, 2) : (2, 3);
}

/// Multi-chat grid (proposal 19): up to [maxTiles] live Claude sessions at once,
/// each a streaming [SessionTile]. Controllers come from [chatControllerPoolProvider]
/// — the daemon keeps one socket per session (latest attach wins), so a tile, its
/// expanded view and a workspace tab of the same session share one connection.
/// Leaving the screen releases this grid's holds; a controller closes once no
/// view holds it (the daemon replays history on the next attach).
class MultiChatScreen extends ConsumerStatefulWidget {
  const MultiChatScreen({super.key, required this.creds});
  final Creds creds;

  static const maxTiles = 6;

  @override
  ConsumerState<MultiChatScreen> createState() => _MultiChatScreenState();
}

class _MultiChatScreenState extends ConsumerState<MultiChatScreen> {
  late final SessionApi _api = SessionApi(dioFor(widget.creds));
  late final ChatControllerPool _pool = ref.read(chatControllerPoolProvider);

  // Insertion-ordered: map order is grid order and persisted order.
  final _sessions = <String, Session>{};
  final _controllers = <String, ChatSessionController>{};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  /// Restore the persisted grid: keep only ids that are still live claude
  /// sessions (prune dead/deleted ones and re-save the trimmed list).
  Future<void> _restore() async {
    try {
      final saved = await MultiChatPrefs.ids();
      final all = await _api.allSessions();
      final byId = {for (final s in all) s.id: s};
      if (!mounted) return;
      for (final id in saved) {
        final s = byId[id];
        if (s != null && s.kind == 'claude' && s.isLive && _sessions.length < MultiChatScreen.maxTiles) {
          _attach(s);
        }
      }
      _persist();
      setState(() => _loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  /// Create + start the session's controller — same construction as ChatScreen's
  /// owned path, minus initialMessage (grid tiles never prime a first turn).
  void _attach(Session s) {
    _sessions[s.id] = s;
    _controllers[s.id] = _pool.acquire(
      s.id,
      () => ChatSessionController(
        url: claudeUrl(widget.creds.baseUrl, s.id),
        token: widget.creds.token,
        cache: const TranscriptCache(),
        sessionId: s.id,
      ),
      onAuthFailed: _onAuthFailed,
    );
    PushService.registerVisible(s.id, _isOnScreen);
  }

  // Every tile is on screen while the grid route is the top one.
  bool _isOnScreen() => mounted && (ModalRoute.of(context)?.isCurrent ?? false);

  void _add(Session s) {
    if (_sessions.length >= MultiChatScreen.maxTiles || _sessions.containsKey(s.id)) return;
    setState(() => _attach(s));
    _persist();
  }

  /// Remove a tile: detach only — the daemon session stays live. Deleting a
  /// session remains the expanded ChatScreen's close action.
  void _remove(String id) {
    if (_controllers.remove(id) != null) _pool.release(id, _onAuthFailed);
    PushService.unregisterVisible(id, _isOnScreen);
    setState(() => _sessions.remove(id));
    _persist();
  }

  void _persist() => MultiChatPrefs.setIds(_sessions.keys.toList());

  Future<void> _onAuthFailed() async {
    await ref.read(tokenStoreProvider).clear();
    ref.invalidate(credsProvider);
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  Future<void> _expand(Session s) async {
    if (!_controllers.containsKey(s.id)) return;
    // ChatScreen takes the same pooled controller as the tile.
    await Navigator.of(context).push(sharedAxisRoute(ChatScreen(creds: widget.creds, session: s)));
    // The expanded view's close action deletes the session → socket closes with
    // a stop code; prune the dead tile instead of showing "ended" forever.
    if (mounted && _controllers[s.id]?.state == ConnState.ended) _remove(s.id);
  }

  /// Picker of live claude sessions not already on the grid (same list source as
  /// the session switcher).
  Future<void> _pickSession() async {
    final List<Session> candidates;
    final Map<String, String> names;
    try {
      final sessions = await _api.allSessions();
      final projects = await _api.projects();
      names = {for (final p in projects) p.id: p.label};
      candidates = sessions
          .where((s) => s.kind == 'claude' && s.isLive && !_sessions.containsKey(s.id))
          .toList();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to list sessions: $e')));
      }
      return;
    }
    if (!mounted) return;
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No other live Claude sessions — start one from a project.')),
      );
      return;
    }
    final picked = await showModalBottomSheet<Session>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final s in candidates)
              ListTile(
                leading: const Icon(Icons.smart_toy_outlined),
                title: Text(s.label),
                subtitle: Text(names[s.projectId] ?? s.projectId),
                onTap: () => Navigator.pop(ctx, s),
              ),
          ],
        ),
      ),
    );
    if (picked != null && mounted) _add(picked);
  }

  @override
  void dispose() {
    for (final e in _controllers.entries) {
      _pool.release(e.key, _onAuthFailed);
      PushService.unregisterVisible(e.key, _isOnScreen);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Multi-chat'),
        actions: [
          IconButton(
            tooltip: 'Add session',
            icon: const Icon(Icons.add),
            onPressed: _sessions.length >= MultiChatScreen.maxTiles ? null : _pickSession,
          ),
        ],
      ),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text(_error!));
    if (_sessions.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('No sessions on the grid yet.'),
            const SizedBox(height: Spacing.md),
            FilledButton.icon(
              onPressed: _pickSession,
              icon: const Icon(Icons.add),
              label: const Text('Add session'),
            ),
          ],
        ),
      );
    }
    final tiles = _sessions.values.toList();
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    final (cols, rows) = gridDims(tiles.length, landscape);
    return Padding(
      padding: const EdgeInsets.all(Spacing.xs),
      child: Column(
        children: [
          for (var r = 0; r < rows; r++)
            Expanded(
              child: Row(
                children: [
                  for (var c = 0; c < cols; c++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(Spacing.xs / 2),
                        child: (r * cols + c) < tiles.length ? _tile(tiles[r * cols + c]) : const SizedBox(),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _tile(Session s) => SessionTile(
        session: s,
        controller: _controllers[s.id]!,
        onTap: () => _expand(s),
        onRemove: () => _remove(s.id),
      );
}
