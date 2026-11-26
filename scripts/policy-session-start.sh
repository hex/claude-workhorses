#!/bin/bash
# ABOUTME: Prints the SessionStart response that Claude Code, Cursor and VS Code consume.
# ABOUTME: The context is the same policy that the plain-text hook prints.
set -euo pipefail

policy=$(bash "$(dirname "$0")/policy.sh")
jq -n --arg text "$policy" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $text}}'
