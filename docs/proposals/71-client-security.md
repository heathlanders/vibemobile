# 71 — Client security: update authenticity, local data, app lock

**Status:** accepted 2026-11-19 · from the 2026-11-19 project review · client + `scripts/release.sh` · `reviewer` pass on the update change

## Problem

Findings read in code on 2026-11-19 (v1.0.40). Paths under `app/` unless noted.

| # | Finding | Where |
|---|---------|-------|
| S1 | Self-update checks a sha256 that comes from the same `/dl/latest.json` as the file. That detects corruption, not tampering. On Windows the zip is mirrored over the install dir and run with `-ExecutionPolicy Bypass`, so a compromised server means code execution on the PC. Android is covered by APK signature continuity. | `lib/features/update/data/update_api.dart:24-33`; `lib/features/update/domain/update_info.dart:104-123` |
| S2 | Transcripts (up to 1 MB per session) are stored in plaintext `SharedPreferences`, never pruned, and Android backup is not disabled. | `lib/features/chat/data/transcript_cache.dart:21-44`; `android/app/src/main/AndroidManifest.xml:15` |
| S3 | No app lock. Anyone holding the unlocked phone can approve a permission or open a shell. | no `local_auth` / `FLAG_SECURE` in the app |
| S4 | Pairing accepts any URL scheme; `http://` would send the token in clear. No QR pairing. | `lib/features/pairing/presentation/pairing_screen.dart:44-58` |

## Proposal

1. **S1 — signed manifest.** `release.sh` signs `latest.json` with an Ed25519 key kept on the box
   (outside the repo); writes `latest.json.sig`. The app pins the public key and refuses an update
   whose manifest signature fails. Then the sha256 inside the manifest is trustworthy. Ship the
   verifying build first, start requiring signatures one release later (so the updater can still
   update itself).
2. **S2.** `android:allowBackup="false"`. Move the cache to files under the app's private dir,
   delete on session delete, cap total size (drop oldest).
3. **S3.** Optional setting "Require unlock": `local_auth` on app resume after N minutes and before
   an Allow from inside the app. Off by default. Windows: skip.
4. **S4.** Reject non-`https` URLs (allow `http://localhost` in debug). QR pairing: the box prints a
   QR of `{url, code}` next to the pairing code; the app scans it. QR is optional — do it only if
   typing the URL is still annoying after S4.

## Not doing

- Certificate pinning. `tailscale serve` issues the certificate and rotates it.
- Encrypting the transcript cache. Private app storage + no backup is enough for one owner.

## Wire / schema impact

- `/dl/latest.json.sig` (new file). No daemon code change: `/dl` is static.
- New dependencies: an Ed25519 verify package (e.g. `cryptography`), `local_auth`.

## Acceptance

- Test: manifest with a wrong or missing signature → update refused; valid → accepted.
- Test: cache prunes past the cap and on session delete.
- Test: pairing with `http://box` shows an error and sends nothing.
- A real release cycle: old build → signed build → next signed build, on phone and Windows.
- `cd app && flutter analyze && flutter test` green; `reviewer` pass recorded.

## What shipped

- **S4** (2026-11-19). `pairing/domain/pairing_url.dart` `pairingUrlError`: pairing accepts only
  `https://` with a host; debug builds may also use `http://localhost` / `http://127.0.0.1`.
  Checked before any request. QR pairing not done (optional per this proposal). To know: the box
  also serves the daemon on a plain-`http` tailnet port; pairing through that URL is now refused
  (existing devices keep working; re-pair with the `https://` address). Tests:
  `pairing_url_test.dart`, plus a screen case in `pairing_screen_test.dart` (red on old code).
- **S2** (2026-11-19). Manifest: `allowBackup="false"`, `fullBackupContent="false"` and
  `data_extraction_rules.xml` excluding every domain from cloud backup and device transfer
  (Android 12+). `TranscriptCache` moved from SharedPreferences to one JSON file per session under
  the app support dir (`transcripts/<id>.json`, id sanitized, temp + rename); a transcript left
  in SharedPreferences by an older build moves to its file on first load. Total capped at 20 MB,
  least recently written first; `delete(id)` runs when a chat is ended from the close X or the
  session list's Kill (bulk prune relies on the size cap). Best-effort: storage errors mean no
  cache. Tests: `transcript_cache_test.dart` (file storage, per-file and total caps, delete,
  migration, id can't escape the dir; red on old code). Not done: no Android build was run for the
  manifest change (CI doesn't build Android); check `flutter build apk` before release.
