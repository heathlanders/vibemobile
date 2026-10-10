# 24 — Desktop workspace (session cockpit)

Status: **shipped (code)**: roadmap phase 1 of [ADR 0015](../decisions/0015-desktop-client.md).
Non-maximized windows: see [proposal 49](49-responsive-desktop.md) (2026-10-10). Below the 1000 px
breakpoint the app currently falls back to the phone layout and the workspace is lost.
Client only, no daemon change. It hasn't been run as a Windows build yet (that
needs the PC).

## Problem

On a wide screen the phone flow wastes space. Each session is its own pushed
route, so you can't watch one session while typing in another, and the
changed-files list is a modal sheet. Moving between sessions takes a trip back
through the project list.

## What shipped

`features/workspace/` adds a **Workspace** page, which is the first rail
destination in `DesktopShell`. The shell keeps it mounted while other pages
show.

- **Sidebar:** projects as expandable tiles. Each lists its openable sessions
  (live ones first, CLI sessions marked "on PC") and has **+ Chat** and
  **+ Terminal** buttons. New chats use the default model; the model picker
  arrives with phase 2's registry.
- **Tabs:** up to 8 open sessions, each a full `ChatScreen` or `TerminalScreen`.
  - Closing a tab only detaches. Close inside the session deletes it, then
    closes the tab through the new `onClose` hook, because a tab isn't a route
    and can't be popped.
  - Drag a tab to reorder it (2026-10-06). A plain click still selects; the drag
    starts only past touch slop. Sessions don't remount when moved.
  - Overflow (2026-10-06): tabs share one width and shrink to fit, down to a
    40px label (full title in the tooltip). Past that the strip scrolls: the
    mouse wheel moves it sideways, a scrollbar shows, and the active tab
    (click, Ctrl+Tab, palette, new tab) scrolls into view.
  - Open tabs, their order, and the active tab survive a relaunch (`WorkspacePrefs`).
- **Split:** shows the active tab and one other side by side.
- **Sidebar refresh:** expanded project lists refetch every 15 s while the
  Workspace is visible, and the whole sidebar refetches when the window regains
  focus, so sessions started on the phone appear without pressing Refresh.
- **Changes pane:** the project's git summary plus the active chat's changed
  files (`ChangedFilesList`, now embeddable). Clicking a file pushes its diff.
- **Keys:**

  | Key | Action |
  |---|---|
  | Ctrl+K | Quick-open palette |
  | Ctrl+Tab / Ctrl+Shift+Tab | Next / previous tab |
  | Ctrl+W | Close tab |
  | Ctrl+\ | Split |
  | Enter | Send (composer, desktop) |
  | Shift+Enter | Newline (composer, desktop) |

  A focused terminal gets keys first, so these chords go to the shell there.
- **Drag-drop:** dropping image files on a chat attaches them (`desktop_drop`).
  The daemon still sniffs the type and enforces the size limit.

## How tabs stay alive

Every tab stays mounted. Hidden tabs sit under
`Visibility(visible: false, maintainState: true)`, which keeps their state and
also sets `TickerMode` off and adds `ExcludeFocus`. A `GlobalKey` per tab lets a
session move between the visible panes and the hidden stack without being
rebuilt, so the socket, scrollback and composer draft survive.

`ChatScreen` reads `TickerMode` to decide whether it is on screen. A prompt in a
hidden tab therefore still raises a local notification, while the visible
panes show their prompts as cards.

## Known limits

- ~~Opening the same session in Multi-chat and in a workspace tab gives two
  sockets.~~ Fixed 2026-10-06: both views share one pooled controller
  ([proposal 19](19-multi-chat-grid.md)).
- ~~Tab labels don't update when the auto-titler renames a session.~~ Fixed
  2026-10-06: `ChatScreen.onTitle` reports each `title` frame (and the title a
  pooled controller already holds); the workspace keeps a live title map that
  beats the stale `Session.title`.
- A manual rename (sidebar menu) doesn't reach an open chat's header or tab:
  `PATCH /sessions/:id` sends no `title` frame, and the controller's last
  frame wins over the REST row. Reopening the tab shows the new name.

## Composer keys
Plain Tab in the chat composer inserts two spaces and keeps focus (no jump to
the next GUI section). Shift+Tab still cycles session mode; Ctrl+Tab still
cycles workspace tabs.
