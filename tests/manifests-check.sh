#!/bin/bash
# ABOUTME: Checks that the manifests for Claude Code, Codex, Antigravity and npm (pi, OpenCode) name the same version, which
# ABOUTME: release.sh bumps. Usage: tests/manifests-check.sh; exits 1 when one differs.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
want=$(jq -r .version "$root/.claude-plugin/plugin.json")
for manifest in .codex-plugin/plugin.json .antigravity-plugin/plugin.json package.json; do
  got=$(jq -r .version "$root/$manifest")
  if [ "$got" != "$want" ]; then
    echo "FAIL .claude-plugin/plugin.json is at $want, $manifest at $got" >&2
    exit 1
  fi
done
echo "ok   every manifest is at $want"
