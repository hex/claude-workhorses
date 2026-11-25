#!/bin/bash
# ABOUTME: Checks that the plugin manifests for Claude Code and Antigravity name the same version, which release.sh bumps.
# ABOUTME: Usage: tests/manifests-check.sh; exits 1 when they differ.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
claude=$(jq -r .version "$root/.claude-plugin/plugin.json")
agy=$(jq -r .version "$root/.antigravity-plugin/plugin.json")
if [ "$claude" != "$agy" ]; then
  echo "FAIL .claude-plugin/plugin.json is at $claude, .antigravity-plugin/plugin.json at $agy" >&2
  exit 1
fi
echo "ok   both manifests are at $claude"
