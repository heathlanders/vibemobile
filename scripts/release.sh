#!/usr/bin/env bash
# Cut a release (proposal 51): bump the version, tag and push, build the signed
# APK here, fetch the Windows zip from GitHub Actions, and publish both to the
# release dir that `tailscale serve --set-path /dl` exposes on the tailnet.
#
#   scripts/release.sh 1.0.18 [--notes "text"] [--skip-apk] [--skip-windows]
#
# Env: VIBE_RELEASE_DIR (default /data/volumes/vibemobile/releases), FLUTTER.
set -euo pipefail

usage() { echo "usage: $0 <x.y.z> [--notes TEXT] [--skip-apk] [--skip-windows]" >&2; exit 2; }
die() { echo "release: $*" >&2; exit 1; }

version="${1:-}"; [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage; shift
notes="" apk=1 win=1
while [ $# -gt 0 ]; do
  case "$1" in
    --notes) notes="${2:-}"; shift 2 ;;
    --skip-apk) apk=0; shift ;;
    --skip-windows) win=0; shift ;;
    *) usage ;;
  esac
done

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${VIBE_RELEASE_DIR:-/data/volumes/vibemobile/releases}"
flutter="${FLUTTER:-$HOME/flutter/bin/flutter}"
tag="v$version"
keep=5

cd "$root"
[ "$(git branch --show-current)" = main ] || die "not on main"
[ -z "$(git status --porcelain)" ] || die "working tree not clean"
git fetch -q origin main --tags
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || die "main is not in sync with origin/main"
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && die "tag $tag already exists"

# 1. Bump pubspec: version x.y.z+N, build number always previous + 1.
build=$(( $(sed -n 's/^version: .*+\([0-9]*\)$/\1/p' app/pubspec.yaml) + 1 ))
sed -i "s/^version: .*/version: $version+$build/" app/pubspec.yaml
git commit -qm "chore(release): $tag" app/pubspec.yaml
git tag -a "$tag" -m "$tag"
git push origin main "$tag"   # tag push starts .github/workflows/release-windows.yml
echo "release: pushed $tag (build $build)"

mkdir -p "$out"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# 2. APK, built here so the signing key never leaves this box.
if [ "$apk" = 1 ]; then
  avail=$(awk '/MemAvailable/ {print int($2/1048576)}' /proc/meminfo)
  [ "$avail" -ge 4 ] || echo "release: warning: only ${avail}G RAM free (stop the mi-* docker stack if the build gets OOM-killed)" >&2
  (cd app && "$flutter" build apk --release)
  cp app/build/app/outputs/flutter-apk/app-release.apk "$tmp/vibemobile-$version.apk"
fi

# 3. Windows zip from the Actions run for this tag.
if [ "$win" = 1 ]; then
  run=""
  for _ in $(seq 30); do
    run=$(gh run list --workflow release-windows.yml --branch "$tag" --event push \
      --json databaseId --jq '.[0].databaseId // empty')
    [ -n "$run" ] && break
    sleep 10
  done
  [ -n "$run" ] || die "no release-windows run found for $tag"
  gh run watch "$run" --exit-status >/dev/null || die "Windows build failed: gh run view $run --log-failed"
  gh run download "$run" -n vibemobile-windows -D "$tmp/win"
  mv "$tmp/win/vibemobile-windows.zip" "$tmp/vibemobile-windows-$version.zip"
fi

# 4. Publish: files first, latest.json last (atomic rename) so clients never
#    see a half-written release. A skipped platform keeps its previous entry.
entry() { [ -f "$tmp/$1" ] && jq -n --arg f "$1" --arg s "$(sha256sum "$tmp/$1" | cut -d' ' -f1)" '{file:$f,sha256:$s}' || echo null; }
apk_entry=$(entry "vibemobile-$version.apk")
win_entry=$(entry "vibemobile-windows-$version.zip")
prev='{}'; [ -f "$out/latest.json" ] && prev=$(cat "$out/latest.json")
cp "$tmp"/vibemobile-*"$version"* "$out"/ 2>/dev/null || true
jq -n --arg v "$version" --argjson b "$build" --arg n "$notes" \
  --argjson a "$apk_entry" --argjson w "$win_entry" --argjson p "$prev" \
  '{version:$v, build:$b, notes:$n, apk:($a // $p.apk), windows:($w // $p.windows)}' \
  > "$out/.latest.json.tmp"
mv "$out/.latest.json.tmp" "$out/latest.json"

# Keep the newest $keep of each kind.
for pat in 'vibemobile-[0-9]*.apk' 'vibemobile-windows-*.zip'; do
  (cd "$out" && ls -1 $pat 2>/dev/null | sort -V | head -n -"$keep" | xargs -r rm -f)
done

{
  echo "<!doctype html><meta charset=utf-8><title>VibeMobile releases</title>"
  echo "<h1>VibeMobile $version</h1><p>$(jq -r '.notes' "$out/latest.json" | sed 's/&/\&amp;/g; s/</\&lt;/g')</p><ul>"
  for f in $(cd "$out" && ls -1 vibemobile-*.apk vibemobile-windows-*.zip 2>/dev/null | sort -rV); do
    echo "<li><a href=\"$f\">$f</a></li>"
  done
  echo "</ul><p><a href=\"latest.json\">latest.json</a></p>"
} > "$out/index.html"

echo "release: published $tag to $out"
jq . "$out/latest.json"
