import 'package:flutter/material.dart';

/// How Claude is allowed to act in a session (proposal 25). The wire carries only
/// these three names; the daemon maps them to SDK permission modes and the tool
/// gate — the app never names a raw SDK mode.
enum SessionMode {
  ask(
    label: 'Ask',
    icon: Icons.verified_user_outlined,
    description: 'Approve every tool call on the phone',
  ),
  auto(
    label: 'Auto-allow',
    icon: Icons.bolt_outlined,
    description: 'Claude runs tools (including shell commands) without asking',
  ),
  plan(
    label: 'Plan',
    icon: Icons.map_outlined,
    description: 'Read-only research, then you approve the plan before anything runs',
  );

  const SessionMode({required this.label, required this.icon, required this.description});

  final String label;
  final IconData icon;
  final String description;

  String get wire => name;

  /// Null for names this client doesn't know (a newer daemon).
  static SessionMode? fromWire(Object? v) {
    for (final m in values) {
      if (m.name == v) return m;
    }
    return null;
  }
}

/// Shift+Tab cycle (desktop, like Claude Code's CLI): the next of [available]
/// after [current] in enum order (ask → auto → plan → ask). Null when there is
/// nothing to switch to.
SessionMode? nextMode(SessionMode current, List<SessionMode> available) {
  final order = [for (final m in SessionMode.values) if (available.contains(m)) m];
  if (order.length < 2) return null;
  final i = order.indexOf(current);
  return order[(i + 1) % order.length]; // current missing (i = -1) → first
}
