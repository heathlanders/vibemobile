# 50 — Workflow screenshots (headless, phone + desktop)

**Status:** accepted (2026-10-10)

Screenshots of each workflow, step by step, at phone and desktop sizes. They're for the README and
docs, and for checking a change visually without a device. Generated headless on the dev box with
Flutter widget tests, so no emulator, Windows PC or browser is needed.

**Why not Playwright:** the app has no web target. A Flutter web build draws to a canvas, so
Playwright would only see pixels, and several plugins (secure storage, pasteboard, FCM, speech)
don't run on the web. Flutter's own test renderer captures the real widgets.

- **Where:** `app/screenshots/*_test.dart`, separate from `app/test/` so `flutter test` stays fast
  and unchanged. Run them with `scripts/screenshots.sh` (`flutter test screenshots --update-goldens`).
- **Output:** `docs/screenshots/<workflow>/<size>/NN-step.png` and an index,
  `docs/screenshots/README.md`, which links every image under its workflow and step caption.
- **Sizes:** `phone` 412×915 (Android theme), `desktop` 1440×900 and `desktop-compact` 800×700
  (Windows platform override, so `DesktopShell` and its compact mode show).
- **Rendering:** real fonts (the bundled JetBrainsMono, Roboto and MaterialIcons loaded from the
  Flutter SDK with `FontLoader`), so text and icons aren't boxes. Animations are settled, and the
  clock and random values are fixed so reruns are byte-stable.
- **Data:** fakes only, from the existing test fakes and fixtures. No real hostnames, paths, names or
  tokens (the repo is public): `box.tailnet.ts.net`, project `demo-app`, and so on.
- **First workflows** (the 2026-10-10 inbox work): paste collapse (47), file links (48), copy (06),
  compact desktop workspace (49), and a chat overview. More flows (pairing, dashboard,
  permissions, terminal, workspace) are added the same way later.

Out of scope: device frames, real-device or emulator screenshots (integration_test, a possible
follow-up), image diff checks in CI.
