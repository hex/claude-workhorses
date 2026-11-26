#!/bin/bash
# ABOUTME: Prints the SessionStart response that Claude Code, Cursor and VS Code consume.
# ABOUTME: The context is the same policy that the plain-text hook prints.
set -euo pipefail

here=$(dirname "$0")
bash "$here/policy.sh" | jq -Rsc -L "$here/lib" 'include "session-start"; rtrimstr("\n") | session_start'
