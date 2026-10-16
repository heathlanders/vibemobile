import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';

import '../../../core/reconnect.dart';
import '../../notifications/data/push_service.dart';
import '../data/claude_socket.dart';
import '../data/transcript_cache.dart';
import '../domain/chat_message.dart';
import '../domain/context_usage.dart';
import '../domain/mcp_server.dart';
import '../domain/slash_command.dart';
import '../domain/session_mode.dart';
import '../domain/session_usage.dart';
import '../domain/turn_status.dart';

/// Owns one Claude session: connect → stream frames into a message list, surface
/// tool-permission requests, and reconnect on drop (reusing core/reconnect.dart,
/// same policy as the terminal). The session lives server-side (in-daemon
/// registry); reconnect replays `history` then resumes live (claude-ws.md).
class ChatSessionController extends ChangeNotifier with WidgetsBindingObserver {
  ChatSessionController({
    required this.url,
    required this.token,
    this.initialMessage,
    this.cache,
    this.sessionId,
  });

  final Uri url;
  final String token;

  /// If set, sent as the first user turn once the session is live (e.g. a filled
  /// prompt from the library). Sent exactly once.
  final String? initialMessage;
  bool _sentInitial = false;
  final _queued = <String>[];

  /// A first turn handed over by a later view of an already-pooled controller
  /// (e.g. a prompt sent into a session that's open in a tab): sent now if
  /// live, else once connected.
  void sendWhenLive(String text) {
    if (state == ConnState.live) {
      sendUser(text);
    } else {
      _queued.add(text);
    }
  }

  /// The session's mode (proposal 25), as the daemon last reported it. Null until
  /// the first `mode` frame (and for old daemons) — the chip hides meanwhile.
  /// Never sent on (re)connect: the daemon is the source of truth, so a reconnect
  /// can't clobber a mid-session Plan.
  SessionMode? mode;

  /// The session's model as the daemon last reported it (`model` frame), and whether
  /// it can be switched live. Native-engine sessions never send the frame, so
  /// [canSwitchModel] stays false and the menu item stays hidden.
  String? model;
  bool canSwitchModel = false;

  /// Reasoning effort (proposal 39): the current level (`null` = the model's default) and
  /// the levels the daemon accepts. Empty [effortLevels] (native engine, old daemon) hides
  /// the menu entry.
  String? effort;
  List<String> effortLevels = const [];

  /// Latest context-window reading (proposal 40); null until the daemon sends one
  /// (native engine, old daemon, or before the first turn).
  ContextUsage? context;

  /// Skills / project commands the session can run as `/name` (proposal 41); empty until
  /// the daemon sends them (native engine, old daemon).
  List<SlashCommandInfo> slashCommands = const [];

  /// MCP servers of this session (proposal 43); null until the daemon has answered
  /// `requestMcp()`. [mcpTruncated]: the daemon capped the list or a tool list.
  List<McpServerInfo>? mcpServers;
  bool mcpTruncated = false;

  /// True for a Claude-engine session: only that engine sends `model` / `effort` frames.
  bool get isClaudeEngine => canSwitchModel || effortLevels.isNotEmpty;

  /// Modes this session's engine supports (native sessions have no Plan).
  List<SessionMode> availableModes = const [];

  /// Optional offline transcript cache, keyed by [sessionId].
  final TranscriptCache? cache;
  final String? sessionId;
  bool _connectedOnce = false;

  /// True when we've never reached the daemon and are retrying/ended — the UI
  /// shows an "offline, cached transcript" banner over the cached messages.
  bool get offline => !_connectedOnce && (state == ConnState.reconnecting || state == ConnState.ended);

  final List<ChatMessage> messages = [];
  PermissionRequest? pendingPermission;
  UserDialog? pendingDialog;
  ConnState state = ConnState.connecting;

  /// Running session spend in USD (proposal 03), from `init`/`result` frames.
  /// Real for native (pay-per-token) sessions; on a Max subscription the daemon
  /// leaves this at 0 and sends [usage] instead.
  double sessionCost = 0;

  /// Real Max-plan usage (5-hour session + weekly per-model limits), from `usage`
  /// frames. Null for native sessions (which use [sessionCost] instead).
  SessionUsage? usage;

  /// Set while a `claude` CLI on the server owns this session (ADR 0012): the
  /// daemon mirrors its transcript instead of running the Agent SDK. Cleared by
  /// every `history` (a mirror re-sends it right after).
  ExternalRun? external;

  /// Server-side display title (ADR 0009), from `title` frames. Null until the
  /// daemon auto-names the session; the UI falls back to `Session.label`.
  String? title;

  /// A turn is in flight (proposal 09): true from a sent user turn until `result`.
  /// Drives the composer's send↔stop toggle.
  bool busy = false;

  /// The running turn's phase / elapsed / stall state for the status line
  /// (proposal 32). Null when idle. The daemon's `status` frames are
  /// authoritative — including on reattach, which fixes a stuck or missing [busy].
  TurnStatus? turn;

  /// Re-auth needed (4401 / 401 upgrade) — host clears the token, routes to pairing.
  VoidCallback? onAuthFailed;

  ClaudeSocket? _socket;
  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _retry;
  int _attempt = 0;
  bool _disposed = false;
  bool _stopped = false;
  // Backgrounded: socket closed on purpose so the daemon sees no client and
  // pushes instead (ADR 0013). Resume reconnects; no retry while paused.
  bool _paused = false;
  bool _observing = false;
  ChatMessage? _streaming; // the assistant bubble currently being built by deltas
  ChatMessage? _thinking; // the thinking row currently being built by thinking_delta

  void start() {
    WidgetsBinding.instance.addObserver(this);
    _observing = true;
    _loadCache();
    _connect();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `inactive` (notification shade, app switcher peek) keeps the socket.
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) {
      _pause();
    } else if (state == AppLifecycleState.resumed) {
      _resume();
    }
  }

  void _pause() {
    if (_paused || _disposed || _stopped) return;
    _paused = true;
    _retry?.cancel();
    _sub?.cancel();
    _sub = null;
    _socket?.close();
    _socket = null;
  }

  void _resume() {
    if (!_paused || _disposed) return;
    _paused = false;
    _attempt = 0;
    _connect();
  }

  Future<void> _loadCache() async {
    if (cache == null || sessionId == null) return;
    final cached = await cache!.load(sessionId!);
    // Only seed from cache if the live `history` hasn't already populated us.
    if (_disposed || messages.isNotEmpty || cached.isEmpty) return;
    messages.addAll(cached);
    notifyListeners();
  }

  void _saveCache() {
    if (cache != null && sessionId != null) cache!.save(sessionId!, messages);
  }

  Future<void> _connect() async {
    if (_disposed || _stopped || _paused) return;
    _set(_attempt == 0 ? ConnState.connecting : ConnState.reconnecting);
    try {
      final socket = await ClaudeSocket.connect(url: url, token: token);
      if (_paused || _disposed) {
        socket.close(); // backgrounded mid-connect
        return;
      }
      _socket = socket;
      _attempt = 0;
      _connectedOnce = true;
      _set(ConnState.live);
      if (initialMessage != null && !_sentInitial) {
        _sentInitial = true;
        sendUser(initialMessage!);
      }
      for (final t in _queued) {
        sendUser(t);
      }
      _queued.clear();
      _sub = socket.frames.listen(
        applyFrame,
        onDone: () => _onClosed(socket.closeCode),
        onError: (_) => _onClosed(socket.closeCode),
      );
    } catch (e) {
      if (looksLikeAuthError(e)) {
        _fail();
      } else {
        _onClosed(null);
      }
    }
  }

  /// Frame → state reducer (claude-ws.md). Public for unit testing.
  @visibleForTesting
  void applyFrame(Map<String, dynamic> f) {
    switch (f['t']) {
      case 'history':
        messages.clear();
        _streaming = null;
        _thinking = null;
        external = null;
        for (final m in (f['messages'] as List? ?? const [])) {
          _applyHistoryRow(m as Map<String, dynamic>);
        }
      case 'external':
        external = ExternalRun(status: f['status'] as String? ?? '', canReply: f['canReply'] == true);
        busy = external!.busy;
      case 'status':
        final running = f['running'] == true;
        busy = running;
        turn = running ? TurnStatus.fromFrame(f, DateTime.now()) : null;
      case 'model':
        model = f['model'] as String?;
        canSwitchModel = f['canSwitch'] == true;
      case 'effort':
        effort = f['effort'] as String?;
        effortLevels = [for (final l in (f['levels'] as List? ?? const [])) '$l'];
      case 'mcp':
        mcpServers = [
          if (f['servers'] is List)
            for (final s in f['servers'] as List) ?McpServerInfo.tryFromJson(s),
        ];
        mcpTruncated = f['truncated'] == true;
      case 'commands':
        slashCommands = [
          if (f['commands'] is List)
            for (final c in f['commands'] as List) ?SlashCommandInfo.tryFromJson(c),
        ];
      case 'context':
        context = ContextUsage.fromFrame(f);
      case 'compacted':
        // The SDK summarized earlier turns. A persisted notice row replays this after a
        // reattach (history), so the live frame and the replay never both show.
        messages.add(ChatMessage(role: ChatRole.notice, text: f['text'] as String? ?? 'Context compacted'));
      case 'user_ack':
        // Daemon row id of the turn we just sent (FIFO: newest user bubble without
        // one) — enables "rewind files to here" without a reattach.
        final id = f['messageId'] as String?;
        final i = messages.lastIndexWhere((m) => m.role == ChatRole.user && m.serverId == null);
        if (id != null && i >= 0) messages[i].serverId = id;
      case 'user_turn':
        // A user turn typed on another device (proposal 58) or on the PC — or our own
        // reply echoed back through the CLI's transcript (sendUser doesn't add it
        // locally while mirroring).
        messages.add(ChatMessage(
          role: ChatRole.user,
          text: f['text'] as String? ?? '',
          images: ((f['images'] as List?) ?? const []).cast<String>(),
          ts: f['ts'] as String?,
          serverId: f['messageId'] as String?,
        ));
      case 'delta':
        (_streaming ??= _newAssistantBubble()).text += (f['text'] as String? ?? '');
      case 'thinking_delta':
        (_thinking ??= _newThinkingBubble()).text += (f['text'] as String? ?? '');
      case 'thinking':
        // The final summarized block: replaces what the deltas built (or stands alone
        // when the client attached after the deltas went by).
        final thought = f['text'] as String? ?? '';
        if (_thinking != null) {
          _thinking!
            ..text = thought
            ..streaming = false;
          _thinking = null;
        } else if (thought.isNotEmpty) {
          messages.add(ChatMessage(role: ChatRole.thinking, text: thought));
        }
      case 'assistant':
        final text = f['text'] as String? ?? '';
        if (_streaming != null) {
          _streaming!
            ..text = text
            ..streaming = false;
          _streaming = null;
        } else {
          messages.add(ChatMessage(role: ChatRole.assistant, text: text));
        }
      case 'tool_use':
        messages.add(ChatMessage(
          role: ChatRole.tool,
          toolName: f['name'] as String?,
          toolInput: (f['input'] as Map?)?.cast<String, dynamic>(),
          toolUseId: f['id'] as String?,
        ));
      case 'tool_result':
        // Attach to the matching tool chip by id (proposal 07).
        final id = f['toolUseID'] as String?;
        for (final m in messages.reversed) {
          if (m.role == ChatRole.tool && m.toolUseId == id) {
            m.toolResult = f['content'] as String? ?? '';
            m.toolResultIsError = f['isError'] as bool? ?? false;
            m.images = ((f['images'] as List?) ?? const []).cast<String>();
            break;
          }
        }
      case 'permission_request':
        pendingPermission = PermissionRequest(
          toolUseID: f['toolUseID'] as String,
          toolName: f['toolName'] as String? ?? 'tool',
          title: f['title'] as String?,
          displayName: f['displayName'] as String?,
          description: f['description'] as String?,
          input: (f['input'] as Map?)?.cast<String, dynamic>(),
          // Optional, Edit/Write/MultiEdit only (proposal 02).
          diffPreview: f['diffPreview'] == null
              ? null
              : DiffPreview.fromJson((f['diffPreview'] as Map).cast<String, dynamic>()),
        );
        _notifyIfOffscreen(f);
      case 'user_dialog':
        final d = UserDialog(
          dialogId: f['dialogId'] as String,
          dialogKind: f['dialogKind'] as String? ?? '',
          payload: (f['payload'] as Map?)?.cast<String, dynamic>() ?? const {},
        );
        // Question and plan-approval dialogs are renderable. Auto-cancel anything
        // else so an unknown dialog kind can never hang the session (claude-ws.md).
        if (d.questions.isEmpty && !d.isExitPlan) {
          _socket?.sendDialogResponse(d.dialogId, completed: false);
        } else {
          pendingDialog = d;
          _notifyIfOffscreen(f);
        }
      case 'mode':
        // Daemon-authoritative (proposal 25): sent on attach and after every change.
        mode = SessionMode.fromWire(f['mode']) ?? mode;
        availableModes = [
          for (final m in (f['available'] as List? ?? const [])) ?SessionMode.fromWire(m),
        ];
      case 'dialog_closed':
        // A question got answered (here, on another device, or on the PC in
        // Mirror mode) or timed out: drop the card.
        if (pendingDialog?.dialogId == f['dialogId']) pendingDialog = null;
        if (f['dialogId'] is String) unawaited(PushService.cancelPrompt(f['dialogId'] as String));
      case 'permission_closed':
        // Another device answered (or it timed out): drop the approval card.
        if (pendingPermission?.toolUseID == f['toolUseID']) pendingPermission = null;
        if (f['toolUseID'] is String) unawaited(PushService.cancelPrompt(f['toolUseID'] as String));
      case 'result':
        _streaming = null;
        _thinking = null;
        busy = false;
        turn = null;
        if (f['sessionCost'] is num) sessionCost = (f['sessionCost'] as num).toDouble();
      case 'usage':
        if (f['usage'] is Map) {
          usage = SessionUsage.fromJson((f['usage'] as Map).cast<String, dynamic>());
        }
      case 'error':
        busy = false;
        turn = null;
        messages.add(ChatMessage(role: ChatRole.error, text: f['message'] as String? ?? 'error'));
      case 'init':
        if (f['sessionCost'] is num) sessionCost = (f['sessionCost'] as num).toDouble();
      case 'title':
        // Server auto-titled the session (ADR 0009); the app bar reads this.
        title = f['title'] as String?;
    }
    notifyListeners();
    // Persist when durable content changed (not on transient deltas).
    if (f['t'] case 'history' || 'assistant' || 'result' || 'tool_use') _saveCache();
  }

  void _applyHistoryRow(Map<String, dynamic> m) {
    final role = ChatRole.values.firstWhere((e) => e.name == m['role'], orElse: () => ChatRole.assistant);
    if (role == ChatRole.tool) {
      final j = m['tool_json'] as String?;
      final decoded = j != null ? jsonDecode(j) as Map<String, dynamic> : const {};
      messages.add(ChatMessage(
        role: ChatRole.tool,
        toolName: decoded['name'] as String?,
        toolInput: (decoded['input'] as Map?)?.cast<String, dynamic>(),
        toolUseId: decoded['id'] as String?,
        // The tool result is folded onto this row server-side (proposal 07).
        toolResult: decoded['result'] as String?,
        toolResultIsError: decoded['isError'] as bool? ?? false,
        images: ((decoded['images'] as List?) ?? const []).cast<String>(),
      ));
    } else {
      final text = m['content'] as String? ?? '';
      // A user turn's images arrive as [{id, mediaType}] refs (claude-ws.md
      // history replay); we only need each id to lazy-fetch the thumbnail.
      final images = ((m['images'] as List?) ?? const [])
          .map((e) => (e as Map)['id'] as String)
          .toList();
      if (text.isNotEmpty || images.isNotEmpty) {
        messages.add(ChatMessage(role: role, text: text, images: images, ts: m['ts'] as String?, serverId: m['id'] as String?));
      }
    }
  }

  ChatMessage _newThinkingBubble() {
    final m = ChatMessage(role: ChatRole.thinking, streaming: true);
    messages.add(m);
    return m;
  }

  ChatMessage _newAssistantBubble() {
    final m = ChatMessage(role: ChatRole.assistant, streaming: true);
    messages.add(m);
    return m;
  }

  void sendUser(String text, {List<String> images = const []}) {
    if (text.trim().isEmpty && images.isEmpty) return;
    // Mirroring: the turn comes back as `user_turn` once the CLI takes it.
    if (external == null) messages.add(ChatMessage(role: ChatRole.user, text: text, images: images));
    _socket?.sendUser(text, images: images);
    busy = true; // turn in flight until `result` (proposal 09)
    turn ??= TurnStatus.local(DateTime.now()); // until the daemon's first status frame
    _saveCache();
    notifyListeners();
  }

  /// Ask the daemon for this session's MCP servers; the answer arrives as an `mcp` frame.
  void requestMcp() => _socket?.sendGetMcp();

  /// `reconnect` | `enable` | `disable` — the daemon refreshes the list afterwards.
  void mcpAction(String server, String action) => _socket?.sendMcpAction(server, action);

  /// Compact the conversation now; ignored by the daemon while a turn is running.
  void compact() => _socket?.sendCompact();

  /// Ask the daemon to change this session's reasoning effort ([level] null = default).
  void setEffort(String? level) => _socket?.sendSetEffort(level);

  /// Ask the daemon to switch this session to [id] (a plain Claude model id).
  void switchModel(String id) => _socket?.sendSetModel(id);

  /// Cancel the in-flight turn (proposal 09). The session stays live; the daemon
  /// finalizes with a result, which clears [busy].
  void interrupt() => _socket?.sendInterrupt();

  /// Retry a prior user turn (proposal 11): mark the original superseded and
  /// append a fresh, verbatim copy. No history rewrite — the SDK transcript is
  /// append-only; Claude's context already holds the earlier exchange.
  void resendUser(ChatMessage original) {
    if (original.role != ChatRole.user) return;
    original.superseded = true;
    sendUser(original.text, images: original.images);
  }

  /// Ask the daemon to switch modes (proposal 25). The chip updates when the
  /// daemon echoes its `mode` frame, so it never shows a mode that didn't apply.
  void setMode(SessionMode m) {
    if (m == mode || !availableModes.contains(m)) return;
    _socket?.sendMode(m.wire);
  }

  /// Answer the pending plan-approval dialog (proposal 25). Approve returns to
  /// [approveMode] (`auto`/`ask`; null = where the session was before plan).
  /// Keep planning denies with optional [feedback] so the model revises.
  void respondExitPlan({required bool approve, SessionMode? approveMode, String? feedback}) {
    final d = pendingDialog;
    if (d == null || !d.isExitPlan) return;
    _socket?.sendDialogResponse(d.dialogId, completed: true, result: {
      'approve': approve,
      if (approve && approveMode != null) 'mode': approveMode.wire,
      if (!approve && feedback != null && feedback.trim().isNotEmpty) 'feedback': feedback.trim(),
    });
    pendingDialog = null;
    notifyListeners();
  }

  void respondPermission(bool allow) {
    final p = pendingPermission;
    if (p == null) return;
    _socket?.sendPermission(p.toolUseID, allow);
    pendingPermission = null;
    notifyListeners();
  }

  /// Answer the pending question dialog. [answers] maps each question's text to
  /// the chosen option label (multi-select: comma-joined) — the AskUserQuestion
  /// result contract (claude-ws.md).
  void respondDialog(Map<String, String> answers) {
    final d = pendingDialog;
    if (d == null) return;
    _socket?.sendDialogResponse(d.dialogId, completed: true, result: {
      'questions': d.payload['questions'],
      'answers': answers,
    });
    pendingDialog = null;
    notifyListeners();
  }

  void cancelDialog() {
    final d = pendingDialog;
    if (d == null) return;
    _socket?.sendDialogResponse(d.dialogId, completed: false);
    pendingDialog = null;
    notifyListeners();
  }

  // Attached but not on screen (another chat/dir open): the daemon won't push,
  // so raise it locally. Visible sessions are skipped inside notifyPrompt.
  void _notifyIfOffscreen(Map<String, dynamic> f) {
    final id = sessionId;
    if (id != null) unawaited(PushService.notifyPrompt(id, title, f));
  }

  void _onClosed(int? code) {
    _sub?.cancel();
    _sub = null;
    _socket = null;
    if (_disposed || _stopped || _paused) return;
    switch (actionForCloseCode(code)) {
      case CloseAction.stop:
        _stopped = true;
        _set(ConnState.ended);
      case CloseAction.reauth:
        _fail();
      case CloseAction.retry:
        final delay = backoffDelay(_attempt);
        _attempt++;
        _set(ConnState.reconnecting);
        _retry = Timer(delay, _connect);
    }
  }

  void _fail() {
    _stopped = true;
    _set(ConnState.authFailed);
    onAuthFailed?.call();
  }

  void _set(ConnState s) {
    if (_disposed) return;
    state = s;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    _retry?.cancel();
    _sub?.cancel();
    _socket?.close();
    super.dispose();
  }
}

/// A running CLI session being mirrored (`external` frame, claude-ws.md).
class ExternalRun {
  const ExternalRun({required this.status, required this.canReply});

  /// The CLI's own `busy` / `idle`.
  final String status;

  /// Started with `vc` (tmux) → replies and the Terminal view work.
  final bool canReply;

  bool get busy => status == 'busy';
}
