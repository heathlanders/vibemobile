# 38 — Terminal key row (mobile)

**Status:** implemented (code + tests 2026-10-07; on-device check pending)

A phone keyboard has no Esc, Tab, arrows or Ctrl, which makes the terminal tab nearly
unusable for anything interactive (vim, htop, readline history, Ctrl+C). Found by the gap
analysis; `app/` had no key row at all.

- **`TerminalKeyRow`** (`terminal/presentation/terminal_key_row.dart`, mobile only —
  `isMobile`): Esc, Tab, sticky **Ctrl**, ← ↑ ↓ →, Home/End/PgUp/PgDn, and `| ~ / - _ \ \` * & < >`.
  Built on xterm's `keyInput` / `textInput`, so application-cursor mode and modifiers behave as
  for a hardware keyboard.
- **`CtrlLatch`** (`terminal/domain/ctrl_latch.dart`, pure): Ctrl is one-shot. Arm it, then type
  one letter on the soft keyboard and the controller sends the control code instead (Ctrl+C =
  0x03 …). Wired in `TerminalSessionController` (`terminal.onOutput = sendInput(ctrl.take(data))`).
  Any input disarms; only a single letter / `@[\]^_` / space maps; digits, pastes and escape
  sequences pass through. Ctrl + a row key sends the modified key (Ctrl+←).
- No server change; hidden on desktop (a real keyboard exists).

Out of scope: customizing the key set, long-press repeat, function keys.

Tests: `app/test/terminal_keys_test.dart`.
