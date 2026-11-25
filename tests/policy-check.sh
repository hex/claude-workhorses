#!/bin/bash
# ABOUTME: Checks what the session-start hook, scripts/policy.sh, tells Claude for a good, a missing and a bad hosts file.
# ABOUTME: Usage: tests/policy-check.sh; no host is contacted; exits 1 on the first wrong answer.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
root=$(cd "$here/.." && pwd -P)
config=$(mktemp -d "${TMPDIR:-/tmp}/policy-check.XXXX")
trap 'rm -rf "$config"' EXIT
export CLAUDE_WORKHORSES_CONFIG_DIR=$config
state=$config/state
export CLAUDE_WORKHORSES_STATE_DIR=$state

fail() { echo "FAIL $*" >&2; exit 1; }

out=$("$BASH" "$root/scripts/policy.sh")
[ "$out" = "claude-workhorses: no workhorses are configured (no hosts file at $config/hosts), so wh cannot run; the plugin's README shows how to add one." ] ||
  fail "a missing hosts file: got '$out'"
echo "ok   with no hosts file, one line says so"

printf '%s\n' "gamma g x86_64 6 16 dock dock" >"$config/hosts"
out=$("$BASH" "$root/scripts/policy.sh")
[ "$out" = "claude-workhorses: the hosts file is not usable, so wh cannot run: claude-workhorses: $config/hosts line 1: option \"dock\" for gamma is given twice" ] ||
  fail "a bad hosts file: got '$out'"
echo "ok   with a bad hosts file, one line names the problem"

printf '%s\n' "gamma gamma@gamma-mini.example.test x86_64 6 16 no-sleep wallpaper=Teal" "alpha ws-alpha arm64 10 24" >"$config/hosts"
out=$("$BASH" "$root/scripts/policy.sh")
table=$(grep '^|' <<<"$out")
[ "$table" = "| Host | ssh | Arch | Cores | RAM |
|------|-----|------|-------|-----|
| gamma | gamma@gamma-mini.example.test | x86_64 | 6 | 16 GB |
| alpha | ws-alpha | arm64 | 10 | 24 GB |" ] || fail "the host table: got '$table'"
echo "ok   the host table lists every host in file order"

grep -qF "\`bash $root/provision/sync.sh\`" <<<"$out" || fail "the policy does not name $root/provision/sync.sh"
grep -qF "$root/scripts/mirror.sh run" <<<"$out" || fail "the policy does not name $root/scripts/mirror.sh"
! grep -q '@[A-Z]*@' <<<"$out" || fail "a placeholder is left: $(grep '@[A-Z]*@' <<<"$out")"
echo "ok   the policy names this install's sync.sh and mirror.sh and leaves no placeholder"

grep -qxF "The tools file lists nothing yet, so the workhorses have only what macOS and their owners put there; the workhorse skill shows how to add a tool." <<<"$out" ||
  fail "with no tools file and no records, the policy does not say the tools file is empty"
echo "ok   with no tools file and no records, one line says so"

# The tools section, from stored manifests. alpha and beta have records; gamma has none.
mkdir -p "$state/manifests" "$config/bin"
# The hook must never reach a host: an ssh that records its calls stands first on PATH.
printf '#!/bin/sh\necho "ssh $*" >>"%s/ssh-calls"\nexit 1\n' "$config" >"$config/bin/ssh"
chmod +x "$config/bin/ssh"
printf '%s\n' "alpha a x86_64 6 16" "beta b x86_64 6 16" "gamma g arm64 10 16" >"$config/hosts"
printf '%s\n' "port cmake" "npm pnpm" "unity 6000 abc @arch=x86_64" >"$config/tools"
printf '%s\n' "#synced 2026-11-20 10:00 UTC" "#exit 0" "#base" "arch x86_64" "macos 15.5" \
  "#line port cmake" "port cmake @3.31" "#line npm pnpm" "npm pnpm@9.1" \
  "#line unity 6000 abc" "unity-cli 1.0" "unity-hub 4.0" "#option no-sleep" "pmset sleep 0" >"$state/manifests/alpha"
long=$(printf 'x%.0s' $(seq 200))
printf '%s\n' "#synced 2026-11-21 10:00 UTC" "#exit 3 port" "#base" "arch x86_64" "macos 15.5" \
  "#line port cmake" "port cmake @3.31" "#line npm pnpm" "npm pnpm@9.2" 'npm evil$(rm -rf ~)<b>`x`' "npm $long" >"$state/manifests/beta"

out=$(PATH="$config/bin:$PATH" "$BASH" "$root/scripts/policy.sh")
tools=$(sed -n '/^Tools on the workhorses/,/^The tools file has changed/p' <<<"$out")
[ "$tools" = "Tools on the workhorses, as each host's last sync recorded them (\`bash $root/provision/sync.sh status\` stores the record):

On every host with a record:
- port cmake @3.31

alpha (macOS 15.5, synced 2026-11-20 10:00 UTC) also has:
- npm pnpm@9.1
- unity-cli 1.0
- unity-hub 4.0

beta (macOS 15.5, synced 2026-11-21 10:00 UTC, stopped at port with exit 3) also has:
- npm evil(rm -rf )bx
- npm pnpm@9.2
- npm $(printf 'x%.0s' $(seq 96))

gamma has no record: it was never synced, or \`bash $root/provision/sync.sh status gamma\` has not stored its last run.
The tools file has changed since the last sync of beta: \`bash $root/provision/sync.sh beta\` brings it level." ] ||
  fail "the tools section: got '$tools'"
[ ! -e "$config/ssh-calls" ] || fail "the policy ran ssh: $(cat "$config/ssh-calls")"
echo "ok   the tools section lists common tools once, then each host's own, filtered, with dates; names hosts with no record and stale ones; runs no ssh"

printf '%s\n' "Unity on the hosts has no license; the editor exits 198." "Signing: none." >"$config/notes"
out=$("$BASH" "$root/scripts/policy.sh")
[ "$(sed -n '/^From the user.s notes file/,$p' <<<"$out")" = "From the user's notes file, $config/notes:

Unity on the hosts has no license; the editor exits 198.
Signing: none." ] || fail "the notes: got '$(sed -n '/^From the user.s notes file/,$p' <<<"$out")'"
echo "ok   the user's notes file is appended as written"

rm "$state/manifests/beta"
printf '%s\n' "#synced 2026-11-20 10:00 UTC" "#exit 0" "#base" "macos 15.5" "#line port many" >"$state/manifests/alpha"
for n in $(seq 25); do echo "port tool$n 1.$n"; done >>"$state/manifests/alpha"
printf '%s\n' "port many" >"$config/tools"
out=$("$BASH" "$root/scripts/policy.sh")
listed=$(sed -n '/^alpha (/,/^$/p' <<<"$out")
[ "$(head -n 1 <<<"$listed")" = "alpha (macOS 15.5, synced 2026-11-20 10:00 UTC) has:" ] || fail "a lone record's heading: '$(head -n 1 <<<"$listed")'"
[ "$(grep -c '^- port tool' <<<"$listed")" = 20 ] || fail "a host's list is not cut at 20 lines: '$listed'"
grep -qx -- '- and 5 more' <<<"$listed" || fail "a cut list does not say how many it left out: '$listed'"
echo "ok   a host's list stops at 20 lines and counts the rest"

printf 'port -rf\n' >"$config/tools"
out=$("$BASH" "$root/scripts/policy.sh")
grep -qxF "The tools file is not usable, so the tools section is left out: claude-workhorses: $config/tools line 1: argument \"-rf\" for port is not letters, digits and @._/+- (and does not start with -)" <<<"$out" ||
  fail "a bad tools file: got '$out'"
echo "ok   a bad tools file is named in one line"

echo "all policy checks passed"
