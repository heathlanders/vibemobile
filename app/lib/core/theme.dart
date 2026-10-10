import 'package:flutter/material.dart';

import 'spacing.dart';

/// App theme — a Material 3 scheme tuned for a dev/terminal tool. Dark is the
/// default (see theme_controller.dart); light is the same scheme inverted. The
/// xterm terminal renders its own ANSI colors and is left untouched.
class AppTheme {
  AppTheme._();

  static const _seed = Color(0xFF4F9DDE); // calm blue accent

  /// Bundled monospace family — terminal, tool output, code, session IDs.
  /// See app/DESIGN.md §3. Never use the bare 'monospace' string.
  static const String monoFontFamily = 'JetBrainsMono';

  /// `MaterialApp.builder`: cap toast width on wide screens so it reads as a
  /// toast, not a bar. The theme alone can't, it doesn't know the screen size.
  static Widget capToastWidth(BuildContext context, Widget? child) {
    const max = 440.0;
    if (MediaQuery.sizeOf(context).width < max + 2 * Spacing.lg) return child!;
    final theme = Theme.of(context);
    return Theme(data: theme.copyWith(snackBarTheme: theme.snackBarTheme.copyWith(width: max)), child: child!);
  }

  static ThemeData get dark => _build(Brightness.dark);
  static ThemeData get light => _build(Brightness.light);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 2,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerHighest,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      chipTheme: ChipThemeData(side: BorderSide(color: scheme.outlineVariant)),
      inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder(), isDense: true),
      listTileTheme: const ListTileThemeData(visualDensity: VisualDensity.compact),
      extensions: [AppColors.fromScheme(scheme)],
    );
    // Toasts ("Copied", errors): a floating card on the surface tint, not the
    // default full-width inverse bar. Width is capped per screen by [capToastWidth].
    return base.copyWith(
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.surfaceContainerHigh,
        contentTextStyle: base.textTheme.bodyMedium?.copyWith(color: scheme.onSurface),
        actionTextColor: scheme.primary,
        closeIconColor: scheme.onSurfaceVariant,
        elevation: 1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        insetPadding: const EdgeInsets.fromLTRB(Spacing.lg, 0, Spacing.lg, Spacing.lg),
      ),
    );
  }
}

/// Named connection-state colors — see app/DESIGN.md §2.
/// Read via `Theme.of(context).extension<AppColors>()!`. Live = no banner
/// (render transparent); the tokens below cover the non-live states.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.connConnecting,
    required this.connReconnecting,
    required this.connEnded,
    required this.connAuthFailed,
  });

  final Color connConnecting;
  final Color connReconnecting;
  final Color connEnded;
  final Color connAuthFailed;

  factory AppColors.fromScheme(ColorScheme s) => AppColors(
        connConnecting: s.secondaryContainer,
        connReconnecting: s.tertiaryContainer,
        connEnded: s.surfaceContainerHighest,
        connAuthFailed: s.errorContainer,
      );

  @override
  AppColors copyWith({
    Color? connConnecting,
    Color? connReconnecting,
    Color? connEnded,
    Color? connAuthFailed,
  }) =>
      AppColors(
        connConnecting: connConnecting ?? this.connConnecting,
        connReconnecting: connReconnecting ?? this.connReconnecting,
        connEnded: connEnded ?? this.connEnded,
        connAuthFailed: connAuthFailed ?? this.connAuthFailed,
      );

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    return AppColors(
      connConnecting: Color.lerp(connConnecting, other.connConnecting, t)!,
      connReconnecting: Color.lerp(connReconnecting, other.connReconnecting, t)!,
      connEnded: Color.lerp(connEnded, other.connEnded, t)!,
      connAuthFailed: Color.lerp(connAuthFailed, other.connAuthFailed, t)!,
    );
  }
}
