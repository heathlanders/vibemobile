/// One row in the Claude conversation. [ChatRole.notice] is a system note shown in the flow
/// (e.g. "Context compacted …"), never part of the model's transcript. [ChatRole.thinking] is the model's summarized
/// reasoning (daemon `thinking` frames) — shown collapsed, never copied as an answer. `text` is mutable so streamed `delta`
/// frames can grow an assistant bubble in place.
enum ChatRole { user, assistant, tool, result, error, thinking, notice }

class ChatMessage {
  ChatMessage({
    required this.role,
    this.text = '',
    this.toolName,
    this.toolInput,
    this.toolUseId,
    this.toolResult,
    this.toolResultIsError = false,
    this.images = const [],
    this.streaming = false,
    this.superseded = false,
    this.ts,
    this.serverId,
  });

  /// The daemon's `messages.id` for a user turn — what "rewind files to here"
  /// sends (ADR 0023). From `history` rows, or a `user_ack` frame for a turn
  /// sent live. Null for other roles and for turns not yet acknowledged.
  String? serverId;

  /// Server timestamp, set on rows replayed from `history` (null on live
  /// frames). Lets a search hit (proposal 10) find its exact bubble.
  final String? ts;

  final ChatRole role;
  String text;
  final String? toolName;
  final Map<String, dynamic>? toolInput;

  /// Tool-call identity + result (proposal 07). [toolUseId] keys a `tool_result`
  /// frame back to its tool chip; [toolResult] is the (possibly truncated) output,
  /// rendered expandable under the chip. Mutable so a live result can fill in.
  final String? toolUseId;
  String? toolResult;
  bool toolResultIsError;

  /// Attachment ids on a user turn (proposal 16) or a tool result's images
  /// (proposal 33). The bubble lazy-fetches each via `GET /attachments/:id`.
  /// Mutable so a live `tool_result` can fill a tool row in.
  List<String> images;
  bool streaming;

  /// A user turn that's been retried/edited (proposal 11) — rendered dimmed.
  /// Client-only marking; not persisted (the SDK transcript is append-only).
  bool superseded;

  // Persistence for the offline transcript cache (transcript_cache.dart).
  // `streaming` is transient and intentionally omitted.
  Map<String, dynamic> toJson() => {
        'role': role.name,
        'text': text,
        if (toolName != null) 'toolName': toolName,
        if (toolInput != null) 'toolInput': toolInput,
        if (toolUseId != null) 'toolUseId': toolUseId,
        if (toolResult != null) 'toolResult': toolResult,
        if (toolResultIsError) 'toolResultIsError': true,
        if (images.isNotEmpty) 'images': images,
        if (serverId != null) 'serverId': serverId,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        role: ChatRole.values.firstWhere((e) => e.name == j['role'], orElse: () => ChatRole.assistant),
        text: j['text'] as String? ?? '',
        toolName: j['toolName'] as String?,
        toolInput: (j['toolInput'] as Map?)?.cast<String, dynamic>(),
        toolUseId: j['toolUseId'] as String?,
        toolResult: j['toolResult'] as String?,
        toolResultIsError: j['toolResultIsError'] as bool? ?? false,
        images: (j['images'] as List?)?.cast<String>() ?? const [],
        serverId: j['serverId'] as String?,
      );
}

/// Index in [messages] of a search hit (proposal 10): the row with the hit's
/// [ts] if history carried one, else the newest same-role row with identical
/// text (turns that arrived live, before any reattach). -1 when not loaded.
int findHitIndex(List<ChatMessage> messages, {required String role, required String content, required String ts}) {
  final exact = messages.indexWhere((m) => m.ts == ts);
  if (exact >= 0) return exact;
  return messages.lastIndexWhere((m) => m.role.name == role && m.text == content);
}

/// Pre-approval diff of a file-writing tool call (proposal 02). The daemon
/// builds it from the exact input it will execute — render equals execution.
/// [truncated] means [diff] ends with a visible "… +N lines truncated" marker.
class DiffPreview {
  DiffPreview({
    required this.relPath,
    required this.diff,
    required this.adds,
    required this.dels,
    required this.truncated,
  });

  final String relPath;
  final String diff;
  final int adds;
  final int dels;
  final bool truncated;

  factory DiffPreview.fromJson(Map<String, dynamic> j) => DiffPreview(
        relPath: j['relPath'] as String? ?? '',
        diff: j['diff'] as String? ?? '',
        adds: (j['adds'] as num?)?.toInt() ?? 0,
        dels: (j['dels'] as num?)?.toInt() ?? 0,
        truncated: j['truncated'] == true,
      );
}

/// A pending tool-approval the phone must answer before Claude runs the tool
/// (docs/protocols/claude-ws.md — the security gate).
class PermissionRequest {
  PermissionRequest({
    required this.toolUseID,
    required this.toolName,
    this.title,
    this.displayName,
    this.description,
    this.input,
    this.diffPreview,
  });

  final String toolUseID;
  final String toolName;
  final String? title;

  /// Friendly action label from the SDK (proposal 08), e.g. "Run shell command".
  /// Preferred over [title]/[toolName] for the card heading.
  final String? displayName;
  final String? description;
  final Map<String, dynamic>? input;

  /// Present only for Edit/Write/MultiEdit (proposal 02); null otherwise.
  final DiffPreview? diffPreview;
}

/// A blocking dialog the daemon forwarded from the Agent SDK (claude-ws.md).
/// The AskUserQuestion tool routes here: the user picks an option per question
/// and the answer is sent back as the dialog result. Transported opaquely —
/// [payload] shape is defined per [dialogKind]; we only render question dialogs.
class UserDialog {
  UserDialog({required this.dialogId, required this.dialogKind, required this.payload});

  final String dialogId;
  final String dialogKind;
  final Map<String, dynamic> payload;

  /// Plan approval (proposal 25): the model called ExitPlanMode and the daemon
  /// is waiting for approve / keep-planning. Rendered as a plan card.
  bool get isExitPlan => dialogKind == 'exit_plan';

  /// The plan text (markdown) of an [isExitPlan] dialog.
  String get plan => (payload['plan'] as String?) ?? '';

  /// The questions to render (AskUserQuestion: `payload.questions`). Empty for
  /// dialog kinds this client doesn't know how to render — those auto-cancel.
  List<Map<String, dynamic>> get questions => ((payload['questions'] as List?) ?? const [])
      .map((q) => (q as Map).cast<String, dynamic>())
      .toList();
}
