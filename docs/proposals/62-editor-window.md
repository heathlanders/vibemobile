# 62 — Code editor in its own window (desktop)

**Status:** shipped (2026-10-17, v1.0.34; on-device check passed on Windows) · builds on [60](60-code-editor.md)

## Problem

On Windows, opened files become tabs in the workspace, next to the chat tabs. The user wants
code in its own OS window, with its own tab strip like the workspace: open a file anywhere in
the app and it lands as a tab in the editor window, which can sit on a second monitor.

## Options considered

- **Flutter windowing API:** ships in 3.44 but is `@internal` and enabled only on the master
  channel. Not usable on our pinned stable SDK.
- **`desktop_multi_window` 0.3.1:** spike reading of its source. Sub-windows are fixed at
  800×600 with an empty title, the Dart API is only show/hide, and `WM_CLOSE` destroys the
  window without asking Dart. Unsaved edits would be lost, and title, size and focus all need
  a patched `window_manager` fork. Rejected.
- **A second app process in editor mode (chosen).** It is the same `vibemobile.exe`, started
  with `--editor`. It's a normal Flutter window, so the cancelable exit prompt
  (`AppLifecycleListener.onExitRequested`, already used by the workspace) works. No new
  plugin is needed, and closing the main window leaves the editor open.

## Approach

- **Launch:** the main window starts the editor with
  `Process.start(Platform.resolvedExecutable, ['--editor'], detached)`. `main(args)` branches
  on `--editor` before push and updater init. The runner gives that window the title
  "VibeMobile Editor".
- **One editor at a time.** The editor holds an exclusive lock on
  `<app support>/editor/editor.lock`. Whoever opens a file writes a request
  `{v:1, scope, path, line}` to `editor/inbox/<uuid>.json` (tmp file, then rename). If the lock
  is free, nobody is running, so the opener also spawns the editor. The editor drains the
  inbox on start, then watches it (with a 1 s poll fallback).
- **Requests are validated.** Scope must match `projects/<id>` or `sessions/<id>`, the path
  must be a string, and the line a positive int. Files are still read through the
  authenticated API, so the inbox carries no secrets.
- **Front:** before writing, the main window calls `AllowSetForegroundWindow(ASFW_ANY)`. The
  editor then restores itself and calls `SetForegroundWindow`, using user32 via `dart:ffi`.
- **Editor window:**
  - It reads creds from `TokenStore` itself. If not paired, it shows "Pair in the main
    window".
  - It has a tab strip of up to 8 tabs over `CodeEditorScreen(embedded: true)`, with a dirty
    dot and a dirty prompt on tab close. Ctrl+W closes a tab and Ctrl+Tab switches tabs.
  - On window close it shows the dirty prompt (cancelable).
  - It saves its tabs in `editor/tabs.json`, not SharedPreferences, because the two processes
    would overwrite each other's prefs file.
- **Main window (Windows only):** `EditorOpener` sends opens to the editor process. Workspace
  file tabs restored from earlier versions are forwarded to the editor once and dropped.
  Other platforms are unchanged.
- **Updates:** before handing off, the updater sends `{v:1, quit:true}`. The editor exits, or
  prompts first if anything is dirty. The updater waits up to 15 s for the lock. If the lock
  is still held, it aborts with "Close the editor window to update".

## Touches

- `main.dart`
- `windows/runner/main.cpp` (title)
- `features/editor/` (new `editor_window/`: IPC, app, tabs)
- `workspace_screen.dart` (route + migration)
- `update_installer.dart`

## Risks

- **A second process roughly doubles memory** (about 50–100 MB). That's acceptable on desktop.
- **Windows builds only in CI.** The PR touches `app/windows/**`, so `release-windows.yml`
  produces an artifact to install and test on the PC.
- **The editor process holds DLLs**, so the updater must close it first. That is covered by
  the quit request above.

## Built

Code is in `app/lib/features/editor/window/`: `editor_ipc.dart` (request validation, lock, inbox),
`editor_launcher.dart` (open, spawn, quit-for-update), `editor_native.dart` (user32 via ffi),
`editor_tabs.dart` (pure tab model + `tabs.json`), `editor_window_app.dart` (the app).
Tests: `app/test/editor_window_test.dart`.

Deviations from the plan above:

- **`package:ffi` added as a direct dependency** (`^2.2.0`). It was already in the lockfile as a
  transitive one; `dart:ffi` alone has no allocator for the UTF-16 strings `FindWindowW` needs.
- **Opening an already-open file focuses its tab but does not move the cursor** to a new line.
  Jumping needs a change to `CodeView`, which only applies `line` when it first shows. The line is
  honoured when the tab is newly opened.
- **Inbox names** are a zero-padded microsecond timestamp plus 8 random hex digits, not a plain
  uuid, so name order is send order.
- **Workspace migration** is inline in `_restore` (a three-line branch), not an extracted helper.
  `_openFile` itself routes to the editor window on Windows, which covers the `EditorOpener`
  callback and the file-browser callback.
- **No `AppLifecycleListener.onExitRequested` existed in the workspace**; the editor window is its
  first user. The proposal text saying "already used by the workspace" was wrong.
- **Touches:** the folder is `window/`, not `editor_window/`.
- POSIX file locks are per process, so the "lock held" unit test spawns a `dart` process.

Needs checking on a Windows machine (no Windows build here):

1. Open a file from a chat link, the file browser and the palette: one "VibeMobile Editor" window
   appears, a second file adds a tab, and the window comes to the front (also when minimized).
2. Closing the main window leaves the editor open; reopening a file reuses it.
3. Close button with unsaved edits shows the discard prompt, and Keep editing cancels the exit.
4. Ctrl+W and Ctrl+Tab / Ctrl+Shift+Tab work with focus inside the text area.
5. Tabs come back after restarting the editor; 9th file evicts the oldest clean tab.
6. Old workspace file tabs move to the editor once, then vanish from the main window.
7. Unpaired: editor shows "Not paired".
8. Update with the editor open: it quits (prompting if dirty) and the update proceeds; with a dirty
   file left open, the update stops with "Close the editor window to update".
