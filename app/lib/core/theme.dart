import 'package:flutter/material.dart';

/// App theme — a Material 3 scheme tuned for a dev/terminal tool. Dark is the
/// default (see theme_controller.dart); light is the same scheme inverted. The
/// xterm terminal renders its own ANSI colors and is left untouched.
class AppTheme {
  AppTheme._();

  static const _seed = Color(0xFF4F9DDE); // calm blue accent

  /// Bundled monospace family — terminal, tool output, code, session IDs.
  /// See app/DESIGN.md §3. Never use the bare 'monospace' string.
  static const String monoFontFamily = 'JetBrainsMono';

  static ThemeData get dark => _build(Brightness.dark);
  static ThemeData get light => _build(Brightness.light);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
    return ThemeData(
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
