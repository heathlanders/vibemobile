# ADR 0025 — Storage layout: `/data` is the default for repos, caches and Docker

**Status:** Accepted (2026-10-07). Caches and models are moved and verified across a
reboot; the env wiring is in place; **Docker's data-root is on `/data/docker`** (verified:
same 37 containers/27 volumes, identical Postgres sizes). Repos mostly stay where they are
(see "Repos" below).

**Repos (decided 2026-10-07):** moving a repo changes the path that the project row in
`vibe.db`, the Claude transcripts, the per-project auto-memory folder and worktree paths are
keyed on, and the scanner ignores symlinks (`Dirent.isDirectory()`), so a symlink left at the
old path is not listed. Most `node_modules` bytes are also hardlinked into the pnpm store, so
moving a repo frees little. Existing repos stay in `/home/user`; **new** projects land in
`/data/projects` (`VIBE_PROJECT_ROOTS`). Only idle repos with no session history are moved.
pnpm should create its own per-drive store (`/data/.pnpm-store`) for projects on `/data`; the
global store variable stays unset.

## Context

`/` is a 238G SSD that also held every repo, every build cache, the Android SDK, the
model files and Docker's whole data root. It reached 94% full (ADR 0019's monitor had
already seen it at 92%). A second SSD, `sdb` (931G), sat holding old game installs.
There was no rule saying where new data goes, so every tool defaulted to `$HOME` on `/`.

Drives (device letters can change; identify by model):

| Mount | Drive | Role |
|---|---|---|
| `/` | Samsung 840 SSD, 238G | OS, `~/.claude`, `~/.vscode-server`, small config only |
| `/data` | WD Blue SSD, 931G, **ext4** (UUID in fstab, `nofail`) | **repos, caches, models, Docker** |
| `/mnt/sdd1` | WD Green HDD, 1.8T, NTFS (physical `sda`) | **media library: never modified**; only `/mnt/sdd1/backups/` may be written |
| `/mnt/ro-sdd1` | Seagate HDD, 298G, NTFS (physical `sdd`) | legacy, read-only, not used |

## Decision

1. **Layout on `/data`:** `projects/` (repos), `cache/` (gradle, pub-cache, rustup,
   pnpm store, npm, JetBrains, Playwright, flutter), `models/` (ollama, comfyui),
   `android/` (SDK), `docker/` (Docker data-root), `volumes/<project>/` (large data
   bind-mounted into containers).
2. **One env file is the source of truth:** `~/.config/data-paths.env` (plain `KEY=value`,
   absolute paths). It is loaded by the `vibe-daemon` unit (`EnvironmentFile=`), so every
   Claude session and tmux terminal the daemon starts inherits it; by
   `~/.config/environment.d/50-data-paths.conf` (a symlink to it) for other user services;
   and by `~/.bashrc`. Variables are only added once the data they point at has moved.
3. **The daemon is told where projects live** (`~/.config/vibe-daemon.env`):
   `VIBE_PROJECT_ROOTS=/data/projects,/home/user` (first root is where `POST /projects`
   creates new projects; sessions are only allowed inside these roots, so a repo outside
   them is rejected by `pathInRoots`) and `VIBE_DISKS=/,/data,/mnt/sdd1`.
4. **pnpm store and repos stay on the same filesystem.** pnpm hardlinks packages from
   the store into `node_modules`; across filesystems it silently copies. They move together.
5. **Never create a cache or data directory on `/`.** New tools get a `/data/cache/<tool>`
   path and a line in `data-paths.env`; new large data goes under `/data/volumes/<project>`.
6. **Old paths stay as symlinks** (`~/Android`, `~/.gradle`, ...) so absolute paths baked into
   venvs, `local.properties` and shebangs keep resolving.

## Consequences

- **Alerts need no new code.** ADR 0019 already pushes when any monitored disk passes 90%
  full; adding `/data` and `/mnt/sdd1` to `VIBE_DISKS` puts them under the same alert.
- **If `/data` fails to mount**, the symlinks dangle and the tools above fail. `nofail` keeps
  the box booting; check `findmnt /data` first.
- **Moving a repo changes its path**, and Claude transcripts live in
  `~/.claude/projects/<encoded cwd>/`, looked up by path (`session-ws.ts`, `discover.ts`).
  Move one idle repo first and confirm session history and resume still work before moving
  the rest.
- Docker's `data-root` moves everything at once (images, named volumes, build cache); compose
  bind mounts follow the repo, not Docker. Needs one downtime window.
- The pnpm store and `npm` cache variables are deliberately **not** set yet; setting them before
  their data moves would copy packages across filesystems.
- Backups of `/data` are written to `/mnt/sdd1/backups/` only; the media directories are never touched.

**See also:** the step-by-step ops log, with verification and rollback, is
[ops/2026-10-07-root-disk-cleanup.md](../ops/2026-10-07-root-disk-cleanup.md).
