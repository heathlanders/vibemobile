# 49 — Desktop workspace in a non-maximized window

**Status:** accepted (2026-10-10, from the phone Notes inbox). Amends [24](24-desktop-workspace.md).

`DesktopShell.breakpoint` is 1000 px (`desktop_shell.dart`). When a desktop window is narrower than
that, for example snapped to half a screen, the whole app switches to the phone layout. The rail,
workspace, tabs and split view all disappear, so the workspace "just minimizes and isn't available".

- **Desktop platforms keep the shell at every width** (Windows, Linux, macOS). The phone layout is
  chosen by **platform**, not window width. Phones and tablets keep the current behavior.
- **Compact mode below 1000 px:**
  - The rail shows icons only (`NavigationRailLabelType.none`); the plan-usage meter shrinks to fit.
  - The workspace sidebar (project/session list) collapses behind a toggle and opens as an overlay
    drawer.
  - Split view and the changes pane are hidden and their toggles disabled. Tabs, the Ctrl+K palette
    and every session stay available.
- **Minimum window size** of about 600 × 500, so the shell never has to lay out narrower than that.

Out of scope: tablet layouts, persisting sidebar state per width, reflowing the other rail pages
beyond what their own layouts already do.

Tests: widget tests at 700 / 1000 / 1400 px with a desktop platform override check the shell, the rail
label mode, sidebar mode and split toggle state; one test at 700 px on Android checks that the phone
layout is unchanged.
