#!/bin/bash
# ABOUTME: Checks what the session-start hook, scripts/policy.sh, tells Claude for a good, a missing and a bad hosts file.
# ABOUTME: Usage: tests/policy-check.sh; no host is contacted; exits 1 on the first wrong answer.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
root=$(cd "$here/.." && pwd -P)
config=$(mktemp -d "${TMPDIR:-/tmp}/policy-check.XXXX")
trap 'rm -rf "$config"' EXIT
export CLAUDE_WORKHORSES_CONFIG_DIR=$config

fail() { echo "FAIL $*" >&2; exit 1; }

out=$("$BASH" "$root/scripts/policy.sh")
[ "$out" = "claude-workhorses: no workhorses are configured (no hosts file at $config/hosts), so wh cannot run; the plugin's README shows how to add one." ] ||
  fail "a missing hosts file: got '$out'"
echo "ok   with no hosts file, one line says so"

printf '%s\n' "gamma g x86_64 6 16 spare Turquoise Green" >"$config/hosts"
out=$("$BASH" "$root/scripts/policy.sh")
[ "$out" = "claude-workhorses: the hosts file is not usable, so wh cannot run: claude-workhorses: $config/hosts line 1: profile \"spare\" for gamma is not dedicated or shared" ] ||
  fail "a bad hosts file: got '$out'"
echo "ok   with a bad hosts file, one line names the problem"

printf '%s\n' "gamma gamma@gamma-mini.example.test x86_64 6 16 dedicated Turquoise Green" "alpha ws-alpha arm64 10 24 shared -" >"$config/hosts"
out=$("$BASH" "$root/scripts/policy.sh")
table=$(grep '^|' <<<"$out")
[ "$table" = "| Host | ssh | Arch | Cores | RAM | Profile |
|------|-----|------|-------|-----|---------|
| gamma | gamma@gamma-mini.example.test | x86_64 | 6 | 16 GB | dedicated |
| alpha | ws-alpha | arm64 | 10 | 24 GB | shared |" ] || fail "the host table: got '$table'"
echo "ok   the host table lists every host in file order"

grep -qF "\`bash $root/provision/sync.sh\`" <<<"$out" || fail "the policy does not name $root/provision/sync.sh"
grep -qF "$root/scripts/mirror.sh run" <<<"$out" || fail "the policy does not name $root/scripts/mirror.sh"
! grep -q '@[A-Z]*@' <<<"$out" || fail "a placeholder is left: $(grep '@[A-Z]*@' <<<"$out")"
echo "ok   the policy names this install's sync.sh and mirror.sh and leaves no placeholder"

echo "all policy checks passed"
