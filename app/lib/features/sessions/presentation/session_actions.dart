import 'dart:async';

import 'package:flutter/material.dart';

import '../data/session_api.dart';
import '../domain/session.dart';
import '../../../core/errors.dart';
import '../../chat/data/transcript_cache.dart';

// Per-session actions shared by the phone's project screen (long-press sheet)
// and the desktop workspace sidebar (right-click menu). Each returns true when
// the server state changed, so the caller refetches; errors surface as a snack.

void _error(BuildContext context, Object e) {
  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
}

Future<String?> _textDialog(BuildContext context, {required String title, required String initial, required String hint}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Save')),
      ],
    ),
  );
}

Future<bool> renameSession(BuildContext context, SessionApi api, Session s) async {
  final title = (await _textDialog(context, title: 'Rename session', initial: s.title ?? '', hint: 'Title'))?.trim();
  if (title == null || title.isEmpty) return false;
  try {
    await api.rename(s.id, title);
    return true;
  } catch (e) {
    if (context.mounted) _error(context, e);
    return false;
  }
}

Future<bool> editSessionTags(BuildContext context, SessionApi api, Session s) async {
  final tags = await _textDialog(
    context,
    title: 'Edit tags',
    initial: s.tags.join(', '),
    hint: 'Comma-separated, e.g. review, bug',
  );
  if (tags == null) return false;
  try {
    await api.setTags(s.id, tags.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList());
    return true;
  } catch (e) {
    if (context.mounted) _error(context, e);
    return false;
  }
}

/// The close X in chat and terminal ends the session on the server (proposal 70 C4):
/// ask first. True = end it.
Future<bool> confirmEndSession(BuildContext context, String label) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('End session?'),
        content: Text('“$label” will be ended on the server. To keep it running, go back instead.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('End')),
        ],
      ),
    ) ==
    true;

/// Confirm, then end + remove the session on the daemon.
Future<bool> killSession(BuildContext context, SessionApi api, Session s) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Kill session?'),
      content: Text('“${s.label}” will be ended and removed.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Kill')),
      ],
    ),
  );
  if (confirmed != true) return false;
  try {
    final kept = await api.delete(s.id);
    unawaited(const TranscriptCache().delete(s.id)); // its cached transcript goes too (71 S2)
    if (kept != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(kept.message), duration: const Duration(seconds: 8)));
    }
    return true;
  } catch (e) {
    if (context.mounted) _error(context, e);
    return false;
  }
}
