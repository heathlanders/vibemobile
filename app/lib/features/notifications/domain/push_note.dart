import 'dart:convert';

/// Pure notification logic for push (ADR 0013): turn a daemon
/// `GET /sessions/:id/pending` body into local notifications, and a tapped
/// action back into an answer. No plugin imports, so it's unit-testable.
///
/// The FCM push itself carries only `{type, sessionId}` — the content shown
/// here is fetched from the daemon over the tailnet, never sent through Google.

/// One local notification to show. [payload] round-trips through the
/// notification plugin and comes back on tap (see [NotePayload]).
class PushNote {
  const PushNote({
    required this.id,
    required this.title,
    required this.body,
    required this.actions,
    required this.payload,
    required this.prompt,
  });

  final int id;
  final String title;
  final String body;

  /// (actionId, label) pairs, in display order. Empty = tap-to-open only.
  final List<(String, String)> actions;
  final String payload;

  /// True for approvals/questions (high-importance, hidden on the lock screen);
  /// false for "finished".
  final bool prompt;
}

/// Stable 31-bit notification id (FNV-1a). `String.hashCode` isn't guaranteed
/// stable across isolates, and the background isolate must hit the same id to
/// replace or cancel a notification the main isolate showed.
int stableNoteId(String key) {
  var h = 0x811c9dc5;
  for (final c in utf8.encode(key)) {
    h ^= c;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h & 0x7fffffff;
}

const _maxBody = 160;

String _truncate(String s) {
  final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return one.length <= _maxBody ? one : '${one.substring(0, _maxBody - 1)}…';
}

/// The one-line gist of a tool call: the Bash command, the file path, else the
/// SDK's description / first string field.
String summarizeInput(String toolName, Map<String, dynamic> input) {
  for (final k in const ['command', 'file_path', 'path', 'url', 'pattern']) {
    final v = input[k];
    if (v is String && v.isNotEmpty) return v;
  }
  final first = input.values.whereType<String>().where((v) => v.isNotEmpty);
  return first.isEmpty ? '' : first.first;
}

/// Build notifications for a push of [type] ("permission" | "question" |
/// "done", or "cli_*" for a CLI session outside the daemon, ADR 0014).
/// [pending] is the `/pending` body. Returns nothing for a
/// permission/question push whose request is already gone (answered or timed
/// out between push and fetch).
List<PushNote> buildNotes(String type, String sessionId, Map<String, dynamic> pending) {
  final title = (pending['title'] as String?)?.trim();
  final name = (title == null || title.isEmpty) ? 'Claude' : title;

  if (type == 'done') {
    return [
      PushNote(
        id: stableNoteId('done:$sessionId'),
        title: '$name finished',
        body: 'Tap to open the session.',
        actions: const [],
        payload: NotePayload(sessionId: sessionId, kind: 'done').encode(),
        prompt: false,
      ),
    ];
  }

  // A swarm task reached review (proposal 65): content-free, tap opens its session.
  if (type == 'task_review') {
    return [
      PushNote(
        id: stableNoteId('task_review:$sessionId'),
        title: '$name finished a task',
        body: 'Ready for review. Tap to open the session.',
        actions: const [],
        payload: NotePayload(sessionId: sessionId, kind: 'done').encode(),
        prompt: false,
      ),
    ];
  }

  // Swarm merge queue (ADR 0032): content-free; the details are on the approval screen.
  if (type == 'merge_ready' || type == 'merge_bounced') {
    final ready = type == 'merge_ready';
    return [
      PushNote(
        id: stableNoteId('$type:$sessionId'),
        title: ready ? 'Merge ready for approval' : 'Merge bounced',
        body: ready ? 'Review and approve it in the tasks panel.' : 'Open the tasks panel to see why.',
        actions: const [],
        payload: NotePayload(sessionId: sessionId, kind: 'done').encode(),
        prompt: ready,
      ),
    ];
  }

  // A CLI session's prompt lives in its terminal (ADR 0014): no details to
  // fetch, no buttons — tap opens the session. One id per session, so a newer
  // state replaces the older one.
  final cli = switch (type) {
    'cli_permission' => ('$name needs approval', 'Waiting for approval in the terminal.', true),
    'cli_question' => ('$name has a question', 'Waiting for your answer in the terminal.', true),
    'cli_waiting' => ('$name is waiting', 'Waiting for your input.', false),
    _ => null,
  };
  if (cli != null) {
    final (title, body, prompt) = cli;
    return [
      PushNote(
        id: stableNoteId('cli:$sessionId'),
        title: title,
        body: body,
        actions: const [],
        payload: NotePayload(sessionId: sessionId, kind: 'done').encode(),
        prompt: prompt,
      ),
    ];
  }

  final notes = <PushNote>[];
  for (final p in (pending['permissions'] as List<dynamic>? ?? const []).whereType<Map<String, dynamic>>()) {
    final toolUseID = p['toolUseID'] as String?;
    if (toolUseID == null) continue;
    final tool = (p['displayName'] as String?) ?? (p['toolName'] as String?) ?? 'Tool';
    final gist = summarizeInput(p['toolName'] as String? ?? '', (p['input'] as Map?)?.cast<String, dynamic>() ?? const {});
    notes.add(PushNote(
      id: stableNoteId(toolUseID),
      title: '$name needs approval',
      body: _truncate(gist.isEmpty ? tool : '$tool: $gist'),
      actions: const [('allow', 'Allow'), ('deny', 'Deny')],
      payload: NotePayload(sessionId: sessionId, kind: 'permission', requestId: toolUseID).encode(),
      prompt: true,
    ));
  }
  for (final d in (pending['dialogs'] as List<dynamic>? ?? const []).whereType<Map<String, dynamic>>()) {
    final dialogId = d['dialogId'] as String?;
    if (dialogId == null) continue;
    // Plan approval (proposal 25): never one-tap — a plan has to be read, so the
    // note has no buttons and a tap opens the session's plan card.
    if (d['dialogKind'] == 'exit_plan') {
      final plan = ((d['payload'] as Map?)?['plan'] as String?) ?? '';
      final firstLine = plan.split('\n').map((l) => l.replaceFirst(RegExp(r'^#+\s*'), '').trim()).firstWhere(
            (l) => l.isNotEmpty,
            orElse: () => 'Tap to review.',
          );
      notes.add(PushNote(
        id: stableNoteId(dialogId),
        title: '$name has a plan ready',
        body: _truncate(firstLine),
        actions: const [],
        payload: NotePayload(sessionId: sessionId, kind: 'question', requestId: dialogId).encode(),
        prompt: true,
      ));
      continue;
    }
    if (d['dialogKind'] != 'ask_user_question') continue;
    final questions = ((d['payload'] as Map?)?['questions'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    if (questions.isEmpty) continue;
    final q = questions.first;
    // Buttons only when one tap fully answers: a single, single-select question.
    // Anything else opens the session's own question UI.
    final options = (q['options'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((o) => o['label'] as String?)
        .whereType<String>()
        .toList();
    final oneTap = questions.length == 1 && q['multiSelect'] != true && options.isNotEmpty;
    notes.add(PushNote(
      id: stableNoteId(dialogId),
      title: '$name has a question',
      body: _truncate((q['question'] as String?) ?? 'Tap to answer.'),
      actions: oneTap ? [for (var i = 0; i < options.length && i < 3; i++) ('opt:$i', options[i])] : const [],
      payload: NotePayload(
        sessionId: sessionId,
        kind: 'question',
        requestId: dialogId,
        questions: oneTap ? questions : null,
      ).encode(),
      prompt: true,
    ));
  }
  // A "question" push can race a permission (and vice versa) — show whatever
  // is pending; ids are stable, so a re-show just replaces in place.
  return notes;
}

/// What a notification carries back to the tap/action handler.
class NotePayload {
  const NotePayload({required this.sessionId, required this.kind, this.requestId, this.questions});

  final String sessionId;
  final String kind; // permission | question | done
  final String? requestId; // toolUseID or dialogId
  final List<Map<String, dynamic>>? questions; // one-tap question only

  String encode() => jsonEncode({
        's': sessionId,
        'k': kind,
        'r': ?requestId,
        'q': ?questions,
      });

  static NotePayload? decode(String? raw) {
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return NotePayload(
        sessionId: j['s'] as String,
        kind: j['k'] as String,
        requestId: j['r'] as String?,
        questions: (j['q'] as List<dynamic>?)?.whereType<Map<String, dynamic>>().toList(),
      );
    } catch (_) {
      return null;
    }
  }
}

/// The daemon call an action tap maps to.
sealed class NoteAnswer {
  const NoteAnswer();
}

class PermissionAnswer extends NoteAnswer {
  const PermissionAnswer(this.toolUseID, this.allow);
  final String toolUseID;
  final bool allow;
}

class DialogAnswer extends NoteAnswer {
  const DialogAnswer(this.dialogId, this.result);
  final String dialogId;

  /// `{questions, answers: {questionText: optionLabel}}` — the same result the
  /// in-chat question UI sends (claude-ws.md).
  final Map<String, dynamic> result;
}

/// Map a tapped action to its answer; null for a body tap or anything stale.
NoteAnswer? answerFor(NotePayload p, String? actionId) {
  final id = p.requestId;
  if (actionId == null || actionId.isEmpty || id == null) return null;
  if (p.kind == 'permission' && (actionId == 'allow' || actionId == 'deny')) {
    return PermissionAnswer(id, actionId == 'allow');
  }
  if (p.kind == 'question' && actionId.startsWith('opt:')) {
    final qs = p.questions;
    final i = int.tryParse(actionId.substring(4));
    if (qs == null || qs.isEmpty || i == null) return null;
    final opts = (qs.first['options'] as List<dynamic>? ?? const []).whereType<Map<String, dynamic>>().toList();
    if (i < 0 || i >= opts.length) return null;
    return DialogAnswer(id, {
      'questions': qs,
      'answers': {qs.first['question'] as String? ?? '': opts[i]['label'] as String? ?? ''},
    });
  }
  return null;
}

/// Box health push (ADR 0019): content-free, so the note can't say which
/// resource — opening the app's System page shows it. One id: a newer alert
/// replaces the older one.
PushNote systemAlertNote() => PushNote(
      id: stableNoteId('system_alert'),
      title: 'Server needs attention',
      body: 'Memory, swap, disk or GPU is past its limit. Open System in VibeMobile to check.',
      actions: const [],
      payload: const NotePayload(sessionId: '', kind: 'system').encode(),
      prompt: false,
    );

/// Plan-usage nudge (ADR 0020): a 5-hour or weekly window resets soon with most
/// of it unused. Content-free like the system alert; the app's usage meter
/// shows which window.
PushNote usageResetNote() => PushNote(
      id: stableNoteId('usage_reset'),
      title: 'Plan capacity about to reset',
      body: 'A usage window resets soon and most of it is unused. Open VibeMobile to see which.',
      actions: const [],
      payload: const NotePayload(sessionId: '', kind: 'usage').encode(),
      prompt: false,
    );
