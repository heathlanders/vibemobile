# 55 — Mouse back/forward on desktop

**Status:** building 2026-10-10

From the inbox: "the mouse4 and mouse5 (back and forward in browsers) should go back and forth to
the last screen that was used in the desktop app."

- **History:** `DesktopShell` keeps a back/forward history of rail selections, browser-style.
  Selecting a section pushes the previous one and clears forward.
- **Back (mouse 4):** if a screen is pushed on top (a chat, a settings sub-page), it is closed
  first. Otherwise the rail goes back to the previous section.
- **Forward (mouse 5):** moves forward in the rail history.
- **Wiring:** one `Listener` in `MaterialApp.builder`, above the navigator, so it also sees clicks
  on pushed routes. Desktop only.

Out of scope: forward into a closed route, and history inside the Workspace's own tabs.
