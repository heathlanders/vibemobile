import 'dart:async';
import 'dart:convert';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../../usage/presentation/session_spend_sheet.dart';
import '../../../core/app_log.dart';
import '../../../core/platform.dart';
import '../../../core/providers.dart';
import '../../../core/reconnect.dart';
import '../../../core/session_attention.dart';
import '../../../core/spacing.dart';
import '../../../core/theme.dart';
import '../../../core/token_store.dart';
import '../../../core/widgets.dart';
import '../../notifications/data/push_service.dart';
import '../../prompts/data/prompt_api.dart';
import '../../prompts/domain/prompt.dart';
import '../../prompts/presentation/improve_prompt.dart';
import '../../sessions/data/session_api.dart';
import '../../sessions/domain/session.dart';
import '../../sessions/presentation/model_picker.dart';
import '../../terminal/presentation/terminal_screen.dart';
import '../data/attachment_api.dart';
import '../data/fork_api.dart';
import '../data/project_tree_api.dart';
import '../data/transcript_cache.dart';
import 'chat_image.dart';
import '../domain/chat_message.dart';
import '../domain/composer_triggers.dart';
import '../domain/handoff.dart';
import '../domain/paste_tokens.dart';
import '../domain/rollover.dart';
import '../domain/slash_command.dart';
import '../domain/image_normalize.dart';
import '../domain/image_paths.dart';
import '../domain/session_mode.dart';
import '../domain/session_usage.dart';
import '../domain/tool_groups.dart';
import '../domain/turn_status.dart';
import 'changed_files_sheet.dart';
import 'chat_controller_pool.dart';
import 'chat_session_controller.dart';
import 'composer_overlay.dart';
import 'diff_lines.dart';
import 'linkified_text.dart';
import 'paste_composer.dart';
import 'context_sheet.dart';
import 'branch_sheet.dart';
import 'ci_sheet.dart';
import 'effort_sheet.dart';
import '../../editor/presentation/editor_opener.dart';
import '../../files/data/project_files_api.dart';
import 'file_browser_screen.dart';
import 'markdown_text.dart';
import 'mcp_sheet.dart';
import 'mode_widgets.dart';
import 'rewind_sheet.dart';

/// A Claude chat for one session: streamed replies, tool-approval prompts, and
/// the same reconnect resilience as the terminal. Close = DELETE /sessions/:id.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({
    super.key,
    required this.creds,
    required this.session,
    this.initialMessage,
    this.initialImageBytes = const [],
    this.controller,
    this.onClose,
    this.onTitle,
    this.onOpenSession,
    this.initialDraft,
    this.onMenu,
  });

  final Creds creds;
  final Session session;

  /// Desktop workspace tab (ADR 0015): called after Close deletes the session,
  /// instead of popping a route — the tab isn't one.
  final VoidCallback? onClose;

  /// Desktop workspace tab: called with the daemon's display title (ADR 0009)
  /// whenever it arrives or changes, so the tab label follows auto-title renames.
  final void Function(String title)? onTitle;

  /// Where a session started from here opens (hand off, ADR 0016). The desktop
  /// workspace opens it as a tab; null replaces this route with its ChatScreen.
  final void Function(Session)? onOpenSession;

  /// Phone shell: shows a ☰ button as the app-bar leading that opens the navigation panel.
  final VoidCallback? onMenu;

  /// Text to put in the composer (not send) when the screen opens — a branch made "before"
  /// a message hands that message back for rewriting (proposal 42).
  final String? initialDraft;

  /// Injected controller (tests). When null — every real path — the screen takes
  /// the session's shared controller from [chatControllerPoolProvider], so a tab,
  /// a grid tile and an expanded view of one session ride one socket.
  final ChatSessionController? controller;

  /// Optional first user turn (e.g. a filled prompt from the library).
  final String? initialMessage;

  /// Images to pre-attach to the composer (e.g. shared in via the OS share
  /// sheet). Each is uploaded on open and parked in the tray until sent.
  final List<Uint8List> initialImageBytes;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

/// An image picked and uploaded for the next turn: the server-minted [id] rides
/// the `user` frame; [bytes] is the local preview shown in the composer tray.
class _PendingImage {
  _PendingImage(this.id, this.bytes);
  final String id;
  final Uint8List bytes;
}

class _ChatScreenState extends ConsumerState<ChatScreen> with WidgetsBindingObserver {
  late final ChatSessionController _controller;
  late final ChatControllerPool _pool; // read in initState: ref is unsafe in dispose
  late final AttachmentApi _attachments;
  final _picker = ImagePicker();
  // Large pastes collapse to chip tokens (proposal 47); expanded again on send.
  final _pastes = PasteTokens();
  late final _input = PasteTextController(_pastes);
  late final _inputFocus = FocusNode(onKeyEvent: _onComposerKey);

  /// Desktop: Enter sends, Shift+Enter inserts a newline. Phones keep the
  /// keyboard's own send action.
  KeyEventResult _onComposerKey(FocusNode _, KeyEvent e) {
    if (isMobile || e is! KeyDownEvent) return KeyEventResult.ignored;
    final kb = HardwareKeyboard.instance;
    if (e.logicalKey == LogicalKeyboardKey.keyV && (kb.isControlPressed || kb.isMetaPressed)) {
      unawaited(_paste());
      return KeyEventResult.handled;
    }
    // Shift+Tab cycles the session mode (ask → auto → plan). The chip updates
    // on the daemon's `mode` echo. A mirrored CLI owns its mode → normal focus.
    if (e.logicalKey == LogicalKeyboardKey.tab && kb.isShiftPressed && _controller.external == null) {
      final current = _controller.mode;
      final next = current == null ? null : nextMode(current, _controller.availableModes);
      if (next == null) return KeyEventResult.ignored;
      _controller.setMode(next);
      return KeyEventResult.handled;
    }
    // Plain Tab stays in the composer (two spaces) instead of moving focus to
    // the next GUI section. Ctrl+Tab is left for the workspace tab cycling.
    if (e.logicalKey == LogicalKeyboardKey.tab &&
        !kb.isShiftPressed &&
        !kb.isControlPressed &&
        !kb.isAltPressed &&
        !kb.isMetaPressed) {
      final v = _input.value;
      final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
      _input.value = v.copyWith(
        text: v.text.replaceRange(sel.start, sel.end, '  '),
        selection: TextSelection.collapsed(offset: sel.start + 2),
        composing: TextRange.empty,
      );
      return KeyEventResult.handled;
    }
    final enter = e.logicalKey == LogicalKeyboardKey.enter || e.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!enter || HardwareKeyboard.instance.isShiftPressed) return KeyEventResult.ignored;
    _send(); // also while busy: the daemon folds it into the running turn
    return KeyEventResult.handled;
  }
  final _scroll = ScrollController();
  final _speech = SpeechToText();
  bool _listening = false;
  String _textBeforeDictation = '';

  final List<_PendingImage> _pending = [];
  bool _uploading = false;

  // Tool-call runs the user expanded, keyed by the run's first call.
  final Set<ChatMessage> _openRuns = {};

  // Slash commands (proposal 22): the trigger under the caret, plus the prompt
  // library fetched lazily the first time `/prompt` is used.
  SlashTrigger? _trigger;
  List<Prompt>? _prompts;

  // `@file` mentions (ADR 0010): the mention under the caret and the last tree
  // response for it. Names only — the daemon never resolves the mention.
  MentionTrigger? _mention;
  String? _treeQuery; // query the current [_treeFiles] answer belongs to
  List<String> _treeFiles = const [];
  bool _treeTruncated = false;

  // Scroll/unread tracking (proposal 13): only auto-scroll when pinned to the
  // bottom; otherwise count new messages for the scroll-to-bottom FAB.
  bool _atBottom = true;
  int _unread = 0;
  int _lastLen = 0;
  // Whether the current permission/dialog already fired its arrival nudge (14).
  bool _promptNudged = false;

  // Desktop attention badge: edge detection for "turn finished" / "prompt arrived".
  late final SessionAttentionNotifier _attention; // read in initState: ref is unsafe in dispose
  bool _wasBusy = false;
  bool _hadPrompt = false;

  /// Flagged and now actually in front of the user → they've seen it. Deferred:
  /// this runs from build/lifecycle callbacks, where provider writes are illegal.
  void _clearAttentionIfSeen() {
    if (!ref.read(sessionAttentionProvider).containsKey(widget.session.id)) return;
    if (!PushService.isVisible(widget.session.id)) return;
    Future.microtask(() {
      if (mounted) _attention.clear(widget.session.id);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _clearAttentionIfSeen(); // window focused again
  }

  // Mounted isn't enough: a chat under another route is alive but hidden.
  // A hidden desktop workspace tab sits under TickerMode(enabled: false) —
  // mounted on the current route but not visible, so its prompts must notify.
  bool _tickersOn = true;
  bool _isOnScreen() => mounted && _tickersOn && (ModalRoute.of(context)?.isCurrent ?? false);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickersOn = TickerMode.valuesOf(context).enabled;
    _clearAttentionIfSeen(); // tab/page just became visible
  }

  @override
  void initState() {
    super.initState();
    if (widget.initialDraft != null) _input.text = widget.initialDraft!;
    WidgetsBinding.instance.addObserver(this);
    _attention = ref.read(sessionAttentionProvider.notifier);
    _attachments = AttachmentApi(dioFor(widget.creds));
    PushService.registerVisible(widget.session.id, _isOnScreen); // its prompts show as cards, not notifications
    _pool = ref.read(chatControllerPoolProvider);
    _controller = widget.controller ??
        _pool.acquire(
          widget.session.id,
          () => ChatSessionController(
            url: claudeUrl(widget.creds.baseUrl, widget.session.id),
            token: widget.creds.token,
            initialMessage: widget.initialMessage,
            cache: const TranscriptCache(),
            sessionId: widget.session.id,
          ),
          onAuthFailed: _onAuthFailed,
        );
    // Already pooled (open elsewhere): it was built without our first turn.
    final first = widget.initialMessage;
    if (widget.controller == null && first != null && !identical(_controller.initialMessage, first)) {
      _controller.sendWhenLive(first);
    }
    _controller.addListener(_onChange);
    // A pooled controller may already hold the title; report it once built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reportTitle();
    });
    _scroll.addListener(_onScroll);
    _input.addListener(_onInput);
    for (final bytes in widget.initialImageBytes) {
      _uploadBytes(bytes);
    }
  }

  String? _reportedTitle;
  void _reportTitle() {
    final t = _controller.title;
    if (t == null || t == _reportedTitle) return;
    _reportedTitle = t;
    widget.onTitle?.call(t);
  }

  /// React to controller updates: keep the view pinned to the bottom only when
  /// the user is already there (13); count fresh messages otherwise; nudge on a
  /// newly-arrived permission/dialog (14).
  void _onChange() {
    _reportTitle();
    final hasPrompt = _controller.pendingPermission != null || _controller.pendingDialog != null;
    // Desktop: flag an unseen session that finished a turn or is blocked on us.
    if (!isMobile && !PushService.isVisible(widget.session.id)) {
      if (hasPrompt && !_hadPrompt) {
        _attention.raise(widget.session.id, Attention.needsInput);
      } else if (_wasBusy && !_controller.busy) {
        _attention.raise(widget.session.id, Attention.done);
      }
    }
    _hadPrompt = hasPrompt;
    // "Write handoff & start fresh": the handoff turn just finished → open the resuming chat.
    if (_rollover && _wasBusy && !_controller.busy) {
      _rollover = false;
      unawaited(_openFresh());
    }
    _wasBusy = _controller.busy;
    if (hasPrompt && !_promptNudged) {
      _promptNudged = true;
      if (!_atBottom) HapticFeedback.mediumImpact();
    } else if (!hasPrompt) {
      _promptNudged = false;
    }

    final len = _controller.messages.length;
    final added = len - _lastLen;
    _lastLen = len;

    if (_atBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    } else if (mounted) {
      // Scrolled up: refresh the FAB (unread count + approval styling).
      setState(() {
        if (added > 0) _unread += added;
      });
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final atBottom = _scroll.offset >= _scroll.position.maxScrollExtent - 80;
    if (atBottom != _atBottom) {
      setState(() {
        _atBottom = atBottom;
        if (atBottom) _unread = 0;
      });
    }
  }

  void _jumpToBottom() {
    if (_scroll.hasClients) {
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
    setState(() {
      _atBottom = true;
      _unread = 0;
    });
  }

  /// Track the `/command` or `@file` mention under the caret (proposal 22).
  /// Fetches the prompt library once, and the file tree per mention query.
  void _onInput() {
    final caret = _input.selection.baseOffset;
    final slash = detectSlash(_input.text, caret);
    final mention = slash == null ? detectMention(_input.text, caret) : null;
    final changed = slash?.query != _trigger?.query || mention?.query != _mention?.query;
    // Offsets always current; only a query change needs a repaint.
    _trigger = slash;
    _mention = mention;
    if (changed) setState(() {});

    if (slash != null && slash.command == 'prompt' && _prompts == null) _loadPrompts();
    if (mention != null && mention.query != _treeQuery) _loadTree(mention.query);
  }

  Future<void> _loadPrompts() async {
    _prompts = const []; // marks "loading started" so we fetch only once
    try {
      final prompts = await PromptApi(dioFor(widget.creds)).list(projectId: widget.session.projectId);
      if (mounted) setState(() => _prompts = prompts);
    } catch (_) {
      // Offline / server down: the command list just stays empty.
    }
  }

  /// Fetch file names for the current `@` query. Late answers to a stale query
  /// are dropped — the user has typed on since.
  Future<void> _loadTree(String query) async {
    _treeQuery = query;
    try {
      final res = await ProjectTreeApi(dioFor(widget.creds)).tree(widget.session.id, query: query);
      if (!mounted || _treeQuery != query) return;
      setState(() {
        _treeFiles = res.files;
        _treeTruncated = res.truncated;
      });
    } catch (_) {
      if (mounted && _treeQuery == query) setState(() => _treeFiles = const []);
    }
  }

  /// Replace the trigger text (`/files`, `/prompt foo`) with [replacement].
  void _replaceTrigger(String replacement) {
    final t = _trigger;
    if (t == null) return;
    _replaceRange(t.start, t.end, replacement);
  }

  void _replaceRange(int start, int end, String replacement) {
    final text = _input.text.replaceRange(start, end, replacement);
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: start + replacement.length),
    );
    setState(() {
      _trigger = null;
      _mention = null;
    });
  }

  /// Suggestions for the current trigger: matching commands, prompts from the
  /// library (after `/prompt`), or project files (after `@`).
  List<ComposerAction> _suggestions() {
    final m = _mention;
    if (m != null) {
      return [
        for (final rel in _treeFiles.take(8))
          ComposerAction(
            icon: Icons.insert_drive_file_outlined,
            label: rel,
            // The path is sent as plain text; Claude reads it with its own
            // (gated) Read tool — the daemon never resolves a mention.
            onSelect: () => _replaceRange(m.start, m.end, '@$rel '),
          ),
        if (_treeTruncated)
          ComposerAction(
            icon: Icons.more_horiz,
            label: 'More matches — keep typing',
            onSelect: () {},
          ),
      ];
    }

    final t = _trigger;
    if (t == null) return const [];

    if (t.command == 'prompt') {
      final q = t.argument.toLowerCase();
      final matches = (_prompts ?? const <Prompt>[])
          .where((p) => q.isEmpty || p.title.toLowerCase().contains(q))
          .take(6);
      return [
        for (final p in matches)
          ComposerAction(
            icon: p.isGlobal ? Icons.public : Icons.folder_outlined,
            label: p.title,
            hint: p.body.replaceAll('\n', ' '),
            onSelect: () => _insertPrompt(p),
          ),
      ];
    }

    final commands = <ComposerAction>[
      ComposerAction(
        icon: Icons.bookmarks_outlined,
        label: '/prompt',
        hint: 'Insert a prompt from the library',
        onSelect: () => _replaceTrigger('/prompt '),
      ),
      ComposerAction(
        icon: Icons.difference_outlined,
        label: '/files',
        hint: 'Changed files in this session',
        onSelect: () {
          _replaceTrigger('');
          showChangedFilesSheet(context, widget.creds, widget.session);
        },
      ),
      if (_controller.mode != null && _controller.external == null)
        ComposerAction(
          icon: Icons.tune,
          label: '/mode',
          hint: 'Switch Ask / Auto-allow / Plan',
          onSelect: () {
            _replaceTrigger('');
            _pickMode();
          },
        ),
      ComposerAction(
        icon: Icons.copy_outlined,
        label: '/copy',
        hint: 'Copy the transcript',
        onSelect: () {
          _replaceTrigger('');
          _copyTranscript();
        },
      ),
      if (_controller.busy)
        ComposerAction(
          icon: Icons.stop,
          label: '/stop',
          hint: 'Interrupt the running turn',
          onSelect: () {
            _replaceTrigger('');
            _controller.interrupt();
          },
        ),
    ];
    final typed = t.command.toLowerCase();
    final local = commands.where((c) => c.label.substring(1).startsWith(typed)).toList();
    // The session's skills and project commands (proposal 41) — only while still typing the
    // command name, and not for a mirrored CLI. Selecting inserts "/name " for the arguments.
    final skills = t.query.contains(' ') || _controller.external != null
        ? const <SlashCommandInfo>[]
        : matchCommands(
            _controller.slashCommands,
            typed,
            exclude: {for (final c in commands) c.label.substring(1)},
            limit: 8,
          );
    return [
      ...local,
      for (final c in skills)
        ComposerAction(
          icon: Icons.auto_awesome_outlined,
          label: '/${c.name}',
          hint: c.subtitle.isEmpty ? null : c.subtitle,
          onSelect: () => _replaceTrigger('/${c.name} '),
        ),
    ];
  }

  /// Open the mode picker (composer chip or `/mode`, proposal 25). The chip
  /// updates when the daemon echoes the new mode.
  Future<void> _pickMode() async {
    final current = _controller.mode;
    if (current == null) return;
    final picked = await showModePicker(context, current: current, available: _controller.availableModes);
    if (picked != null) _controller.setMode(picked);
  }

  /// Insert a prompt body at the trigger. `{{vars}}` are filled first — the
  /// same template helpers the prompt-use screen uses.
  Future<void> _insertPrompt(Prompt p) async {
    unawaited(PromptApi(dioFor(widget.creds)).markUsed(p.id).catchError((_) {}));
    final vars = extractVars(p.body);
    if (vars.isEmpty) {
      _replaceTrigger(p.body);
      _inputFocus.requestFocus();
      return;
    }
    final values = await _askVars(p, vars);
    if (values == null || !mounted) return;
    _replaceTrigger(fillTemplate(p.body, values));
    _inputFocus.requestFocus();
  }

  /// Sheet with one field per `{{var}}`; null when dismissed.
  Future<Map<String, String>?> _askVars(Prompt p, List<String> vars) {
    final fields = {
      for (final v in vars) v: TextEditingController(text: p.varDefaults[v] ?? ''),
    };
    return showModalBottomSheet<Map<String, String>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: Spacing.lg,
          right: Spacing.lg,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + Spacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(p.title, style: Theme.of(ctx).textTheme.titleMedium),
            for (final v in vars)
              Padding(
                padding: const EdgeInsets.only(top: Spacing.md),
                child: TextField(
                  controller: fields[v],
                  decoration: InputDecoration(labelText: v, border: const OutlineInputBorder()),
                ),
              ),
            const SizedBox(height: Spacing.lg),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, {for (final e in fields.entries) e.key: e.value.text}),
              child: const Text('Insert'),
            ),
          ],
        ),
      ),
    ).whenComplete(() {
      for (final c in fields.values) {
        c.dispose();
      }
    });
  }

  /// Retry (resend verbatim) a prior user turn (proposal 11).
  void _retry(ChatMessage m) => _controller.resendUser(m);

  /// Edit (proposal 11): prefill the composer with the turn's text and focus it.
  /// Sends as a new turn — no history rewrite.
  void _edit(ChatMessage m) {
    _input.text = m.text;
    _input.selection = TextSelection.collapsed(offset: m.text.length);
    _inputFocus.requestFocus();
  }

  /// Rewrite the composer draft against the prompting checklist (ADR 0018);
  /// the user reviews before it replaces the draft. Nothing is sent.
  Future<void> _improveDraft() async {
    if (_input.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Type a draft first')));
      return;
    }
    final better = await improvePromptFlow(context, PromptApi(dioFor(widget.creds)), _pastes.expand(_input.text));
    if (better == null || !mounted) return;
    _input.text = better;
    _input.selection = TextSelection.collapsed(offset: better.length);
    _inputFocus.requestFocus();
  }

  /// Continue this conversation on another model (ADR 0016): a new session
  /// whose first turn carries the recent transcript. This one keeps running.
  Future<void> _pickEffort() async {
    final picked = await showEffortSheet(context, current: _controller.effort, levels: _controller.effortLevels);
    if (picked == null || !mounted) return; // dismissed
    _controller.setEffort(picked.isEmpty ? null : picked);
  }

  /// "Browse files…": a pushed browser; on the desktop workspace a tapped file opens as a tab.
  void _browseFiles() {
    final tab = EditorOpener.maybeOf(context);
    final nav = Navigator.of(context);
    nav.push(sharedAxisRoute(FileBrowserScreen(
      api: ProjectFilesApi.session(dioFor(widget.creds), widget.session.id),
      title: 'Files',
      onOpenFile: tab == null
          ? null
          : (api, path) {
              nav.pop();
              tab(api, path);
            },
    )));
  }

  // Switch model in place — same conversation, new model from the next turn on.
  // Claude models only; moving to another provider is what Hand off is for.

  Future<void> _switchModel() async {
    final choice = await chooseModel(context, SessionApi(dioFor(widget.creds)), title: 'Switch model to');
    final id = choice?.id;
    if (id == null || !mounted) return;
    final msg = ScaffoldMessenger.of(context);
    if (id.contains(':')) {
      msg.showSnackBar(const SnackBar(content: Text('Only Claude models can be switched in place — use “Hand off” for other providers.')));
      return;
    }
    _controller.switchModel(id);
    msg.showSnackBar(SnackBar(content: Text('Switching to ${choice?.label ?? id}…')));
  }

  // Branch the conversation at [m] into a NEW chat (proposal 42); this one is left alone.
  Future<void> _branch(ChatMessage m) async {
    final at = await showBranchSheet(context);
    if (at == null || !mounted) return;
    final msg = ScaffoldMessenger.of(context);
    final ForkResult r;
    try {
      r = await ForkApi(dioFor(widget.creds)).fork(widget.session.id, m.serverId!, at: at);
    } catch (_) {
      msg.showSnackBar(const SnackBar(content: Text('Could not reach the server.')));
      return;
    }
    if (!mounted) return;
    if (!r.ok) {
      msg.showSnackBar(SnackBar(content: Text(r.error ?? 'Could not branch.')));
      return;
    }
    final draft = at == 'before' ? m.text : null;
    final open = widget.onOpenSession;
    if (open != null) {
      // A workspace tab can't be pre-filled; hand the text over on the clipboard instead.
      if (draft != null) await Clipboard.setData(ClipboardData(text: draft));
      open(r.session!);
      if (draft != null) msg.showSnackBar(const SnackBar(content: Text('Branched — your message is on the clipboard, paste it to rewrite.')));
    } else {
      await Navigator.of(context).push(sharedAxisRoute(ChatScreen(creds: widget.creds, session: r.session!, initialDraft: draft)));
    }
  }

  bool _rollover = false;

  /// ADR 0028: have this session write a Handoff, then (when that turn ends) open a fresh
  /// chat that resumes from it — a deliberate, lossless alternative to auto-compaction.
  void _startFresh() {
    if (_controller.busy || _rollover) return;
    _rollover = true;
    _controller.sendUser(handoffInstruction);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Writing the handoff — a fresh chat opens when it is done.')));
  }

  Future<void> _openFresh() async {
    try {
      final s = await SessionApi(dioFor(widget.creds)).create(
        widget.session.projectId,
        kind: 'claude',
        model: widget.session.model,
        title: '⟳ ${_controller.title ?? widget.session.label}',
        initialPrompt: resumeInstruction,
      );
      if (!mounted) return;
      final open = widget.onOpenSession;
      if (open != null) {
        open(s);
      } else {
        await Navigator.of(context).push(sharedAxisRoute(ChatScreen(creds: widget.creds, session: s)));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open a fresh chat: $e')));
    }
  }

  Future<void> _handoff() async {
    final api = SessionApi(dioFor(widget.creds));
    final choice = await chooseModel(context, api, title: 'Hand off to');
    if (choice == null || !mounted) return;
    try {
      final s = await api.create(
        widget.session.projectId,
        kind: 'claude',
        model: choice.id,
        title: '↪ ${_controller.title ?? widget.session.label}',
        initialPrompt: buildHandoffPrompt(_controller.messages),
      );
      if (!mounted) return;
      final open = widget.onOpenSession;
      if (open != null) {
        open(s);
      } else {
        Navigator.of(context).pushReplacement(sharedAxisRoute(ChatScreen(creds: widget.creds, session: s)));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// Copy the whole transcript as plain `role: text` lines (proposal 06).
  /// Includes tool calls, skips result/empty rows.
  void _copyTranscript() {
    Clipboard.setData(ClipboardData(text: _transcriptText()));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Transcript copied')));
  }

  /// OS share sheet (proposal 06): the same plain transcript as Copy.
  void _shareTranscript() {
    SharePlus.instance.share(ShareParams(text: _transcriptText(), subject: _controller.title ?? widget.session.label));
  }

  String _transcriptText() {
    final lines = <String>[];
    for (final m in _controller.messages) {
      switch (m.role) {
        case ChatRole.user:
          if (m.text.isNotEmpty) lines.add('You: ${m.text}');
        case ChatRole.assistant:
          if (m.text.isNotEmpty) lines.add('Claude: ${m.text}');
        case ChatRole.tool:
          lines.add('Tool: ${m.toolName ?? 'tool'}');
        case ChatRole.error:
          if (m.text.isNotEmpty) lines.add('Error: ${m.text}');
        case ChatRole.result:
        case ChatRole.thinking: // reasoning is not part of the conversation transcript
        case ChatRole.notice: // nor are system notes
          break;
      }
    }
    return lines.join('\n');
  }

  // Search jump-to (proposal 10): the target row gets [_hitKey] and a brief tint.
  final _hitKey = GlobalKey();
  ChatMessage? _hit;

  Future<void> _search() async {
    final hit = await showSearch<MessageHit?>(
      context: context,
      delegate: _MessageSearchDelegate(SessionApi(dioFor(widget.creds)), widget.session.id),
    );
    if (hit == null || !mounted) return;
    final messages = _controller.messages;
    final i = findHitIndex(messages, role: hit.role, content: hit.content, ts: hit.ts);
    if (i < 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('That message is not in the loaded transcript')));
      return;
    }
    final target = messages[i];
    final rows = groupToolRuns(messages);
    final row = rows.indexWhere((r) => identical(r, target));
    if (row < 0) return;
    setState(() => _hit = target);
    // The list is lazy with variable row heights: jump to a proportional guess
    // until the row is built, then let ensureVisible place it exactly.
    for (var attempt = 0; attempt < 8 && mounted; attempt++) {
      final ctx = _hitKey.currentContext;
      if (ctx != null && ctx.mounted) {
        await Scrollable.ensureVisible(ctx, alignment: 0.2, duration: Motion.slow, curve: Motion.enter);
        break;
      }
      if (!_scroll.hasClients) break;
      final max = _scroll.position.maxScrollExtent;
      _scroll.jumpTo(rows.length < 2 ? 0 : max * row / (rows.length - 1));
      await WidgetsBinding.instance.endOfFrame;
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted && identical(_hit, target)) setState(() => _hit = null);
  }

  /// Voice input (proposal 01): on-device speech → composer text. Edit-first —
  /// dictation only fills the field; the user reviews and taps send.
  Future<void> _toggleMic() async {
    if (_listening) {
      await _speech.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    final ok = await _speech.initialize(
      onError: (_) {},
      onStatus: (s) {
        if ((s == 'done' || s == 'notListening') && mounted) setState(() => _listening = false);
      },
    );
    if (!ok) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Speech recognition unavailable')));
      }
      return;
    }
    _textBeforeDictation = _input.text;
    setState(() => _listening = true);
    await _speech.listen(onResult: (r) {
      final base = _textBeforeDictation;
      final sep = base.isEmpty || base.endsWith(' ') ? '' : ' ';
      _input.text = '$base$sep${r.recognizedWords}';
      _input.selection = TextSelection.collapsed(offset: _input.text.length);
    });
  }

  Future<void> _onAuthFailed() async {
    await ref.read(tokenStoreProvider).clear();
    ref.invalidate(credsProvider);
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  void _send() {
    final text = _pastes.expand(_input.text).trim();
    if (text.isEmpty && _pending.isEmpty) return;
    HapticFeedback.selectionClick();
    _controller.sendUser(text, images: _pending.map((p) => p.id).toList());
    _input.clear();
    _pastes.clear();
    setState(_pending.clear);
  }

  /// Pick images (several from the gallery, one from the camera), downscale
  /// on-device (≤1568px long edge — Claude's cap), and upload them. The returned
  /// ids are parked in [_pending] until the next send.
  Future<void> _attach(ImageSource source) async {
    final List<XFile> files;
    try {
      if (source == ImageSource.gallery) {
        files = await _picker.pickMultiImage(maxWidth: 1568, maxHeight: 1568, imageQuality: 85);
      } else {
        final file = await _picker.pickImage(source: source, maxWidth: 1568, maxHeight: 1568, imageQuality: 85);
        files = [?file];
      }
    } catch (_) {
      return; // permission denied / no camera — nothing to surface
    }
    for (final f in files) {
      await _uploadBytes(await f.readAsBytes());
    }
  }

  /// Desktop Ctrl/Cmd+V. The clipboard read is async, so the key is always
  /// consumed here: an image on the clipboard is attached, otherwise the text is
  /// inserted at the caret like a normal paste.
  Future<void> _paste() async {
    try {
      final img = await Pasteboard.image;
      if (img != null && img.isNotEmpty) {
        await _uploadBytes(img);
        return;
      }
    } catch (_) {/* no image support on this platform → fall through to text */}
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || text.isEmpty || !mounted) return;
    _input.value = _pastes.insert(_input.value, text); // formatters don't see programmatic edits
  }

  /// Tap on a paste chip (proposal 47): view the full text, expand it inline or drop it.
  Future<void> _openPasteAtCaret() async {
    final range = _input.tokenAt(_input.selection.baseOffset);
    if (range == null) return;
    final token = _input.text.substring(range.start, range.end);
    final text = _pastes.textOf(token);
    if (text == null) return;
    final action = await showPasteSheet(context, text);
    if (action == null || !mounted || range.end > _input.text.length || _input.text.substring(range.start, range.end) != token) return;
    final replacement = action == PasteAction.expand ? text : '';
    _input.value = TextEditingValue(
      text: _input.text.replaceRange(range.start, range.end, replacement),
      selection: TextSelection.collapsed(offset: range.start + replacement.length),
    );
    if (!_input.text.contains(token)) _pastes.forget(token); // last copy gone → drop the map entry
  }

  /// Normalize (BMP → PNG, ≤1568px), upload, and park the minted id in
  /// [_pending] for the next send. Shared by the picker ([_attach]), paste,
  /// drag-drop and pre-attached images ([initState]).
  Future<void> _uploadBytes(Uint8List raw) async {
    setState(() => _uploading = true);
    try {
      final bytes = await normalizeImage(raw);
      final id = await _attachments.upload(widget.session.id, bytes);
      if (mounted) setState(() => _pending.add(_PendingImage(id, bytes)));
    } catch (e) {
      AppLog.error('image upload (${raw.length} B, session ${widget.session.id}): $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Image upload failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _pickSource() {
    if (!isMobile) {
      _attach(ImageSource.gallery); // desktop: file dialog, no camera
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(children: [
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Photo library'),
            onTap: () {
              Navigator.pop(ctx);
              _attach(ImageSource.gallery);
            },
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Camera'),
            onTap: () {
              Navigator.pop(ctx);
              _attach(ImageSource.camera);
            },
          ),
        ]),
      ),
    );
  }

  Future<void> _close() async {
    WorktreeKept? kept;
    try {
      kept = await SessionApi(dioFor(widget.creds)).delete(widget.session.id);
    } catch (_) {/* idempotent server-side */}
    if (!mounted) return;
    if (kept != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(kept.message), duration: const Duration(seconds: 8)));
    }
    final onClose = widget.onClose;
    onClose != null ? onClose() : Navigator.of(context).pop();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final id = widget.session.id;
    Future.microtask(() => _attention.clear(id)); // closed tab: nothing left to look at
    PushService.unregisterVisible(widget.session.id, _isOnScreen);
    _controller.removeListener(_onChange);
    if (widget.controller == null) _pool.release(widget.session.id, _onAuthFailed);
    _input.removeListener(_onInput);
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    _speech.cancel();
    super.dispose();
  }

  // Compact reset countdown, e.g. "2h 54m", "3d 4h", or "" when unknown/past.
  String _fmtReset(DateTime? at) {
    if (at == null) return '';
    final d = at.difference(DateTime.now());
    if (d.isNegative) return '';
    if (d.inDays >= 1) return '${d.inDays}d ${d.inHours % 24}h';
    if (d.inHours >= 1) return '${d.inHours}h ${d.inMinutes % 60}m';
    return '${d.inMinutes}m';
  }

  // Meter tint by API severity; null/"normal" inherits the default text colour.
  Color? _meterColor(BuildContext context, String? severity) {
    switch (severity) {
      case 'warning':
        return Colors.orange;
      case 'critical':
      case 'exceeded':
        return Theme.of(context).colorScheme.error;
      default:
        return null;
    }
  }

  /// Permission/question gates: slide + fade in above the composer instead of
  /// appearing instantly (DESIGN.md §9).
  Widget _gateSwitcher(Widget? card) => AnimatedSwitcher(
        duration: Motion.slow,
        switchInCurve: Motion.enter,
        switchOutCurve: Motion.exit,
        transitionBuilder: (child, anim) => SizeTransition(
          sizeFactor: anim,
          alignment: Alignment.topCenter,
          child: FadeTransition(opacity: anim, child: child),
        ),
        child: card ?? const SizedBox(width: double.infinity),
      );

  /// Desktop drag-drop attach: image files only (the daemon sniffs and
  /// enforces type + size; this just skips obvious non-images).
  Future<void> _onDrop(DropDoneDetails d) async {
    const exts = ['.png', '.jpg', '.jpeg', '.webp', '.gif'];
    for (final f in d.files.where((f) => exts.any(f.name.toLowerCase().endsWith))) {
      await _uploadBytes(await f.readAsBytes());
    }
  }

  void _showUsageSheet(BuildContext context, SessionUsage usage) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => _UsageMeters(usage: usage, fmtReset: _fmtReset, meterColor: _meterColor),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      enable: !isMobile,
      onDragDone: _onDrop,
      child: Scaffold(
      appBar: AppBar(
        leading: widget.onMenu == null
            ? null
            : IconButton(tooltip: 'Menu', icon: const Icon(Icons.menu), onPressed: widget.onMenu),
        title: ListenableBuilder(
          listenable: _controller,
          builder: (context, _) {
            final usage = _controller.usage;
            final session = usage?.session;
            final cost = _controller.sessionCost;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_controller.title ?? widget.session.label, overflow: TextOverflow.ellipsis),
                // Max subscription: real usage meter (tap for the full breakdown).
                if (session != null)
                  GestureDetector(
                    onTap: () => _showUsageSheet(context, usage!),
                    child: Text(
                      'Session ${session.pct.round()}%'
                      '${_fmtReset(session.resetsAt) == '' ? '' : ' · ${_fmtReset(session.resetsAt)}'}',
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: _meterColor(context, session.severity)),
                    ),
                  )
                // Native (pay-per-token) session: real dollar spend.
                else if (cost > 0)
                  Text(
                    '\$${cost < 1 ? cost.toStringAsFixed(3) : cost.toStringAsFixed(2)}',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
              ],
            );
          },
        ),
        actions: [
          // A `vc` CLI session running on the server: open its own TUI (ADR 0012)
          // for what the transcript can't show — permission prompts, menus.
          ListenableBuilder(
            listenable: _controller,
            builder: (context, _) => _controller.external?.canReply == true
                ? IconButton(
                    tooltip: 'Terminal on PC',
                    icon: const Icon(Icons.terminal),
                    onPressed: () => Navigator.of(context).push(sharedAxisRoute(TerminalScreen(
                      creds: widget.creds,
                      session: widget.session,
                      url: ttyUrl(widget.creds.baseUrl, widget.session.id),
                    ))),
                  )
                : const SizedBox.shrink(),
          ),
          IconButton(
            tooltip: 'Changed files',
            icon: const Icon(Icons.difference_outlined),
            onPressed: () => showChangedFilesSheet(context, widget.creds, widget.session),
          ),
          IconButton(
            tooltip: 'Search messages',
            icon: const Icon(Icons.search),
            onPressed: _search,
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'copy') _copyTranscript();
              if (v == 'share') _shareTranscript();
              if (v == 'handoff') _handoff();
              if (v == 'switch') _switchModel();
              if (v == 'effort') _pickEffort();
              if (v == 'mcp') showMcpSheet(context, _controller);
              if (v == 'ci') showCiSheet(context, creds: widget.creds, sessionId: widget.session.id);
              if (v == 'files') _browseFiles();
              if (v == 'improve') _improveDraft();
              if (v == 'tokens') showSessionSpendSheet(context, widget.creds, widget.session.id);
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'improve', child: Text('Improve draft prompt')),
              const PopupMenuItem(value: 'copy', child: Text('Copy transcript')),
              const PopupMenuItem(value: 'share', child: Text('Share transcript…')),
              if (_controller.canSwitchModel)
                PopupMenuItem(
                  value: 'switch',
                  child: Text(_controller.model == null ? 'Switch model…' : 'Switch model… (${_controller.model})'),
                ),
              if (_controller.isClaudeEngine) const PopupMenuItem(value: 'mcp', child: Text('Tools & integrations…')),
              if (_controller.isClaudeEngine) const PopupMenuItem(value: 'ci', child: Text('Pull request & CI…')),
              if (_controller.isClaudeEngine) const PopupMenuItem(value: 'files', child: Text('Browse files…')),
              if (_controller.effortLevels.isNotEmpty)
                PopupMenuItem(value: 'effort', child: Text('Effort… (${_controller.effort ?? 'default'})')),
              const PopupMenuItem(value: 'handoff', child: Text('Hand off to another model…')),
              const PopupMenuItem(value: 'tokens', child: Text('Token usage')),
            ],
          ),
          IconButton(tooltip: 'Close session', icon: const Icon(Icons.close), onPressed: _close),
        ],
      ),
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          return Column(
            children: [
              AnimatedSwitcher(
                duration: Motion.fast,
                switchInCurve: Motion.enter,
                switchOutCurve: Motion.exit,
                transitionBuilder: (child, anim) => SizeTransition(
                  sizeFactor: anim,
                  alignment: Alignment.topCenter,
                  child: FadeTransition(opacity: anim, child: child),
                ),
                child: _controller.state == ConnState.live
                    ? const SizedBox(width: double.infinity)
                    : _Banner(key: ValueKey(_controller.state), state: _controller.state),
              ),
              if (_controller.external != null) _ExternalBanner(run: _controller.external!),
              if (_controller.offline && _controller.messages.isNotEmpty)
                Container(
                  width: double.infinity,
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  padding: const EdgeInsets.symmetric(vertical: Spacing.xs, horizontal: Spacing.md),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: const [
                      Icon(Icons.cloud_off, size: 14),
                      SizedBox(width: 6),
                      Text('Offline — showing cached transcript'),
                    ],
                  ),
                ),
              Expanded(
                child: Stack(children: [
                  Builder(builder: (context) {
                  // Consecutive tool calls fold into one collapsed row.
                  final rows = groupToolRuns(_controller.messages);
                  final gallery = galleryFromMessages(_controller.messages, widget.session.id);
                  final list = ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(Spacing.md),
                    itemCount: rows.length,
                    itemBuilder: (context, i) {
                      final row = rows[i];
                      final Widget item;
                      if (row is ToolRun) {
                        item = _ToolRunTile(
                          run: row,
                          creds: widget.creds,
                          sessionId: widget.session.id,
                          open: _openRuns.contains(row.first),
                          // Only the live tail can still be running.
                          running: _controller.busy && i == rows.length - 1 && row.calls.last.toolResult == null,
                          onToggle: () => setState(() {
                            if (!_openRuns.remove(row.first)) _openRuns.add(row.first);
                          }),
                        );
                      } else {
                        final m = row as ChatMessage;
                        final isUser = m.role == ChatRole.user;
                        final bubble = _Bubble(
                          message: m,
                          creds: widget.creds,
                          sessionId: widget.session.id,
                          onRetry: isUser ? () => _retry(m) : null,
                          onEdit: isUser ? () => _edit(m) : null,
                          // Needs the daemon row id (history / user_ack); Claude engine only.
                          onRewind: isUser && m.serverId != null
                              ? () => showRewindSheet(
                                    context,
                                    creds: widget.creds,
                                    sessionId: widget.session.id,
                                    messageId: m.serverId!,
                                  )
                              : null,
                          // Same condition: the daemon needs the row's checkpoint uuid.
                          onBranch: isUser && m.serverId != null && _controller.external == null ? () => _branch(m) : null,
                        );
                        item = identical(m, _hit)
                            ? AnimatedContainer(
                                key: _hitKey,
                                duration: Motion.base,
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(Radii.sm),
                                ),
                                child: bubble,
                              )
                            : bubble;
                      }
                      // Only the newest row animates in — older rows would replay
                      // the entrance every time they scroll back into view.
                      return i == rows.length - 1 ? FadeSlideIn(child: item) : item;
                    },
                  );
                  // Desktop: mouse-drag selects text across messages (Ctrl+C copies).
                  // Phones keep long-press for the bubble's action sheet.
                  return ChatGallery(sources: gallery, child: isMobile ? list : SelectionArea(child: list));
                  }),
                  // Jump to the newest message: bottom centre of the chat area, above the composer.
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: Spacing.md,
                    child: Center(
                      child: AnimatedSwitcher(
                        duration: Motion.fast,
                        switchInCurve: Motion.enter,
                        switchOutCurve: Motion.exit,
                        transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
                        child: _atBottom
                            ? const SizedBox.shrink()
                            : _ScrollDownButton(
                                key: ValueKey(_controller.pendingPermission != null || _controller.pendingDialog != null),
                                unread: _unread,
                                approval: _controller.pendingPermission != null || _controller.pendingDialog != null,
                                onPressed: _jumpToBottom,
                              ),
                      ),
                    ),
                  ),
                ]),
              ),
              // Gates slide in rather than snapping the composer down.
              _gateSwitcher(
                _controller.pendingPermission == null
                    ? null
                    : _PermissionCard(
                        key: ValueKey(_controller.pendingPermission!.toolUseID),
                        request: _controller.pendingPermission!,
                        onAllow: () => _controller.respondPermission(true),
                        onDeny: () {
                          HapticFeedback.heavyImpact();
                          _controller.respondPermission(false);
                        },
                      ),
              ),
              _gateSwitcher(
                _controller.pendingDialog == null
                    ? null
                    : _controller.pendingDialog!.isExitPlan
                        ? ExitPlanCard(
                            key: ValueKey(_controller.pendingDialog!.dialogId),
                            dialog: _controller.pendingDialog!,
                            onApprove: (m) => _controller.respondExitPlan(approve: true, approveMode: m),
                            onKeepPlanning: (fb) => _controller.respondExitPlan(approve: false, feedback: fb),
                          )
                        : _QuestionCard(
                            // key by dialogId so a new dialog resets the picker's selection state
                            key: ValueKey(_controller.pendingDialog!.dialogId),
                            dialog: _controller.pendingDialog!,
                            onSubmit: _controller.respondDialog,
                            onCancel: _controller.cancelDialog,
                          ),
              ),
              // A mirrored CLI has its own banner (_ExternalBanner).
              if (_controller.busy && _controller.external == null && _controller.turn != null)
                _TurnStatusLine(turn: _controller.turn!),
              if (_controller.context != null && _controller.external == null)
                ContextStrip(
                  usage: _controller.context!,
                  onFresh: _controller.busy ? null : _startFresh,
                  onTap: () => showContextSheet(
                    context,
                    usage: _controller.context!,
                    onCompact: _controller.busy ? null : _controller.compact,
                    onFresh: _startFresh,
                  ),
                ),
              ComposerSuggestions(actions: _suggestions()),
              _Composer(
                mode: _controller.external == null ? _controller.mode : null, // a mirrored CLI owns its own mode
                onModeTap: _pickMode,
                onImprove: _improveDraft,
                onResumeHandoff: _openFresh,
                controller: _input,
                inputFormatters: [PasteCollapseFormatter(_pastes)],
                onTapField: _openPasteAtCaret,
                focusNode: _inputFocus,
                onSend: _send,
                onAttach: _pickSource,
                onMic: _toggleMic,
                listening: _listening,
                busy: _controller.busy,
                onStop: _controller.interrupt,
                uploading: _uploading,
                pending: _pending,
                onRemove: (p) => setState(() => _pending.remove(p)),
              ),
            ],
          );
        },
      ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.creds, required this.sessionId, this.onRetry, this.onEdit, this.onRewind, this.onBranch});
  final ChatMessage message;
  final Creds creds;
  final String sessionId;

  /// Set for user turns (proposal 11). Null for other roles → the actions menu
  /// only offers Copy.
  final VoidCallback? onRetry;
  final VoidCallback? onEdit;

  /// Set for user turns with a checkpoint (ADR 0023): opens the rewind sheet.
  final VoidCallback? onRewind;

  /// Set for user turns that can be branched (proposal 42).
  final VoidCallback? onBranch;

  @override
  Widget build(BuildContext context) {
    if (message.role == ChatRole.result) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    Widget content = _content(context, scheme);
    if (message.role == ChatRole.user || message.role == ChatRole.assistant) {
      final user = message.role == ChatRole.user;
      content = Column(
        crossAxisAlignment: user ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          content,
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
            child: Text(
              fmtMessageTime(message.at, DateTime.now()),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.outline),
            ),
          ),
        ],
      );
    }
    if (message.superseded) content = Opacity(opacity: 0.5, child: content);
    if (!isMobile) {
      // Desktop: right-click for the actions; left-drag belongs to SelectionArea.
      return GestureDetector(
        onSecondaryTapUp: (d) => _showActionsMenu(context, d.globalPosition),
        child: content,
      );
    }
    return GestureDetector(onLongPress: () => _showActions(context), child: content);
  }

  /// Desktop right-click menu at the cursor: same actions as [_showActions].
  Future<void> _showActionsMenu(BuildContext context, Offset at) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        const PopupMenuItem(value: 'copy', child: Text('Copy message')),
        if (onRetry != null) const PopupMenuItem(value: 'retry', child: Text('Retry')),
        if (onEdit != null) const PopupMenuItem(value: 'edit', child: Text('Edit')),
        if (onRewind != null) const PopupMenuItem(value: 'rewind', child: Text('Rewind files to here')),
        if (onBranch != null) const PopupMenuItem(value: 'branch', child: Text('Branch from here…')),
      ],
    );
    if (!context.mounted) return;
    switch (choice) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: _copyPayload()));
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
      case 'retry':
        onRetry!();
      case 'edit':
        onEdit!();
      case 'rewind':
        onRewind!();
      case 'branch':
        onBranch!();
    }
  }

  Widget _content(BuildContext context, ColorScheme scheme) {
    switch (message.role) {
      case ChatRole.user:
        if (message.images.isNotEmpty) {
          return Align(
            alignment: Alignment.centerRight,
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: Spacing.xs),
              padding: const EdgeInsets.all(Spacing.md),
              decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(Radii.sm)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  ChatImageStrip(
                    creds: creds,
                    sources: [for (final id in message.images) AttachmentImage(id)],
                    alignment: WrapAlignment.end,
                  ),
                  if (message.text.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    CollapsibleText(message.text, builder: (t) => LinkifiedText(t)),
                  ],
                ],
              ),
            ),
          );
        }
        return _align(Alignment.centerRight, scheme.primaryContainer, message.text, collapse: true);
      case ChatRole.assistant:
        final bubble = _align(Alignment.centerLeft, scheme.surfaceContainerHighest, message.text,
            streaming: message.streaming, markdown: true);
        // Image files the reply mentions (proposal 33) — previewed once complete;
        // a path that isn't a real image in the project silently doesn't render.
        final paths = message.streaming ? const <String>[] : extractImagePaths(message.text);
        if (paths.isEmpty) return bubble;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          bubble,
          ChatImageStrip(
            creds: creds,
            sources: [for (final p in paths) SessionFileImage(sessionId, p)],
            hideOnError: true,
          ),
        ]);
      case ChatRole.tool:
        final result = message.toolResult;
        final chip = Chip(
          avatar: Icon(message.toolResultIsError ? Icons.error_outline : Icons.build, size: 16),
          label: Text(message.toolName ?? 'tool'),
        );
        // No result yet → just the call chip (proposal 07).
        if (result == null) {
          return Align(
            alignment: Alignment.centerLeft,
            child: Padding(padding: const EdgeInsets.symmetric(vertical: Spacing.xs), child: chip),
          );
        }
        // Result arrived → collapse it under the chip; tap to expand. Truncated
        // so a huge dump can't blow out the list. Result images (proposal 33)
        // stay visible below it.
        final shown = result.length > 2000 ? '${result.substring(0, 2000)}\n… (truncated)' : result;
        final tile = Align(
          alignment: Alignment.centerLeft,
          child: Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(left: Spacing.sm, bottom: Spacing.sm),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              title: Align(alignment: Alignment.centerLeft, child: chip),
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(Spacing.sm),
                  decoration: BoxDecoration(
                    color: message.toolResultIsError ? scheme.errorContainer : scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(Radii.sm),
                  ),
                  child: Text(shown, style: const TextStyle(fontFamily: AppTheme.monoFontFamily, fontSize: 12)),
                ),
              ],
            ),
          ),
        );
        if (message.images.isEmpty) return tile;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          tile,
          ChatImageStrip(creds: creds, sources: [for (final id in message.images) AttachmentImage(id)]),
        ]);
      case ChatRole.error:
        return _align(Alignment.center, scheme.errorContainer, message.text);
      case ChatRole.notice:
        return Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
            child: Text(
              message.text,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant, fontStyle: FontStyle.italic),
            ),
          ),
        );
      case ChatRole.thinking:
        return ThinkingTile(text: message.text, streaming: message.streaming);
      case ChatRole.result:
        return const SizedBox.shrink();
    }
  }

  Widget _align(Alignment a, Color bg, String text, {bool streaming = false, bool markdown = false, bool collapse = false}) => Align(
        alignment: a,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: Spacing.xs),
          padding: const EdgeInsets.all(Spacing.md),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Radii.sm)),
          child: Builder(
            builder: (context) => streaming
                ? _text(
                    context,
                    markdown,
                    '$text ',
                    trailing: const WidgetSpan(
                      alignment: PlaceholderAlignment.baseline,
                      baseline: TextBaseline.alphabetic,
                      child: StreamingCursor(),
                    ),
                  )
                : collapse
                    ? CollapsibleText(text, builder: (t) => _text(context, markdown, t))
                    : _text(context, markdown, text),
          ),
        ),
      );

  // Assistant text is markdown (domain/markdown.dart); the user's own text and
  // errors stay plain, so what you typed is shown exactly as you typed it.
  // File references open in the in-app viewer for this session (proposal 48).
  Widget _text(BuildContext context, bool markdown, String text, {InlineSpan? trailing}) {
    void open(String path, int? line) => openChatFile(context, sessionId: sessionId, creds: creds, path: path, line: line);
    return markdown
        ? MarkdownText(text, trailing: trailing, onOpenFile: open)
        : LinkifiedText(text, trailing: trailing, onOpenFile: open);
  }

  /// Long-press menu (proposals 06 + 11): Copy the message; Retry/Edit a user turn.
  void _showActions(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(children: [
          ListTile(
            leading: const Icon(Icons.copy_outlined),
            title: const Text('Copy'),
            onTap: () {
              Navigator.pop(ctx);
              Clipboard.setData(ClipboardData(text: _copyPayload()));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
            },
          ),
          if (onRetry != null)
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('Retry'),
              onTap: () {
                Navigator.pop(ctx);
                onRetry!();
              },
            ),
          if (onEdit != null)
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit'),
              onTap: () {
                Navigator.pop(ctx);
                onEdit!();
              },
            ),
          if (onRewind != null)
            ListTile(
              leading: const Icon(Icons.history),
              title: const Text('Rewind files to here'),
              onTap: () {
                Navigator.pop(ctx);
                onRewind!();
              },
            ),
          if (onBranch != null)
            ListTile(
              leading: const Icon(Icons.call_split),
              title: const Text('Branch from here…'),
              onTap: () {
                Navigator.pop(ctx);
                onBranch!();
              },
            ),
        ]),
      ),
    );
  }

  /// Clipboard text for this message: the body, or tool name + input JSON.
  String _copyPayload() {
    if (message.role == ChatRole.tool) {
      final input = message.toolInput;
      return input != null
          ? '${message.toolName ?? 'tool'}\n${jsonEncode(input)}'
          : (message.toolName ?? 'tool');
    }
    return message.text;
  }
}

/// The model's summarized reasoning (proposal 36, M9 spike): one muted row,
/// collapsed by default so it never crowds the answer; tap to read it.
class ThinkingTile extends StatelessWidget {
  const ThinkingTile({super.key, required this.text, required this.streaming});
  final String text;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Align(
      alignment: Alignment.centerLeft,
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          dense: true,
          childrenPadding: const EdgeInsets.only(left: Spacing.sm, bottom: Spacing.sm),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          leading: Icon(Icons.psychology_outlined, size: 18, color: muted),
          title: Text(streaming ? 'Thinking…' : 'Thought', style: theme.textTheme.labelMedium?.copyWith(color: muted)),
          children: [
            Text(text, style: theme.textTheme.bodySmall?.copyWith(color: muted, fontStyle: FontStyle.italic)),
          ],
        ),
      ),
    );
  }
}

/// One collapsed row standing in for a run of consecutive tool calls. Tap to
/// reveal each call (chip + expandable result) inline; closed by default so the
/// conversation stays readable.
class _ToolRunTile extends StatelessWidget {
  const _ToolRunTile({
    required this.run,
    required this.creds,
    required this.sessionId,
    required this.open,
    required this.running,
    required this.onToggle,
  });
  final ToolRun run;
  final Creds creds;
  final String sessionId;
  final bool open;
  final bool running;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final n = run.calls.length;
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return Align(
      alignment: Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(Radii.sm),
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Spacing.xs, horizontal: Spacing.sm),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    run.hasError ? Icons.error_outline : Icons.build_outlined,
                    size: 16,
                    color: run.hasError ? scheme.error : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: Spacing.sm),
                  Flexible(
                    child: Text(
                      '$n tool call${n == 1 ? '' : 's'} · ${run.summary}',
                      style: muted,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (running) ...[
                    const SizedBox(width: Spacing.sm),
                    const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                  ],
                  Icon(open ? Icons.expand_less : Icons.expand_more, size: 18, color: scheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
          // Closed run: still show its result images (proposal 33) so a Read on a
          // PNG isn't buried. Open: each call's bubble shows its own.
          if (!open && run.calls.any((c) => c.images.isNotEmpty))
            ChatImageStrip(
              creds: creds,
              sources: [
                for (final c in run.calls)
                  for (final id in c.images) AttachmentImage(id),
              ],
            ),
          if (open)
            Padding(
              padding: const EdgeInsets.only(left: Spacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [for (final c in run.calls) _Bubble(message: c, creds: creds, sessionId: sessionId)],
              ),
            ),
        ],
      ),
    );
  }
}

/// The approval gate (security.md #5). Shows what the tool will do — for
/// file-writing tools the daemon's `diffPreview`, which is built from the exact
/// input it will execute (proposal 02: render == execution).
///
/// Swipe right = allow, left = deny. Swipe is *additive*: the buttons stay, the
/// dismiss threshold is deliberately high, and high-risk tools still confirm.
/// Either path calls the same `respondPermission`, so the audit trail is
/// identical.
class _PermissionCard extends StatefulWidget {
  const _PermissionCard({super.key, required this.request, required this.onAllow, required this.onDeny});
  final PermissionRequest request;
  final VoidCallback onAllow;
  final VoidCallback onDeny;

  @override
  State<_PermissionCard> createState() => _PermissionCardState();
}

class _PermissionCardState extends State<_PermissionCard> {
  static const _collapsedLines = 12;
  bool _expanded = false;

  /// Tools that get a confirm dialog before a swipe takes effect. Client-side
  /// friction only — the real containment is the server's gate.
  bool get _highRisk {
    final t = widget.request.toolName;
    if (t == 'Bash' || t == 'Write') return true;
    return widget.request.diffPreview == null && widget.request.input?['file_path'] != null;
  }

  Future<bool> _confirm(BuildContext context, bool allow) async {
    if (!allow || !_highRisk) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.warning_amber_outlined),
        title: Text('Allow ${widget.request.toolName}?'),
        content: Text(widget.request.description ?? 'This runs on the server.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Allow')),
        ],
      ),
    );
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final request = widget.request;
    final preview = request.diffPreview;

    return Dismissible(
      key: ValueKey('perm-${request.toolUseID}'),
      // High thresholds: a pocket flick must not approve a tool call.
      dismissThresholds: const {DismissDirection.startToEnd: 0.55, DismissDirection.endToStart: 0.55},
      background: _swipeHint(context, allow: true),
      secondaryBackground: _swipeHint(context, allow: false),
      confirmDismiss: (dir) async {
        final allow = dir == DismissDirection.startToEnd;
        if (!await _confirm(context, allow)) return false;
        HapticFeedback.mediumImpact();
        allow ? widget.onAllow() : widget.onDeny();
        // The controller clears the pending request; don't also dismiss the
        // widget or the list would animate a row that no longer exists.
        return false;
      },
      child: Material(
        color: scheme.tertiaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(Spacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.lock_outline, size: 18),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Text(request.displayName ?? request.title ?? 'Allow ${request.toolName}?',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              ]),
              if (request.description != null) ...[
                const SizedBox(height: Spacing.xs),
                Text(request.description!),
              ],
              if (preview != null) ...[
                const SizedBox(height: Spacing.sm),
                _DiffPreviewBody(
                  preview: preview,
                  expanded: _expanded,
                  collapsedLines: _collapsedLines,
                  onToggle: () => setState(() => _expanded = !_expanded),
                ),
              ],
              const SizedBox(height: Spacing.sm),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(onPressed: widget.onDeny, child: const Text('Deny')),
                const SizedBox(width: Spacing.sm),
                FilledButton(onPressed: widget.onAllow, child: const Text('Allow')),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _swipeHint(BuildContext context, {required bool allow}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: allow ? scheme.primaryContainer : scheme.errorContainer,
      alignment: allow ? Alignment.centerLeft : Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(allow ? Icons.check : Icons.block, size: 18),
          const SizedBox(width: Spacing.sm),
          Text(allow ? 'Allow' : 'Deny'),
        ],
      ),
    );
  }
}

/// The diff inside a permission card: collapsed to the first N lines with a
/// show-all toggle. A server-side cut is stated, never hidden.
class _DiffPreviewBody extends StatelessWidget {
  const _DiffPreviewBody({
    required this.preview,
    required this.expanded,
    required this.collapsedLines,
    required this.onToggle,
  });

  final DiffPreview preview;
  final bool expanded;
  final int collapsedLines;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = preview.diff.split('\n');
    final shown = expanded ? lines : lines.take(collapsedLines).toList();
    final hidden = lines.length - shown.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(
            child: Text(preview.relPath,
                style: monoStyle(context), maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          Text('+${preview.adds} −${preview.dels}', style: theme.textTheme.labelSmall),
        ]),
        const SizedBox(height: Spacing.xs),
        Material(
          color: theme.colorScheme.surface,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.sm)),
          child: Column(children: [for (final l in shown) DiffLine(line: l)]),
        ),
        if (preview.truncated)
          Padding(
            padding: const EdgeInsets.only(top: Spacing.xs),
            child: Text('Diff truncated by the server', style: theme.textTheme.labelSmall),
          ),
        if (hidden > 0 || expanded)
          TextButton(
            onPressed: onToggle,
            child: Text(expanded ? 'Show less' : 'Show all ($hidden more)'),
          ),
      ],
    );
  }
}

/// Renders an AskUserQuestion dialog: each question with its tappable options.
/// Submit is enabled once every question has a selection; the result maps each
/// question's text to the chosen label(s) (claude-ws.md).
class _QuestionCard extends StatefulWidget {
  const _QuestionCard({super.key, required this.dialog, required this.onSubmit, required this.onCancel});
  final UserDialog dialog;
  final void Function(Map<String, String> answers) onSubmit;
  final VoidCallback onCancel;

  @override
  State<_QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends State<_QuestionCard> {
  // question index -> chosen option labels (one for single-select, many for multi)
  final Map<int, Set<String>> _picked = {};

  List<Map<String, dynamic>> get _questions => widget.dialog.questions;

  bool get _complete => _questions
      .asMap()
      .keys
      .every((i) => (_picked[i] ?? const {}).isNotEmpty);

  void _toggle(int qi, String label, bool multi) {
    setState(() {
      final sel = _picked.putIfAbsent(qi, () => {});
      if (multi) {
        sel.contains(label) ? sel.remove(label) : sel.add(label);
      } else {
        _picked[qi] = {label};
      }
    });
  }

  void _submit() {
    final answers = <String, String>{};
    for (var i = 0; i < _questions.length; i++) {
      final q = _questions[i]['question'] as String? ?? '';
      answers[q] = (_picked[i] ?? const {}).join(', ');
    }
    widget.onSubmit(answers);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(Spacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < _questions.length; i++) ..._question(context, i, _questions[i]),
            const SizedBox(height: 4),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: widget.onCancel, child: const Text('Skip')),
              const SizedBox(width: 8),
              FilledButton(onPressed: _complete ? _submit : null, child: const Text('Send')),
            ]),
          ],
        ),
      ),
    );
  }

  List<Widget> _question(BuildContext context, int qi, Map<String, dynamic> q) {
    final multi = q['multiSelect'] == true;
    final options = ((q['options'] as List?) ?? const []).map((o) => (o as Map).cast<String, dynamic>());
    final sel = _picked[qi] ?? const {};
    return [
      if (qi > 0) const Divider(height: 20),
      Text(q['question'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 6),
      Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (final o in options)
            FilterChip(
              label: Text(o['label'] as String? ?? ''),
              tooltip: o['description'] as String?,
              selected: sel.contains(o['label']),
              onSelected: (_) => _toggle(qi, o['label'] as String? ?? '', multi),
            ),
        ],
      ),
    ];
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.mode,
    required this.onModeTap,
    required this.onImprove,
    required this.onResumeHandoff,
    required this.controller,
    required this.inputFormatters,
    required this.onTapField,
    required this.focusNode,
    required this.onSend,
    required this.onAttach,
    required this.onMic,
    required this.listening,
    required this.busy,
    required this.onStop,
    required this.uploading,
    required this.pending,
    required this.onRemove,
  });
  final SessionMode? mode; // null → no chip (old daemon, or a mirrored CLI session)
  final VoidCallback onModeTap;
  final VoidCallback onImprove; // Improve / Go deeper on the draft (ADR 0018, proposal 61)
  final VoidCallback onResumeHandoff; // new chat resuming from the newest Handoff (ADR 0028)
  final TextEditingController controller;
  final List<TextInputFormatter> inputFormatters;
  final VoidCallback onTapField; // taps on a paste chip open it (proposal 47)
  final FocusNode focusNode;
  final VoidCallback onSend;
  final VoidCallback? onMic; // null → hide the on-device speech button
  final bool listening;
  final bool busy;
  final VoidCallback onStop;
  final VoidCallback onAttach;
  final bool uploading;
  final List<_PendingImage> pending;
  final void Function(_PendingImage) onRemove;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(Spacing.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
                if (mode != null) ModeChip(mode: mode!, onTap: onModeTap),
                TextButton.icon(
                  onPressed: onImprove,
                  icon: const Icon(Icons.auto_fix_high_outlined, size: 18),
                  label: const Text('Improve'),
                ),
                TextButton.icon(
                  onPressed: onResumeHandoff,
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: const Text('Resume handoff'),
                ),
              ]),
            ),
            if (pending.isNotEmpty)
              SizedBox(
                height: 72,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final p in pending)
                      Padding(
                        padding: const EdgeInsets.only(right: 6, bottom: 6),
                        child: _PendingThumb(image: p, onRemove: () => onRemove(p)),
                      ),
                  ],
                ),
              ),
            Row(children: [
              IconButton(
                tooltip: 'Attach image',
                icon: uploading
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.add_photo_alternate_outlined),
                onPressed: uploading ? null : onAttach,
              ),
              if (onMic != null)
                IconButton(
                  tooltip: listening ? 'Stop dictation' : 'Voice input',
                  color: listening ? Theme.of(context).colorScheme.error : null,
                  icon: Icon(listening ? Icons.mic : Icons.mic_none_outlined),
                  onPressed: onMic,
                ),
              Expanded(
                child: TextField(
                  controller: controller,
                  inputFormatters: inputFormatters,
                  onTap: onTapField,
                  focusNode: focusNode,
                  minLines: 1,
                  maxLines: 5,
                  // Desktop: Enter is caught by the composer's FocusNode (send);
                  // newline here lets Shift+Enter insert a line break.
                  textInputAction: isMobile ? TextInputAction.send : TextInputAction.newline,
                  onSubmitted: (_) => onSend(),
                  decoration: const InputDecoration(
                    hintText: 'Message Claude…',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // While a turn streams, Stop (proposal 09) sits beside Send: a
              // message sent mid-turn is picked up at Claude's next step
              // (proposal 26).
              if (busy)
                IconButton.filled(
                  tooltip: 'Stop',
                  icon: const Icon(Icons.stop),
                  style: IconButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
                  onPressed: onStop,
                ),
              IconButton.filled(
                tooltip: busy ? 'Send now (Claude sees it at its next step)' : 'Send',
                icon: const Icon(Icons.send),
                onPressed: onSend,
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

/// A picked-but-unsent image in the composer tray, with a remove affordance.
class _PendingThumb extends StatelessWidget {
  const _PendingThumb({required this.image, required this.onRemove});
  final _PendingImage image;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(Radii.sm),
        child: Image.memory(image.bytes, width: 66, height: 66, fit: BoxFit.cover),
      ),
      Positioned(
        top: -6,
        right: -6,
        child: IconButton(
          icon: const Icon(Icons.cancel, size: 18),
          color: Colors.white70,
          style: IconButton.styleFrom(backgroundColor: Colors.black54, padding: EdgeInsets.zero),
          constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          onPressed: onRemove,
        ),
      ),
    ]);
  }
}

class _Banner extends StatelessWidget {
  const _Banner({super.key, required this.state});
  final ConnState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = Theme.of(context).extension<AppColors>()!;
    final (String text, Color bg, bool spin) = switch (state) {
      ConnState.connecting => ('Connecting…', colors.connConnecting, true),
      ConnState.reconnecting => ('Reconnecting…', colors.connReconnecting, true),
      ConnState.ended => ('Session ended', colors.connEnded, false),
      ConnState.authFailed => ('Auth expired — re-pairing', colors.connAuthFailed, false),
      ConnState.live => ('', scheme.surface, false),
    };
    return Container(
      width: double.infinity,
      color: bg,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: Spacing.md),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        if (spin) const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
        if (spin) const SizedBox(width: 8),
        Text(text),
      ]),
    );
  }
}

/// Strip shown while mirroring a CLI session that runs on the server (ADR 0012).
class _ExternalBanner extends StatelessWidget {
  const _ExternalBanner({required this.run});
  final ExternalRun run;

  @override
  Widget build(BuildContext context) {
    final state = run.busy ? 'working…' : 'idle';
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(vertical: Spacing.xs, horizontal: Spacing.md),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.computer, size: 14),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              run.canReply
                  ? 'Running on PC · $state'
                  : 'Running on PC · $state · read-only (start with vc to reply)',
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

/// "Running Bash… 47s" above the composer while a turn runs (proposal 32), so a
/// working turn is told apart from a stalled one. Ticks locally once a second;
/// turns amber with "no activity Ns" when [TurnStatus.stalledFor] says so.
class _TurnStatusLine extends StatefulWidget {
  const _TurnStatusLine({required this.turn});
  final TurnStatus turn;

  @override
  State<_TurnStatusLine> createState() => _TurnStatusLineState();
}

class _TurnStatusLineState extends State<_TurnStatusLine> {
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final stalled = widget.turn.stalledFor(now) != null;
    final fg = stalled ? scheme.onTertiaryContainer : scheme.onSurfaceVariant;
    return Container(
      width: double.infinity,
      color: stalled ? scheme.tertiaryContainer : null,
      padding: const EdgeInsets.symmetric(vertical: Spacing.xs, horizontal: Spacing.md),
      child: Row(children: [
        if (stalled)
          Icon(Icons.hourglass_empty, size: 14, color: fg)
        else
          SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: fg)),
        const SizedBox(width: Spacing.sm),
        Flexible(
          child: Text(
            widget.turn.label(now),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: fg),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ]),
    );
  }
}

/// Per-session transcript search (proposal 10). Queries the daemon's
/// `GET /sessions/:id/messages?q=` and lists matches. Jump-to-message is
/// deferred — the chat list can't scroll to an arbitrary index without
/// churning the proposal-13 scroll logic — so results are read-only for now.
/// Returns the tapped hit (or null) so the chat can jump to it (proposal 10).
class _MessageSearchDelegate extends SearchDelegate<MessageHit?> {
  _MessageSearchDelegate(this.api, this.sessionId);
  final SessionApi api;
  final String sessionId;

  @override
  List<Widget>? buildActions(BuildContext context) => [
        if (query.isNotEmpty) IconButton(icon: const Icon(Icons.clear), onPressed: () => query = ''),
      ];

  @override
  Widget? buildLeading(BuildContext context) =>
      IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => close(context, null));

  @override
  Widget buildSuggestions(BuildContext context) =>
      const Center(child: Text('Type, then search the transcript'));

  @override
  Widget buildResults(BuildContext context) {
    if (query.trim().isEmpty) return const SizedBox.shrink();
    return FutureBuilder<List<MessageHit>>(
      future: api.searchMessages(sessionId, query.trim()),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) return Center(child: Text('${snap.error}'));
        final hits = snap.data ?? [];
        if (hits.isEmpty) return const Center(child: Text('No matches'));
        return ListView.builder(
          itemCount: hits.length,
          itemBuilder: (context, i) {
            final h = hits[i];
            return ListTile(
              leading: Icon(switch (h.role) {
                'user' => Icons.person_outline,
                'assistant' => Icons.smart_toy_outlined,
                'tool' => Icons.build_outlined,
                _ => Icons.notes_outlined,
              }),
              title: Text(h.content, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(h.role),
              onTap: () => close(context, h),
            );
          },
        );
      },
    );
  }
}

/// FAB shown when scrolled up (proposal 13): jumps to the latest message and
/// badges the unread count. When a permission/dialog is waiting (proposal 14)
/// it switches to an "Approval needed" pill so a pending gate can't be missed.
class _ScrollDownButton extends StatelessWidget {
  const _ScrollDownButton({super.key, required this.unread, required this.approval, required this.onPressed});
  final int unread;
  final bool approval;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    if (approval) {
      return FloatingActionButton.extended(
        onPressed: onPressed,
        backgroundColor: Theme.of(context).colorScheme.tertiaryContainer,
        icon: const Icon(Icons.lock_outline),
        label: const Text('Approval needed'),
      );
    }
    return FloatingActionButton.small(
      onPressed: onPressed,
      child: Badge(
        isLabelVisible: unread > 0,
        label: Text('$unread'),
        child: const Icon(Icons.arrow_downward),
      ),
    );
  }
}

/// Bottom sheet mirroring claude.ai's usage panel: the rolling session window on
/// top, then the weekly limits (all-models + per-model), each as a labelled bar
/// with its reset countdown.
class _UsageMeters extends StatelessWidget {
  const _UsageMeters({required this.usage, required this.fmtReset, required this.meterColor});

  final SessionUsage usage;
  final String Function(DateTime?) fmtReset;
  final Color? Function(BuildContext, String?) meterColor;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    if (usage.session != null) {
      rows.add(_meter(context, usage.session!, 'Current session'));
    }
    if (usage.weekly.isNotEmpty) {
      rows.add(Padding(
        padding: const EdgeInsets.only(top: Spacing.md, bottom: Spacing.xs),
        child: Text('Weekly limits', style: Theme.of(context).textTheme.titleSmall),
      ));
      for (final w in usage.weekly) {
        rows.add(_meter(context, w, w.label));
      }
    }
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Spacing.lg, 0, Spacing.lg, Spacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        ),
      ),
    );
  }

  Widget _meter(BuildContext context, UsageLimit l, String title) {
    final reset = fmtReset(l.resetsAt);
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title, style: t.textTheme.bodyMedium),
              Text('${l.pct.round()}%', style: t.textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: (l.pct / 100).clamp(0, 1).toDouble(),
              minHeight: 8,
              color: meterColor(context, l.severity),
            ),
          ),
          if (reset != '')
            Padding(
              padding: const EdgeInsets.only(top: Spacing.xs),
              child: Text(
                'Resets in $reset',
                style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.outline),
              ),
            ),
        ],
      ),
    );
  }
}
