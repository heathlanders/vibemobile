# 54 — Phone layout: portrait, Discord-style navigation

**Status:** shipped 2026-10-10 (v1.0.24)

From the user, on a real phone: the app showed the desktop layout, with a fixed rail plus the
workspace sidebar, cramped and overlapping. The user wants portrait only, just the important
features, a sidebar that slides in and out instead of being fixed, and navigation that works
"similar to the Discord mobile app".

**Cause:** proposal 49 shows `DesktopShell` on any screen at least 1000 logical px wide, and a phone
held in landscape crosses that.

- **A phone always gets the phone layout.** A phone is a mobile platform whose shortest side is
  under 600 dp. `DesktopShell.shown` is never true on one; tablets and desktops keep proposal 49's
  rule. Phones are locked to portrait at startup.
- **`PhoneShell`, modelled on Discord mobile:**
  - The main view is the open chat, full screen, the way Discord shows the current channel.
  - **Swiping right** (or tapping ☰) slides the chat aside and reveals the navigation panel.
    Swiping left, or tapping the chat edge that still shows, slides it back.
  - The panel has a narrow **project rail** on the left: round initials icons with a live-session
    dot, like Discord's server list. At the top of the rail is a **Live** entry, which plays the
    role of Discord's DMs: sessions that are running or need you.
  - Next to the rail is the **session list** for the selected project, like a channel list,
    with "new chat" and "new terminal" at the top. Tapping a session closes the panel and
    opens it.
  - A **bottom bar** appears only while the panel is open, as in Discord: Home, Live (attention
    badge), Search, and You (usage meters, prompts, multi-chat, settings).
  - Android back while a chat is showing opens the panel, as in Discord. Back on the panel leaves
    the app as usual.
  - It starts with the panel open on the last project, and remembers the last opened session.
- `DashboardScreen` stays as the desktop shell's Projects page; phones no longer use it as home.

Client only. Desktop and tablets are unchanged.
