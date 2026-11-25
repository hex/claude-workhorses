#!/bin/bash
# ABOUTME: Checks that the plugin manifests for Claude Code, Codex and Antigravity name the same version, which
# ABOUTME: release.sh bumps. Usage: tests/manifests-check.sh; exits 1 when one differs.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
want=$(jq -r .version "$root/.claude-plugin/plugin.json")
for manifest in .codex-plugin/plugin.json .antigravity-plugin/plugin.json; do
  got=$(jq -r .version "$root/$manifest")
  if [ "$got" != "$want" ]; then
    echo "FAIL .claude-plugin/plugin.json is at $want, $manifest at $got" >&2
    exit 1
  fi
done
echo "ok   every manifest is at $want"
