#!/bin/bash
# ABOUTME: Antigravity SessionStart hook: prints the workhorse policy as the JSON step Antigravity injects, since
# ABOUTME: agy reads a hook's stdout as JSON where Claude Code and Codex take plain text.
set -euo pipefail

policy=$(bash "$(dirname "$0")/policy.sh")
jq -n --arg text "$policy" '{injectSteps: [{systemMessage: {systemMessage: $text}}]}'
