#!/usr/bin/env bash
# PreToolUse guard: when a Flutter UI file is edited, inject a reminder to follow
# app/DESIGN.md. No output (= no-op) for non-UI files.
f=$(jq -r '.tool_input.file_path // empty')
case "$f" in
  */app/lib/*/presentation/*.dart|*/app/lib/core/theme*.dart|*/app/lib/core/spacing.dart|*/app/lib/main.dart)
    cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"UI file edit — follow app/DESIGN.md. Guardrails: no hardcoded hex (use ColorScheme/AppColors); no raw px padding/radius (use Spacing.*/Radii.*); no inline fontSize except mono terminal (use TextTheme roles); never the bare 'monospace' string (use bundled mono); connection state only via named tokens; elevation near-zero; must look right in dark AND light. Read app/DESIGN.md if you haven't this session."}}
JSON
    ;;
esac
