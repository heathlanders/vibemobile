import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Why a session wants the user (desktop workspace, unseen sessions only).
enum Attention {
  /// A turn finished and Claude is waiting for the next instruction.
  done,

  /// Blocked on the user: a tool approval, a question, or a plan to approve.
  needsInput,
}

/// Sessions that need a look and haven't been seen yet, by session id. Raised by
/// a ChatScreen when a turn ends or a prompt arrives while it isn't on screen;
/// cleared when that chat becomes visible with the window focused. Drives the
/// red flashing badge on the rail's Workspace icon and on the session's tab.
class SessionAttentionNotifier extends Notifier<Map<String, Attention>> {
  @override
  Map<String, Attention> build() => const {};

  void raise(String sessionId, Attention a) {
    if (!ref.mounted) return; // a deferred call can outlive the container
    final cur = state[sessionId];
    // A blocking prompt outranks "finished"; never downgrade it.
    if (cur == a || cur == Attention.needsInput) return;
    state = {...state, sessionId: a};
  }

  void clear(String sessionId) {
    if (!ref.mounted) return;
    if (!state.containsKey(sessionId)) return;
    state = {...state}..remove(sessionId);
  }
}

final sessionAttentionProvider =
    NotifierProvider<SessionAttentionNotifier, Map<String, Attention>>(SessionAttentionNotifier.new);

/// A red badge that pulses to catch the eye. With [count] 0 it is just [child].
/// Honors the OS "reduce motion" setting by holding steady instead of pulsing.
class FlashingBadge extends StatefulWidget {
  const FlashingBadge({super.key, required this.count, required this.child, this.showCount = true});
  final int count;
  final Widget child;
  final bool showCount;

  @override
  State<FlashingBadge> createState() => _FlashingBadgeState();
}

class _FlashingBadgeState extends State<FlashingBadge> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.count > 0;
    final still = MediaQuery.disableAnimationsOf(context);
    if (active && !still) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else if (_pulse.isAnimating) {
      _pulse.stop();
    }
    if (!active) return widget.child;

    final scheme = Theme.of(context).colorScheme;
    final dot = widget.showCount && widget.count > 0
        ? Container(
            constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(color: scheme.error, borderRadius: BorderRadius.circular(8)),
            alignment: Alignment.center,
            child: Text(
              '${widget.count}',
              style: TextStyle(color: scheme.onError, fontSize: 10, fontWeight: FontWeight.w700, height: 1.2),
            ),
          )
        : Container(width: 10, height: 10, decoration: BoxDecoration(color: scheme.error, shape: BoxShape.circle));
    return Stack(clipBehavior: Clip.none, children: [
      widget.child,
      Positioned(
        top: -4,
        right: -6,
        child: still ? dot : FadeTransition(opacity: Tween(begin: 1.0, end: 0.25).animate(_pulse), child: dot),
      ),
    ]);
  }
}
