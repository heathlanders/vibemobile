#!/usr/bin/env bash
# Shared by pre-commit and pre-push. This repo is PUBLIC: refuse any added line
# that looks like a credential, or that matches the owner's private denylist
# (kept outside the repo at ~/.config/vibemobile/public-denylist.txt).
# Usage: leak-scan.sh <file holding a unified diff>
set -euo pipefail
diff_file="$1"

# Generic credential shapes — safe to publish, so they live here.
secrets='sk-ant-[A-Za-z0-9_-]{10,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|xox[bpas]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----[A-Za-z0-9+/=]{20,}'

added=$(grep -E '^\+' "$diff_file" | grep -vE '^\+\+\+ ' || true)
fail=0

if hits=$(printf '%s\n' "$added" | grep -nE "$secrets"); then
  echo "leak-scan: possible credential in the change:" >&2
  printf '%s\n' "$hits" | cut -c1-160 >&2
  fail=1
fi

denylist="${VIBE_DENYLIST:-$HOME/.config/vibemobile/public-denylist.txt}"
if [ -f "$denylist" ]; then
  patterns=$(grep -vE '^\s*(#|$)' "$denylist" || true)
  if [ -n "$patterns" ] && hits=$(printf '%s\n' "$added" | grep -niE -f <(printf '%s\n' "$patterns")); then
    echo "leak-scan: private string from the denylist in the change:" >&2
    printf '%s\n' "$hits" | cut -c1-160 >&2
    fail=1
  fi
else
  echo "leak-scan: warning: no denylist at $denylist (credential check only)" >&2
fi

if [ "$fail" -ne 0 ]; then
  echo "leak-scan: blocked. This repo is public — move private details to vibemobile-notes." >&2
  exit 1
fi
