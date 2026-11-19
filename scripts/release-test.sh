#!/usr/bin/env bash
# Exercises scripts/release.sh without touching GitHub or the real release dir
# (proposal 72 Q4): a scratch clone whose origin is a local bare repo.
#   scripts/release-test.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
base="${SCRATCH_DIR:-/data/cache/scratch}"
mkdir -p "$base"
s="$(mktemp -d -p "$base" release-test.XXXX)"; trap 'rm -rf "$s"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

git init -q --bare "$s/origin.git"
git clone -q "$root" "$s/work"
cd "$s/work"
git checkout -q -B main
cp "$root/scripts/release.sh" scripts/release.sh # the version under test, committed or not
git -c user.name=t -c user.email=t@example.invalid commit -qam "test: release.sh under test" || true
git remote set-url origin "$s/origin.git"
git push -q origin main
head="$(git rev-parse HEAD)"

# 1. APK build fails → no commit, no tag (local or remote), pubspec restored.
if FLUTTER=/bin/false VIBE_RELEASE_DIR="$s/out" scripts/release.sh 9.9.9 --skip-windows >"$s/log" 2>&1; then
  fail "release succeeded with a failing APK build"
fi
grep -q "APK build failed" "$s/log" || fail "no build-failure message: $(cat "$s/log")"
[ -z "$(git tag -l v9.9.9)" ] || fail "local tag left behind"
[ -z "$(git ls-remote --tags origin v9.9.9)" ] || fail "remote tag pushed"
[ "$(git rev-parse HEAD)" = "$head" ] || fail "a release commit was made"
[ "$(git ls-remote origin refs/heads/main | cut -f1)" = "$head" ] || fail "main was pushed"
[ -z "$(git status --porcelain)" ] || fail "pubspec not restored: $(git status --porcelain)"
echo "ok - failed APK build leaves no tag, commit or push"

# 2. --rollback repoints latest.json at a retained older build, with its build number.
sed -i 's/^version: .*/version: 1.2.3+77/' app/pubspec.yaml
git -c user.name=t -c user.email=t@example.invalid commit -qam "old release"
git -c user.name=t -c user.email=t@example.invalid tag -a v1.2.3 -m v1.2.3
mkdir -p "$s/out" && echo apk >"$s/out/vibemobile-1.2.3.apk"
echo '{"version":"9.9.8","build":99}' >"$s/out/latest.json"
VIBE_RELEASE_DIR="$s/out" scripts/release.sh --rollback 1.2.3 >/dev/null
[ "$(jq -r '.version' "$s/out/latest.json")" = 1.2.3 ] || fail "rollback version"
[ "$(jq -r '.build' "$s/out/latest.json")" = 77 ] || fail "rollback build"
[ "$(jq -r '.apk.sha256' "$s/out/latest.json")" = "$(sha256sum "$s/out/vibemobile-1.2.3.apk" | cut -d' ' -f1)" ] || fail "rollback sha"
[ "$(jq -r '.windows' "$s/out/latest.json")" = null ] || fail "rollback invented a windows file"
if VIBE_RELEASE_DIR="$s/out" scripts/release.sh --rollback 1.2.4 >/dev/null 2>&1; then fail "rollback to an unknown tag"; fi
echo "ok - rollback repoints latest.json"
