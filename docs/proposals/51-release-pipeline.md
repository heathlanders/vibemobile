# 51 — Release pipeline and in-app updates

**Status:** building 2026-10-10

One command on the dev box ships both clients. Builds are hosted on the tailnet at a fixed URL,
and the app offers a one-click update when a newer build is out. Before this, the APK was built and
renamed by hand and sideloaded, and the Windows app was built on the PC and copied into
`Program Files` from an admin shell.

- **`scripts/release.sh <x.y.z> [--notes TEXT] [--skip-apk] [--skip-windows]`**: refuses to run
  unless on `main` in sync with `origin`, with a clean tree and a new tag. It bumps
  `app/pubspec.yaml` to `x.y.z+N` (build number = previous + 1), commits, tags `vx.y.z` and pushes.
  It then builds the signed APK on the box (the signing key never leaves it), waits for the
  Windows build, and publishes both.
- **Windows build:** `.github/workflows/release-windows.yml` on GitHub Actions (`windows-latest`,
  Flutter pinned to the box's version, actions pinned by SHA, read-only token). A tag push
  triggers it, PRs touching `app/windows/` also run it as a check, and so does a manual dispatch.
  It needs no secrets: the Windows build has no Firebase config file. The zip is a workflow
  artifact (kept 14 days), pulled down with `gh run download`.
- **Hosting:** `tailscale serve --set-path /dl <release dir>` (`VIBE_RELEASE_DIR`, default
  `/data/volumes/vibemobile/releases`). It holds `vibemobile-x.y.z.apk`,
  `vibemobile-windows-x.y.z.zip`, `index.html` and `latest.json`, and keeps the last 5 of each.
  `latest.json` is `{version, build, notes, apk:{file,sha256}, windows:{file,sha256}}`, written
  last via atomic rename. A skipped platform keeps its previous entry. Access is gated by the
  tailnet only; the files are builds of public source with no secrets in them.
- **In-app update** (`app/lib/features/update/`): checks `https://<paired host>/dl/latest.json`
  on launch and resume, at most hourly, without the device token. If `build` is newer, it shows a
  banner.
  - **Android:** downloads the APK, verifies the sha256 and opens the system installer. Android
    itself enforces the same signing key.
  - **Windows:** downloads and verifies the zip, extracts it, and starts a detached PowerShell
    script. The script waits for the app to exit, `robocopy /MIR`s into the install dir and
    relaunches. This needs a user-writable install, so the app moves to
    `%LOCALAPPDATA%\VibeMobile`. Under `Program Files`, the banner links the zip instead.
    The script also waits for any other running copy of the app, closing it after 20 s;
    a second instance held DLLs locked and robocopy retried forever. Robocopy retries are
    bounded, the app is relaunched even if the copy fails, and everything is
    transcribed to `update.log` in the script's temp dir.
  - **Settings** shows the version at the bottom right, with a **Check for updates** button that
    reports the result or the error. The automatic check stays silent.

Out of scope: auto-update without a click, signed Windows installer (MSIX/Inno), release channels.
