# 21 — Motion & polish foundation

Status: **shipped** (client only; no wire, no daemon, no new pub deps)

## Problem

Twenty shipped proposals of real capability, rendered dead still. Before this
change the client had **no** `AnimatedSwitcher`, `Hero`, `TweenAnimationBuilder`,
`AnimatedList` or skeleton anywhere in `app/lib` (the only two `heroTag`s were FAB
disambiguation strings). Every navigation was a stock `MaterialPageRoute`; every
load was a bare `CircularProgressIndicator`; streaming text appended a static `▍`
that never blinked; permission gates snapped the composer down with no transition.

The complaint was "the UI is boring". The diagnosis is **stillness, not palette** —
so DESIGN.md's north star (dark, calm, low-chroma, Warp/Linear, density premium,
elevation ~0) is unchanged. This adds a time axis, not decoration.

## What shipped

New shared primitives in `core/widgets.dart` (previously only `ErrorBody`), each
with ≥2 call sites:

| Widget | Primitive | Call sites |
|---|---|---|
| `SkeletonBox` | `AnimatedBuilder` + `Color.lerp(surfaceContainerHighest, surfaceContainerLow)` | dashboard grid, `SkeletonList` |
| `SkeletonList` | rows of `SkeletonBox` shaped like a compact `ListTile` | project sessions, prompt list, scaffold list, session switcher, session search, changed-files sheet |
| `FadeSlideIn` | `TweenAnimationBuilder<double>` — fade + 8px rise, `delay` staggers via `Interval` | newest chat bubble, dashboard cards |
| `StreamingCursor` | `AnimatedBuilder` + `FadeTransition`, 1.0↔0.25 on `▍` | assistant bubble while streaming |
| `EmptyState` | icon + title + hint + optional action, scrollable (pull-to-refresh) | dashboard, prompt list, scaffold list, session switcher, session search, project sessions |
| `sharedAxisRoute<T>()` | `PageRouteBuilder` fade + 4% slide | **every** `Navigator.push` in the app (14 sites) |

Motion tokens live with the other tokens in `core/spacing.dart` → `Motion`
(`fast` 120ms / `base` 180ms / `slow` 240ms; `enter` = `easeOutCubic`,
`exit` = `easeIn`). Written up as **DESIGN.md §9**.

Surface changes:

- **chat_screen.dart** — blinking cursor via `Text.rich` + `WidgetSpan`
  (replaces the `text + ' ▍'` string concat); newest bubble enters with
  `FadeSlideIn`; permission/question gates slide+fade in via `_gateSwitcher`
  (`AnimatedSwitcher` → `SizeTransition` + `FadeTransition`); connection banner
  cross-fades keyed on `ConnState`; scroll-down FAB scale-swaps into the
  "Approval needed" pill; `HapticFeedback.selectionClick()` on send and
  `heavyImpact()` on deny.
- **dashboard_screen.dart** — skeleton grid using the *same* `_gridDelegate` as
  the real grid (no layout jump on load); staggered card entrance (40ms × index,
  capped at `Motion.slow`).
- Token debt fixed on lines already being touched: bubble padding/radius →
  `Spacing.md` / `Radii.sm` (DESIGN.md §6), card padding `14` → `Spacing.lg`,
  grid spacing `12` → `Spacing.md`, `file_diff_screen.dart`'s literal
  `'JetBrainsMono'` → `AppTheme.monoFontFamily`.

**Shimmer is a plain `AnimatedBuilder`, not the `shimmer` package** — ~25 lines,
and lerping between two `ColorScheme` surfaces satisfies DESIGN.md §2 for free.
Total new pub deps: **zero**.

## Only the newest chat row animates

`ListView.builder` recycles elements, so wrapping every bubble in `FadeSlideIn`
replays the entrance whenever an old row scrolls back into view. Only
`i == messages.length - 1` animates; everything above renders statically.

## Considered and rejected

- **`AnimatedList` for the transcript.** The controller mutates `messages` in
  place while streaming (`_streaming.text` grows), and `AnimatedList` needs
  index-accurate insert/remove callbacks. Retrofitting means restructuring
  `chat_session_controller.dart` for a marginal gain over `FadeSlideIn`.
- **`Hero` tile → chat (deferred, not rejected).** `SessionTile` is a live
  `ListenableBuilder`; a hero flight would rebuild a streaming widget mid-flight
  and needs a `flightShuttleBuilder` snapshot to look right. That can only be
  judged on-device, so it is deferred until a device session — `sharedAxisRoute`
  already carries the transition, the hero was the garnish.

## Verification

- `flutter analyze` — clean (one pre-existing info in `claude_socket.dart`).
- `flutter test` — 45 existing + `test/motion_test.dart` (4 new: `FadeSlideIn`
  reaches opacity 1.0, `SkeletonBox` actually changes colour, `EmptyState`
  renders, `sharedAxisRoute` pushes). Note: `SkeletonBox`/`StreamingCursor`
  repeat forever, so their tests use `pump(duration)` — never `pumpAndSettle`.
- On-device (pending): cursor blinks mid-stream, banner cross-fades when WiFi
  drops, gates slide in, dark **and** light both correct.

## Touches

- client: `core/widgets.dart`, `core/spacing.dart` (`Motion`), `chat_screen.dart`,
  `dashboard_screen.dart`, + `sharedAxisRoute` at all 14 push sites,
  `test/motion_test.dart` (new)
- docs: `app/DESIGN.md` §9 (new), this file, proposals README
