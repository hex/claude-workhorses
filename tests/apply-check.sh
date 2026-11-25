#!/bin/bash
# ABOUTME: Checks a sync without a workhorse: what sync.sh stages for a host, how apply.sh runs it (here, with HOME in a
# ABOUTME: throwaway folder and a stand-in sudo), and that sync.sh checks everything before it contacts a host. Exits 1 on the first miss.
# The recipes this writes are sh scripts held as text: their $ signs are theirs, not this script's.
# shellcheck disable=SC2016
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
root=$(cd "$here/.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/apply-check.XXXX")
trap 'rm -rf "$scratch"' EXIT
config=$scratch/config
export CLAUDE_WORKHORSES_CONFIG_DIR=$config CLAUDE_WORKHORSES_STATE_DIR=$scratch/state
mkdir -p "$config/recipes" "$scratch/home" "$scratch/bin"
chmod 700 "$config" "$config/recipes"

fail() { echo "FAIL $*" >&2; exit 1; }

# Stand-ins that record their calls: sudo (which apply.sh asks to check the password), ssh and rsync.
cat >"$scratch/bin/sudo" <<'SH'
#!/bin/sh
echo "sudo $*" >>"$HOME/calls"
SH
printf '#!/bin/sh\necho "rsync $*" >>"%s/calls"\n[ -f "%s/answers/copy-works" ]\n' "$scratch" "$scratch" >"$scratch/bin/rsync"
# The ssh stand-in answers from $scratch/answers/<target>.<status|manifest> when that file exists.
export APPLY_CHECK_SCRATCH=$scratch
cat >"$scratch/bin/ssh" <<'SH'
#!/bin/bash
echo "ssh LC_SUDO_PW=${LC_SUDO_PW:-unset} $*" >>"$APPLY_CHECK_SCRATCH/calls"
# The target is the first word that is no option and no option's value.
target=""
for word in "$@"; do
  case "$word" in
    (-o | BatchMode=* | ConnectTimeout=* | SendEnv=*) ;;
    (*) target=$word; break ;;
  esac
done
case "$*" in
  (*run.status*) answer=$APPLY_CHECK_SCRATCH/answers/$target.status ;;
  (*manifest*) answer=$APPLY_CHECK_SCRATCH/answers/$target.manifest ;;
  (*mkdir*) [ -f "$APPLY_CHECK_SCRATCH/answers/lock-free" ]; exit ;;
  (*nohup*) exit 0 ;;
  (*) exit 1 ;;
esac
[ -f "$answer" ] && cat "$answer"
SH
chmod +x "$scratch/bin/"*

# User recipes: each logs its argv and whether it sees the sudo password and askpass helper.
recipe() {
  printf '#!/bin/bash\n%s\n. "$(dirname "$0")/../recipe-lib.sh"\n[ "$1" = install ] || { echo "$(basename "$0") probe-says $*"; exit 0; }\nshift\necho "$(basename "$0") args=$(printf "[%%s]" "$@") pw=${SUDO_PW:-unset} askpass=${SUDO_ASKPASS:-unset} plain=${PLAIN_TOOL:-unset}" >>"$HOME/calls"\n%s\n' "$2" "$3" >"$config/recipes/$1"
  chmod 700 "$config/recipes/$1"
}
recipe plain "" "env_snippet plain <<<'export PLAIN_TOOL=1'"
recipe rooted "# needs: sudo" ""
recipe broken "" "exit 5"
recipe after "" ""
# Recipes that misbehave as installers can: one reads stdin, one leaves a snippet that reads an unset variable.
recipe slurp "" "cat >/dev/null"
printf '#!/bin/bash\n[ "$1" = install ] || { cat >/dev/null; echo "slurp-probe read"; exit 0; }\ncat >/dev/null\n' >"$config/recipes/slurp"
recipe loose "" "env_snippet loose <<<'LOOSE_TOOL=\${LOOSE_UNSET_VARIABLE}x'"
printf '#!/bin/sh\necho pw\n' >"$config/sudo-password"
chmod 700 "$config/sudo-password"

printf '%s\n' "alpha a x86_64 6 16" "beta b x86_64 6 16 no-sleep wallpaper=Teal" "gamma g arm64 10 16" >"$config/hosts"
printf '%s\n' "plain @scope/pkg a.b+c" "rooted x" "broken" "after" "plain only-arm @arch=arm64" >"$config/tools"

# shellcheck source=../provision/sync.sh
. "$root/provision/sync.sh"
load_hosts
load_tools

stage=$scratch/stage-alpha
mkdir "$stage"
stage_host alpha "$stage"
[ "$(cd "$stage" && find . -type f | LC_ALL=C sort | tr '\n' ' ')" = "./apply.sh ./askpass-env ./clt-direct.sh ./env.sh ./manifest.sh ./options ./options.sh ./recipe-lib.sh ./recipes/after ./recipes/broken ./recipes/plain ./recipes/rooted ./tools " ] ||
  fail "alpha's stage holds: $(cd "$stage" && find . -type f | LC_ALL=C sort | tr '\n' ' ')"
echo "ok   a stage holds the host scripts and only the recipes the host's lines name; never the hosts file or the sudo helper"
[ "$(cat "$stage/tools")" = "plain @scope/pkg a.b+c
rooted x
broken
after" ] || fail "alpha's tools file: '$(cat "$stage/tools")'"
[ ! -s "$stage/options" ] || fail "alpha has no options, but its options file holds '$(cat "$stage/options")'"
echo "ok   the staged tools file holds the host's lines without filters; a host with no options gets an empty options file"

mkdir "$scratch/stage-beta"
stage_host beta "$scratch/stage-beta"
[ "$(cat "$scratch/stage-beta/options")" = "no-sleep sudo
wallpaper=Teal" ] || fail "beta's options file: '$(cat "$scratch/stage-beta/options")'"
echo "ok   the staged options mark the ones that need sudo"

# Runs the staged files as apply.sh does on a host, with the sudo password $1 (empty: none).
apply() {
  rm -rf "$scratch/home/workhorse"
  cp -R "$stage" "$scratch/home/workhorse"
  mkdir "$scratch/home/workhorse.lock"
  : >"$scratch/home/calls"
  code=0
  HOME=$scratch/home SUDO_PW=$1 PATH="$scratch/bin:$PATH" /bin/bash "$scratch/home/workhorse/apply.sh" >"$scratch/apply.log" 2>&1 || code=$?
}

printf 'export FOO=1' >"$scratch/home/.zshenv"
apply pw
[ "$code" = 5 ] || fail "apply.sh exited $code, not the failing recipe's 5"
[ "$(cat "$scratch/home/workhorse/run.status")" = "5 broken" ] || fail "run.status: '$(cat "$scratch/home/workhorse/run.status")'"
[ ! -e "$scratch/home/workhorse.lock" ] || fail "apply.sh left the lock"
echo "ok   the run stops at the first failing recipe, records its exit code and name, and frees the lock"

[ "$(cat "$scratch/home/calls")" = "sudo -A -v
plain args=[@scope/pkg][a.b+c] pw=unset askpass=unset plain=unset
rooted args=[x] pw=pw askpass=$scratch/home/.local/bin/askpass-env plain=1
broken args=[] pw=unset askpass=unset plain=1" ] ||
  fail "the steps ran as: '$(cat "$scratch/home/calls")'"
grep -q '^after' "$scratch/home/calls" && fail "the recipe after the failing one ran"
echo "ok   arguments arrive as argv; only a recipe that declares sudo sees the password; a snippet reaches the steps after it"

manifest=$scratch/home/workhorse/manifest
grep -qx '#exit 5 broken' "$manifest" || fail "the manifest has no '#exit 5 broken': $(cat "$manifest")"
grep -q '^#synced [0-9-]* [0-9:]* UTC$' "$manifest" || fail "the manifest has no #synced date: $(cat "$manifest")"
[ "$(sed -n '/^#line plain @scope\/pkg a.b+c$/,/^#/p' "$manifest" | sed -n 2p)" = "plain probe-says probe @scope/pkg a.b+c" ] ||
  fail "the manifest's plain block: $(cat "$manifest")"
echo "ok   the manifest records the result and each line's probe"

line='. "$HOME/.local/share/claude-workhorses/env.sh" # claude-workhorses'
[ "$(cat "$scratch/home/.zshenv")" = "export FOO=1
$line" ] || fail ".zshenv after one run: '$(cat "$scratch/home/.zshenv")'"
printf '%s\n' "plain @scope/pkg a.b+c" >"$stage/tools"
apply ""
[ "$code" = 0 ] || fail "a run of one plain recipe exited $code"
[ "$(cat "$scratch/home/workhorse/run.status")" = 0 ] || fail "run.status after a clean run: '$(cat "$scratch/home/workhorse/run.status")'"
[ "$(cat "$scratch/home/.zshenv")" = "export FOO=1
$line" ] || fail ".zshenv after two runs: '$(cat "$scratch/home/.zshenv")'"
grep -q '^sudo' "$scratch/home/calls" && fail "a run with no password called sudo"
echo "ok   ~/.zshenv keeps its own lines and gets the source line once, on a new line; a run with no password never calls sudo"

printf '%s\n' "slurp" "loose" "after" >"$stage/tools"
cp "$config/recipes/slurp" "$config/recipes/loose" "$config/recipes/after" "$stage/recipes/"
apply ""
[ "$code" = 0 ] || fail "a run with a recipe that reads stdin and one with a loose snippet exited $code: $(tail -3 "$scratch/apply.log")"
grep -q '^after' "$scratch/home/calls" || fail "a recipe that read stdin swallowed the lines after it"
for block in slurp loose after; do
  grep -qx "#line $block" "$scratch/home/workhorse/manifest" || fail "the manifest lacks the $block block: $(cat "$scratch/home/workhorse/manifest")"
done
apply ""
[ "$code" = 0 ] || fail "the run after a loose snippet exited $code: $(tail -3 "$scratch/apply.log")"
echo "ok   a recipe that reads stdin cannot eat the lines after it, and a snippet written without set -u in mind breaks no run"

rm -f "$scratch/home/.zshenv"
apply ""
[ "$(cat "$scratch/home/.zshenv")" = "$line" ] || fail ".zshenv from nothing: '$(cat "$scratch/home/.zshenv")'"
echo "ok   a missing ~/.zshenv is created with the one line"

# Runs sync.sh in a fresh bash with the stand-ins first on PATH and compares its stderr and exit code.
expect_sync() {
  local label=$1 want=$2 want_exit=$3 out code=0
  shift 3
  : >"$scratch/calls"
  out=$(PATH="$scratch/bin:$PATH" "$BASH" "$root/provision/sync.sh" "$@" 2>&1) || code=$?
  [ "$out" = "$want" ] && [ "$code" = "$want_exit" ] || fail "$label: wanted '$want' exit $want_exit, got '$out' exit $code"
}

printf '%s\n' "plain ok" "port -rf" >"$config/tools"
expect_sync "a bad tools line" "claude-workhorses: $config/tools line 2: argument \"-rf\" for port is not letters, digits and @._/+- (and does not start with -)" 1 alpha
[ ! -s "$scratch/calls" ] || fail "sync.sh contacted a host before refusing a bad tools file: $(cat "$scratch/calls")"
printf '%s\n' "plain ok" >"$config/tools"
expect_sync "an unknown host" "unknown workhorse \"delta\"; known: alpha beta gamma" 1 alpha delta
[ ! -s "$scratch/calls" ] || fail "sync.sh contacted a host before refusing an unknown one: $(cat "$scratch/calls")"
echo "ok   a bad tools line or host name stops sync.sh before it contacts any host"

printf '%s\n' "plain ok" >"$config/tools"
rm "$config/sudo-password"
expect_sync "a host that needs sudo without a helper" "claude-workhorses: no executable sudo-password helper at $config/sudo-password
beta: no sudo password; nothing was run" 1 beta
[ ! -s "$scratch/calls" ] || fail "sync.sh contacted beta with no password: $(cat "$scratch/calls")"
expect_sync "a host that needs no sudo" "alpha: a sync is already running (~/workhorse.lock exists)" 1 alpha
[ "$(cat "$scratch/calls")" = "ssh LC_SUDO_PW=unset -o BatchMode=yes -o ConnectTimeout=10 a mkdir ~/workhorse.lock" ] ||
  fail "sync.sh's calls for alpha: $(cat "$scratch/calls")"
echo "ok   a host whose lines and options need no sudo syncs without a sudo-password helper"

mkdir "$scratch/answers"
touch "$scratch/answers/lock-free" "$scratch/answers/copy-works"
printf '#!/bin/sh\necho secret-pw-123\n' >"$config/sudo-password"
chmod 700 "$config/sudo-password"
expect_sync "a sync that starts" "beta: sync started; check with: $root/provision/sync.sh status beta" 0 beta
grep -q 'secret-pw-123' "$scratch/calls" || fail "the run never received the password: $(cat "$scratch/calls")"
while IFS= read -r call; do
  # The stand-in logs the environment variable first; what follows it is the command line.
  args=${call#ssh LC_SUDO_PW=* }
  case "$args" in (*secret-pw-123*) fail "the password is in a command line: $call" ;; esac
done <"$scratch/calls"
grep -q '^ssh LC_SUDO_PW=secret-pw-123 .*SendEnv=LC_SUDO_PW' "$scratch/calls" || fail "the password does not reach the run that starts apply.sh: $(cat "$scratch/calls")"
[ "$(grep -c 'LC_SUDO_PW=secret-pw-123' "$scratch/calls")" = 1 ] || fail "the password reaches more than the one ssh that starts the run: $(cat "$scratch/calls")"
rm "$scratch/answers/lock-free" "$scratch/answers/copy-works"
echo "ok   a started sync sends the password only in the environment of the ssh that starts apply.sh, never in a command line"
printf '%s\n' "ended 5 broken" "=== broken" >"$scratch/answers/a.status"
printf '%s\n' "#synced 2026-01-02 03:04 UTC" "#exit 5 broken" "#line plain ok" "plain v1" >"$scratch/answers/a.manifest"
expect_sync "status of a host whose run ended" "=== alpha
exit=5, stopped at broken
=== broken
manifest stored: $scratch/state/manifests/alpha" 0 status alpha
cmp -s "$scratch/answers/a.manifest" "$scratch/state/manifests/alpha" || fail "the stored manifest differs from the host's"
printf '%s\n' "running" >"$scratch/answers/b.status"
expect_sync "status of a host still running" "=== beta
running" 0 status beta
[ ! -e "$scratch/state/manifests/beta" ] || fail "status stored a manifest for a run still going"
echo "ok   status names where a run stopped and stores the manifest of a run that ended, and only then"

printf '%s\n' "plain ok" "plain only-arm @arch=arm64" >"$config/tools"
printf '%s\n' "#base" "arch x86_64" "#line plain ok" "plain v1" >"$scratch/answers/a.manifest"
printf '%s\n' "#base" "arch x86_64" "#line plain ok" "plain v1" "#line plain only-arm" "plain stale" >"$scratch/answers/b.manifest"
printf '%s\n' "#base" "arch arm64" "#line plain ok" "plain v1" "#line plain only-arm" "plain arm1" >"$scratch/answers/g.manifest"
expect_sync "hosts that match on every line they get" "all workhorses match (2 tools lines)" 0 diff
printf '%s\n' "#base" "arch x86_64" "#line plain ok" "plain v2" >"$scratch/answers/b.manifest"
rm "$scratch/answers/g.manifest"
expect_sync "a host that differs, and one that does not answer" "gamma: unreachable, not compared
--- alpha: plain ok
+++ beta: plain ok
@@ -1 +1 @@
-plain v1
+plain v2" 1 diff
printf '%s\n' "#base" "arch arm64" "#line plain ok" "plain v1" >"$scratch/answers/g.manifest"
printf '%s\n' "#base" "arch x86_64" "#line plain ok" "plain v1" >"$scratch/answers/b.manifest"
expect_sync "a host that lacks a line it gets" "gamma: not synced with \"plain only-arm\"" 1 diff
echo "ok   diff compares each tools line only among the hosts it targets, and names a host that lacks one"

echo "all sync and apply checks passed"
