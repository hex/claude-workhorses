#!/bin/bash
# ABOUTME: Fits the Claude Code, Cursor, VS Code and Grok Build startup context into 8500 JSON bytes.
# ABOUTME: Drops the tools first, then notes, so host selection and offload rules take priority.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
printf -v command 'bash %q --full' "$here/policy.sh"
missing_context() {
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"workhorses: the startup policy could not be rendered."}}'
}

warnings=$(mktemp) || { missing_context; exit 0; }
trap 'rm -f "$warnings"' EXIT
failure=""
if sections=$(bash "$here/policy.sh" --sections 2>"$warnings"); then
  :
else
  failure="workhorses: $here/policy.sh failed, so the workhorse policy is missing: "
  [ -s "$warnings" ] || printf 'renderer exited without a diagnostic' >"$warnings"
  sections=""
fi
if ! json=$(printf '%s\n' "$sections" | jq -sc --rawfile warnings "$warnings" \
    --arg failure "$failure" --arg command "$command" -f "$here/lib/session-start.jq"); then
  missing_context
  exit 0
fi
printf '%s\n' "$json"
