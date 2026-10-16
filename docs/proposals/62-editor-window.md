# 62 — Code editor in its own window (desktop)

**Status:** idea (2026-10-16) · builds on [60](60-code-editor.md)

## Problem

On Windows, opened files become tabs in the workspace, next to the chat tabs. The user wants
code in its own OS window, with its own tab strip like the workspace: open a file anywhere in
the app and it lands as a tab in the editor window, which can sit on a second monitor.

## Approach

**Plugin:** `desktop_multi_window` (0.3.x, Windows/Linux/macOS). Flutter's own windowing API
ships in 3.44 but is `@internal` and only enabled on the master channel, so it is not usable
on our pinned stable SDK.

- **One editor window at most.** The first file opened on desktop creates it. Later opens send
  `open {scope, path, line}` over a `WindowMethodChannel`, and the window adds a tab (or
  focuses an existing one) and comes to the front.
- **Separate engine:** each window has its own Dart isolate, so nothing is shared in memory.
  - The editor window reads creds from `TokenStore` (secure storage) itself. The token is
    never passed as a window argument.
  - It has its own `ProviderScope`, and its own `editorDocProvider` and dirty state.
  - It persists its tabs under its own prefs keys (`editor_window_tab_ids` and
    `editor_window_active_id`), so they don't collide with `WorkspacePrefs`.
- **Editor window UI:** a tab strip (the workspace's tab-chip look, max 8 tabs) over
  `CodeEditorScreen(embedded: true)`. It keeps the dirty prompt on tab close, and Ctrl+W
  closes a tab. Closing the window prompts if any tab is dirty.
- **Main window:** `EditorOpener.open` on desktop routes to the editor window. File tabs leave
  the workspace. Any file tabs already persisted there move to the editor window on first
  run. Phones are unchanged (pushed route).
- **Runner:** register plugins for each new engine in `windows/runner/flutter_window.cpp`, as
  the package requires. Closing the main window should not discard unsaved edits: either ask
  the editor window before quitting, or keep the process alive until both windows close.
  Decide which in a spike.

## Touches

`pubspec.yaml`; `main.dart` (the sub-window entrypoint branches on window args);
`workspace_screen.dart` and `work_tab.dart` (file tabs removed); `editor_opener.dart`; a new
`editor/presentation/editor_window.dart`; `windows/runner/*.cpp`.

## Risks

- **A second engine roughly doubles memory** (about 50–100 MB). That's acceptable on desktop.
- **Plugin maturity:** the README recommends a `window_manager` fork for some features. Spike
  first: create a window, send a message, register plugins, and check that secure storage
  reads work in the sub-engine.
- **Testing:** Windows builds only run in CI (`release-windows.yml` runs on PRs that touch
  `app/windows/**`), so every check needs a CI build and an install on the PC.
- **Window close semantics:** the main window currently quits the process
  (`SetQuitOnClose(true)`).

## Open questions

- Should the editor window open on the same monitor as the main window, or remember where it
  was last placed?
- If the editor window is closed, should the next file open as a new window (yes, assumed)?
