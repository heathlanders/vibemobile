import 'package:flutter/material.dart';

import '../../../core/spacing.dart';

/// One selectable row in the composer suggestion list.
class ComposerAction {
  const ComposerAction({
    required this.icon,
    required this.label,
    required this.onSelect,
    this.hint,
  });

  final IconData icon;
  final String label;
  final String? hint;
  final VoidCallback onSelect;
}

/// Slash-command / prompt suggestions, shown inline above the composer.
///
/// Deliberately not a modal: density is premium (DESIGN.md §1) and the keyboard
/// stays up, so picking a command never costs a round-trip through a sheet.
class ComposerSuggestions extends StatelessWidget {
  const ComposerSuggestions({super.key, required this.actions});

  final List<ComposerAction> actions;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedSwitcher(
      duration: Motion.fast,
      switchInCurve: Motion.enter,
      switchOutCurve: Motion.exit,
      transitionBuilder: (child, anim) => SizeTransition(
        sizeFactor: anim,
        alignment: Alignment.bottomCenter,
        child: FadeTransition(opacity: anim, child: child),
      ),
      child: actions.isEmpty
          ? const SizedBox(width: double.infinity)
          : Padding(
              key: ValueKey(actions.map((a) => a.label).join('|')),
              padding: const EdgeInsets.fromLTRB(Spacing.sm, 0, Spacing.sm, Spacing.xs),
              child: Material(
                // Material (not a decorated Container) so tap ink is visible.
                color: scheme.surfaceContainerHighest,
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(Radii.sm),
                  side: BorderSide(color: scheme.outlineVariant),
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    itemCount: actions.length,
                    itemBuilder: (context, i) {
                      final a = actions[i];
                      return ListTile(
                        dense: true,
                        leading: Icon(a.icon, size: 18),
                        title: Text(a.label),
                        subtitle:
                            a.hint == null ? null : Text(a.hint!, maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: a.onSelect,
                      );
                    },
                  ),
                ),
              ),
            ),
    );
  }
}
