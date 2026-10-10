# 53 — Floating toasts

**Status:** building 2026-10-10

From the inbox: the "Copied" style messages show as "a big white bar across the bottom of the
screen". That was Material's default snackbar, which is full width and uses the inverse surface,
so it shows as white in the dark theme.

- **One theme change, every call site:** `AppTheme` sets `snackBarTheme`, and none of the ~40
  `showSnackBar` calls change. The toast floats above the bottom edge on `surfaceContainerHigh`,
  with an `outlineVariant` border, `Radii.md` corners and elevation 1 (DESIGN.md §5), and
  `onSurface` text.
- **Width:** inset `Spacing.lg` from the edges on phones. On wide screens (desktop) it is capped
  at 440 px and centred, set in the `MaterialApp.builder` because the theme doesn't know the
  screen size.

Client only. Out of scope: a top-of-screen overlay toast, or icons per message type.
