# DESIGN.md — VibeMobile

Design system contract for the VibeMobile Flutter client. **Read this before any UI
work.** It defines tokens, components, and guardrails so every session produces
consistent UI instead of re-guessing colors, spacing, and type.

- Scope: `app/` (Flutter, Android-first, Material 3).
- Source of truth for *visual* decisions. Architecture/protocol docs live in `/docs`.
- When a value here conflicts with code, the code is wrong — fix the code, not this doc.

---

## 1. Product & user context (why the design is what it is)

VibeMobile is a **developer tool for one power user**: you, managing Claude Code
sessions and shells on a home server from your phone. Design consequences:

- **Dark-first, calm, low-chroma.** Late-night use. No neon, no decoration.
- **Density is premium.** The terminal and session lists win screen real estate.
  Compact over comfortable.
- **State must be glanceable.** Connection state (live / reconnecting / ended) is
  mission-critical and communicated by color, not modals.
- **Terminal legibility is non-negotiable.** Monospace output must be a real mono
  face, not a platform fallback.

North star aesthetic: **Warp / Linear** — dark, quiet, borders over shadows,
elevation near zero.

---

## 2. Color

Material 3, seeded. Do **not** hardcode hex in widgets — read from
`Theme.of(context).colorScheme` and the `AppColors` ThemeExtension (§7).

**Seed:** `#4F9DDE` (calm blue). Dark is default; light is a seeded variant.

Semantic roles (Material 3 `ColorScheme`):

| Role | Use |
|------|-----|
| `primary` | primary actions, send button, badges |
| `primaryContainer` | user chat bubbles |
| `secondaryContainer` | secondary actions, question cards |
| `tertiaryContainer` | permission / approval prompts |
| `errorContainer` | destructive actions, errors |
| `surface` | scaffold + app-bar background |
| `surfaceContainerHighest` | cards, assistant chat bubbles |
| `outlineVariant` | chip + divider borders |

### Connection-state colors — named, not guessed

These currently vary per widget. Lock them as an `AppColors` ThemeExtension so the
terminal banner, chat banner, and session badges all agree:

| Token | State | Base |
|-------|-------|------|
| `connLive` | live session | transparent / no banner |
| `connConnecting` | connecting | `secondaryContainer` |
| `connReconnecting` | reconnecting | `tertiaryContainer` |
| `connEnded` | ended | `surfaceContainerHighest` |
| `connAuthFailed` | auth failed | `errorContainer` |

Rule: connection state is **always** shown by these tokens. Never invent a new
color for a state.

---

## 3. Typography

Two families. Currently the app ships Roboto default + the string `'monospace'`
(platform-random). Fix both.

- **Sans (UI chrome):** system default (Roboto) is fine — keep it.
- **Mono (terminal, tool output, session IDs, code):** ship a real face —
  **JetBrains Mono** or **IBM Plex Mono** via a bundled font asset. Declare in
  `pubspec.yaml`; never use the bare `'monospace'` string again.

Type scale — use Material 3 roles, don't reinvent sizes:

| Role | Use |
|------|-----|
| `titleLarge` | screen titles |
| `titleMedium` | card titles, section headers |
| `bodyMedium` | primary body |
| `bodySmall` | metadata, timestamps |
| `labelLarge` | buttons |
| `labelSmall` | chips, badges, section labels |
| mono / `bodySmall` | terminal + tool output (12px) |

Guardrail: no inline `fontSize:` in widgets except the mono terminal size. Use theme
roles.

---

## 4. Spacing

8px base. Replace the current ad-hoc 12/14/16/24 mix with a token set:

| Token | px | Use |
|-------|----|----|
| `xs` | 4 | intra-component gaps, bubble margins |
| `sm` | 8 | chip padding, tight rows |
| `md` | 12 | default component padding |
| `lg` | 16 | page/section padding, section-header top |
| `xl` | 24 | modal / centered-content padding |

Expose as a `Spacing` const class. Guardrail: no raw pixel padding in widgets — use
`Spacing.*`.

---

## 5. Shape & elevation

- **Radius:** `chip/bubble = 8`, `card = 14`, `thumbnail = 8`. Token these as
  `Radii.sm = 8`, `Radii.md = 14`.
- **Elevation:** near-zero. AppBar `0` (scrolledUnder `2`), Card `0`. Use borders
  (`outlineVariant`) and surface tints, not shadows.
- **Icons:** 20–24 (app-bar actions), 16–18 (chips/badges). Prefer `_outlined`
  variants.

---

## 6. Components (canonical patterns)

- **Chat bubbles** — user: right, `primaryContainer`, `Radii.sm`. Assistant: left,
  `surfaceContainerHighest`, `Radii.sm`. `md` padding, `xs` vertical margin.
- **Permission card** — `tertiaryContainer`, icon + title + description + actions.
- **Question card** — `secondaryContainer`, `FilterChip`s for multi-select.
- **Status banner** — colored by §2 connection tokens; `sm` vertical / `md`
  horizontal padding; 12×12 spinner (strokeWidth 2) when (re)connecting.
- **Composer** — icon buttons (attach, mic) + expanded 1–5 line `TextField` + filled
  send; pending-image carousel (72px) above; `SafeArea`.
- **ProjectCard** — Card + InkWell, `Spacing.lg` padding, folder icon + title
  (`titleMedium`) + metadata (`bodySmall`), live-session badge on icon.
- **Session row** — `ListTile`, compact density, tags as `FilterChip`s below title.

Lists use `VisualDensity.compact`; inputs use `isDense: true`. Keep it.

---

## 7. Stack mapping (where tokens live)

| DESIGN.md | Flutter home |
|-----------|--------------|
| Motion tokens | `core/spacing.dart` → `Motion` const class |
| Color roles | `ColorScheme.fromSeed` in `core/theme.dart` |
| Connection tokens | new `AppColors extends ThemeExtension` in `core/theme.dart` |
| Type roles | `TextTheme` in `core/theme.dart`; mono font in `pubspec.yaml` |
| Spacing | new `core/spacing.dart` → `Spacing` const class |
| Radii | new `core/spacing.dart` → `Radii` const class |
| Component patterns | themed widgets in `features/*/presentation/` |

---

## 8. Guardrails (agent must obey)

1. No hardcoded hex in widgets — `colorScheme` or `AppColors` only.
2. No raw pixel padding/radius — `Spacing.*` / `Radii.*` only.
3. No inline `fontSize:` except the mono terminal size — use `TextTheme` roles.
4. Never the bare `'monospace'` string — use the bundled mono family.
5. Connection state is shown only via §2 tokens.
6. Elevation stays near-zero; use borders/tints, not shadows.
7. Dark is default; every change must look right in both themes.
8. No raw `Duration`/`Curve` in animations — use `Motion.*` (§9).

---

## 9. Motion

**Rule: motion communicates a state change. It never decorates.** If an
animation isn't telling the user that something loaded, arrived, connected, or
navigated, it doesn't ship. The aesthetic (§1) stays calm — the app is alive, not
loud.

Tokens — `core/spacing.dart` → `Motion`:

| Token | ms | Use |
|-------|----|-----|
| `fast` | 120 | colour/opacity swaps, banner + FAB switches |
| `base` | 180 | entrances, page routes |
| `slow` | 240 | size changes (gates), stagger cap |

| Curve | Value | Use |
|-------|-------|-----|
| `Motion.enter` | `easeOutCubic` | anything appearing |
| `Motion.exit` | `easeIn` | anything leaving |

Canonical patterns (all in `core/widgets.dart`):

- **Page navigation** — `sharedAxisRoute<T>()`, never `MaterialPageRoute`.
- **Loading a list/grid** — `SkeletonList` / `SkeletonBox` in the real layout
  geometry, never a bare `CircularProgressIndicator`. A spinner is acceptable
  only for an inline action (upload, button), not a page body.
- **Empty (not error)** — `EmptyState`: icon + title + hint + optional action.
  `ErrorBody` stays for failures.
- **List entrance** — `FadeSlideIn` (fade + 8px rise), `delay` staggered at
  40ms × index, capped at `Motion.slow`. In a recycling `ListView.builder`,
  animate only genuinely new rows — recycled rows must render statically.
- **Streaming text** — `StreamingCursor` as a `WidgetSpan`, never a literal `▍`
  concatenated into the string.
- **State-driven blocks (banner, permission gate)** — `AnimatedSwitcher` keyed on
  the state value; `SizeTransition(alignment: Alignment.topCenter)` + fade so the
  layout grows instead of jumping.
- **Haptics** — `selectionClick()` on send, `mediumImpact()` on an off-screen
  approval arriving, `heavyImpact()` on deny. Nothing else vibrates.

Repeating animations (skeleton pulse, cursor blink) never settle: in widget tests
use `pump(duration)`, not `pumpAndSettle`.
