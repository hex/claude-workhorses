#!/bin/bash
# ABOUTME: Antigravity SessionStart hook: prints the workhorse policy as the JSON step Antigravity injects, since
# ABOUTME: agy reads a hook's stdout as JSON where Claude Code and Codex take plain text.
set -uo pipefail

# A failing policy script must not leave the session without a word, so its error becomes the step, as in pi and OpenCode.
if ! policy=$(bash "$(dirname "$0")/policy.sh" 2>&1 && printf .); then
  policy="workhorses: $(dirname "$0")/policy.sh failed, so the workhorse policy is missing: $policy"
else
  policy=${policy%$'\n.'}
fi
jq -n --arg text "$policy" '{injectSteps: [{systemMessage: {systemMessage: $text}}]}'
