#!/bin/bash
# ABOUTME: Fits the Claude Code, Cursor and VS Code startup context into 8500 JSON bytes.
# ABOUTME: Drops the tools first, then notes, so host selection and offload rules take priority.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
printf -v command 'bash %q --full' "$here/policy.sh"
if ! sections=$(bash "$here/policy.sh" --sections 2>&1); then
  printf '%s' "workhorses: $here/policy.sh failed, so the workhorse policy is missing: $sections" |
    jq -Rsc '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: .}}'
  exit 0
fi
printf '%s\n' "$sections" | jq -sc --arg command "$command" -f "$here/lib/session-start.jq"
