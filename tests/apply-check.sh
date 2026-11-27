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
export WORKHORSES_CONFIG_DIR=$config WORKHORSES_STATE_DIR=$scratch/state
mkdir -p "$config/recipes" "$scratch/home" "$scratch/bin" "$scratch/hosts/a" "$scratch/hosts/b" "$scratch/hosts/g"
chmod 700 "$config" "$config/recipes"

fail() { echo "FAIL $*" >&2; exit 1; }

# Stand-ins that record their calls: sudo (which apply.sh asks to check the password), ssh and rsync.
cat >"$scratch/bin/sudo" <<'SH'
#!/bin/sh
echo "sudo $*" >>"$HOME/calls"
SH
# rsync waits while answers/copy-blocks exists, so a check can signal sync.sh mid-copy.
printf '#!/bin/sh\necho "rsync $*" >>"%s/calls"\nwhile [ -f "%s/answers/copy-blocks" ]; do sleep 0.1; done\n[ -f "%s/answers/copy-works" ]\n' "$scratch" "$scratch" "$scratch" >"$scratch/bin/rsync"
# apply.sh and manifest.sh ask uname which OS they run on; this one says Darwin unless
# APPLY_CHECK_UNAME names another, so the checks below run the same on a Mac and on Linux.
printf '#!/bin/sh\n[ "$1" = -s ] || exec /usr/bin/uname "$@"\necho "${APPLY_CHECK_UNAME:-Darwin}"\n' >"$scratch/bin/uname"
# The ssh stand-in answers from $scratch/answers/<target>.manifest when that file exists, and runs the
# host script sync.sh sends on stdin, and an rmdir, against $scratch/hosts/<target>, that host's HOME, with
# APPLY_CHECK_HOST_BASH (default macOS's /bin/bash) as its bash.
export APPLY_CHECK_SCRATCH=$scratch
cat >"$scratch/bin/ssh" <<'SH'
#!/bin/bash
# A password in any variable of ssh's environment is marked, so the checks below see it.
if env | grep -q secret-pw-123; then echo "ssh PASSWORD-IN-ENV $*"; else echo "ssh $*"; fi >>"$APPLY_CHECK_SCRATCH/calls"
# The target is the first word that is no option and no option's value.
target=""
for word in "$@"; do
  case "$word" in
    (-o | BatchMode=* | ConnectTimeout=*) ;;
    (*) target=$word; break ;;
  esac
done
answers=$APPLY_CHECK_SCRATCH/answers
# A target with an answers/<target>.unreachable file is down: ssh itself exits 255.
[ ! -f "$answers/$target.unreachable" ] || exit 255
case "$*" in
  (*apply.sh*) IFS= read -r line; echo "stdin $line" >>"$APPLY_CHECK_SCRATCH/calls"; [ -f "$answers/start-works" ]; exit ;;
  (*"bash -s"*) command=${*: -1}; HOME=$APPLY_CHECK_SCRATCH/hosts/$target exec "${APPLY_CHECK_HOST_BASH:-/bin/bash}" -s -- "${command##* }" ;;
  (*"uname -s"*) if [ -f "$answers/$target.os" ]; then cat "$answers/$target.os"; else echo Darwin; fi; exit ;;
  (*rmdir*) HOME=$APPLY_CHECK_SCRATCH/hosts/$target exec /bin/bash -c "${*: -1}" ;;
  (*manifest*)
    # Only diff's command names the lock: it marks a host whose lock is there.
    case "$*" in (*workhorse.lock*) [ ! -d "$APPLY_CHECK_SCRATCH/hosts/$target/workhorse.lock" ] || echo "#sync-lock" ;; esac
    answer=$answers/$target.manifest ;;
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
[ "$(cd "$stage" && find . -type f | LC_ALL=C sort | tr '\n' ' ')" = "./apply.sh ./askpass-env ./clt-direct.sh ./env.sh ./manifest.sh ./options ./options.sh ./recipe-lib.sh ./recipes/after ./recipes/broken ./recipes/plain ./recipes/rooted ./sync-state.sh ./tools " ] ||
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

# gamma runs Linux: sync.sh learns that from the host before it stages anything.
printf '%s\n' "apt git curl @os=linux" "plain mac-only @os=macos" "after" >"$config/tools"
load_tools
host_os=(macos macos linux)
mkdir "$scratch/stage-gamma"
stage_host gamma "$scratch/stage-gamma"
[ "$(cd "$scratch/stage-gamma/recipes" && ls | tr '\n' ' ')" = "after apt " ] ||
  fail "gamma's stage holds the recipes: $(cd "$scratch/stage-gamma/recipes" && ls | tr '\n' ' ')"
[ "$(cat "$scratch/stage-gamma/tools")" = "apt git curl
after" ] || fail "gamma's tools file: '$(cat "$scratch/stage-gamma/tools")'"
mkdir "$scratch/stage-alpha-os"
stage_host alpha "$scratch/stage-alpha-os"
[ "$(cat "$scratch/stage-alpha-os/tools")" = "plain mac-only
after" ] || fail "alpha's tools file with @os lines: '$(cat "$scratch/stage-alpha-os/tools")'"
echo "ok   a Linux host gets the apt line and the lines without @os; a Mac gets its @os=macos line and not the apt one"
host_os=()
printf '%s\n' "plain @scope/pkg a.b+c" "rooted x" "broken" "after" "plain only-arm @arch=arm64" >"$config/tools"
load_tools

# Runs the staged files as sync.sh does on a host: "apply.sh start" with the sudo password $1 (empty:
# none) on stdin, then waits for the detached run to free the lock. Sets code to the run's exit code.
apply() {
  local waited=0
  rm -rf "$scratch/home/workhorse"
  cp -R "$stage" "$scratch/home/workhorse"
  mkdir "$scratch/home/workhorse.lock"
  : >"$scratch/home/calls"
  printf '%s\n' "$1" | HOME=$scratch/home PATH="$scratch/bin:$PATH" /bin/bash "$scratch/home/workhorse/apply.sh" start >"$scratch/apply.log" 2>&1 ||
    fail "apply.sh start failed: $(cat "$scratch/apply.log")"
  while [ -d "$scratch/home/workhorse.lock" ]; do
    [ $waited -lt 300 ] || fail "the run kept its lock for 30 s: $(cat "$scratch/home/workhorse/run.log")"
    sleep 0.1
    waited=$((waited + 1))
  done
  cp "$scratch/home/workhorse/run.log" "$scratch/apply.log"
  code=$(cut -d ' ' -f 1 "$scratch/home/workhorse/run.status")
}

printf 'export FOO=1' >"$scratch/home/.zshenv"
# Any process on a host can write an env snippet; this one records every variable and every open
# descriptor above stderr that it can see while env.sh loads it.
mkdir -p "$scratch/home/.local/share/workhorses/env.d"
cat >"$scratch/home/.local/share/workhorses/env.d/zz-planted.sh" <<'SH'
{ set; env; } >>"$HOME/leak" 2>/dev/null
for fd in 3 4 5 6 7 8 9; do { true <&"$fd"; } 2>/dev/null && echo "descriptor $fd is open" >>"$HOME/leak"; done
SH
apply s3cret-apply-pw
grep -q 's3cret-apply-pw' "$scratch/home/leak" && fail "an env snippet saw the sudo password: $(grep 's3cret-apply-pw' "$scratch/home/leak")"
grep -q '^descriptor' "$scratch/home/leak" && fail "an env snippet ran with an open descriptor: $(grep '^descriptor' "$scratch/home/leak" | sort -u)"
[ -s "$scratch/home/leak" ] || fail "the planted env snippet never ran"
echo "ok   an env snippet sees neither the sudo password nor any descriptor that could carry it"
[ "$code" = 5 ] || fail "apply.sh exited $code, not the failing recipe's 5"
[ "$(cat "$scratch/home/workhorse/run.status")" = "5 broken" ] || fail "run.status: '$(cat "$scratch/home/workhorse/run.status")'"
[ ! -e "$scratch/home/workhorse.lock" ] || fail "apply.sh left the lock"
echo "ok   the run stops at the first failing recipe, records its exit code and name, and frees the lock"

[ "$(cat "$scratch/home/calls")" = "sudo -A -v
plain args=[@scope/pkg][a.b+c] pw=unset askpass=unset plain=unset
rooted args=[x] pw=s3cret-apply-pw askpass=$scratch/home/.local/bin/askpass-env plain=1
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

line='. "$HOME/.local/share/workhorses/env.sh" # workhorses'
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

# An install can exit 0 and leave its tool unusable: an earlier run cut short left a folder the
# installer takes for a finished install. The step fails when its probe still reports the tool missing.
printf '#!/bin/bash\n[ "$1" = install ] || { echo "hollow-tool missing"; echo "hollow-other 1.0"; }\n' >"$stage/recipes/hollow"
chmod 700 "$stage/recipes/hollow"
printf '%s\n' "hollow" "after" >"$stage/tools"
apply ""
[ "$(cat "$scratch/home/workhorse/run.status")" = "1 hollow" ] || fail "a hollow install gave run.status '$(cat "$scratch/home/workhorse/run.status")'"
grep -qxF "hollow: the install ended, but its probe reports: hollow-tool missing" "$scratch/apply.log" ||
  fail "a hollow install is not named: $(tail -3 "$scratch/apply.log")"
grep -q '^after' "$scratch/home/calls" && fail "the recipe after a hollow install ran"
grep -qx 'hollow-tool missing' "$scratch/home/workhorse/manifest" || fail "the manifest lacks the hollow probe: $(cat "$scratch/home/workhorse/manifest")"
# A probe that exits non-zero fails its step whatever it printed, so run.status and the manifest agree.
printf '#!/bin/bash\n[ "$1" = install ] || { echo "crashing 1.0"; exit 127; }\n' >"$stage/recipes/crashing"
chmod 700 "$stage/recipes/crashing"
printf '%s\n' "crashing" "after" >"$stage/tools"
apply ""
[ "$(cat "$scratch/home/workhorse/run.status")" = "1 crashing" ] || fail "a probe that exits 127 gave run.status '$(cat "$scratch/home/workhorse/run.status")'"
grep -qxF "crashing: the install ended, but its probe failed with exit 127" "$scratch/apply.log" ||
  fail "a probe that exits 127 is not named: $(tail -3 "$scratch/apply.log")"
grep -q '^after' "$scratch/home/calls" && fail "the recipe after a failed probe ran"
[ "$(grep -xE '#exit .*|crashing .*' "$scratch/home/workhorse/manifest")" = "#exit 1 crashing
crashing probe-failed 127
crashing 1.0" ] || fail "the manifest of a failed probe: $(cat "$scratch/home/workhorse/manifest")"
printf '%s\n' "slurp" "loose" "after" >"$stage/tools"
echo "ok   an install that exits 0 while its probe still reports the tool missing, or exits non-zero, fails its step, named, and the steps after it do not run"

rm -f "$scratch/home/.zshenv"
apply ""
[ "$(cat "$scratch/home/.zshenv")" = "$line" ] || fail ".zshenv from nothing: '$(cat "$scratch/home/.zshenv")'"
echo "ok   a missing ~/.zshenv is created with the one line"

printf 'exit 3\n' >"$scratch/home/.local/share/workhorses/env.d/zz-exit.sh"
apply ""
rm "$scratch/home/.local/share/workhorses/env.d/zz-exit.sh"
[ "$(cat "$scratch/home/workhorse/run.status")" = "1 env" ] || fail "a snippet that exits gave run.status '$(cat "$scratch/home/workhorse/run.status")'"
grep -qxF "env.sh stopped before its end: a snippet in $scratch/home/.local/share/workhorses/env.d exits or fails, and the steps would miss what it sets" "$scratch/apply.log" ||
  fail "a snippet that exits is not named: $(cat "$scratch/apply.log")"
echo "ok   a snippet that ends env.sh early stops the run at the env step"

# start must leave nothing holding the ssh session open: $(...) returns only when every writer to its
# pipe is gone, so the lock still being there afterwards shows the run went on without it.
recipe nap "" "sleep 3"
cp "$config/recipes/nap" "$stage/recipes/"
printf '%s\n' nap >"$stage/tools"
rm -rf "$scratch/home/workhorse"
cp -R "$stage" "$scratch/home/workhorse"
mkdir "$scratch/home/workhorse.lock"
out=$(printf '\n' | HOME=$scratch/home PATH="$scratch/bin:$PATH" /bin/bash "$scratch/home/workhorse/apply.sh" start 2>&1)
[ -e "$scratch/home/workhorse.lock/started" ] || fail "apply.sh start returned only after the run ended: '$out'"
for _ in $(seq 100); do [ -d "$scratch/home/workhorse.lock" ] || break; sleep 0.1; done
[ ! -d "$scratch/home/workhorse.lock" ] || fail "the detached run kept its lock for 10 s"
[ "$(cat "$scratch/home/workhorse/run.status")" = 0 ] || fail "the detached run ended with '$(cat "$scratch/home/workhorse/run.status")'"
echo "ok   apply.sh start returns at once, with the run going on detached"

# On Linux, sshd starts bash for a command, and bash reads ~/.bashrc, whose stock first lines return
# from a shell that is not interactive: the source line goes above them, once.
printf '%s\n' plain >"$stage/tools"
cp "$config/recipes/plain" "$stage/recipes/"
rm -f "$scratch/home/.zshenv"
printf '%s\n' '# ~/.bashrc' 'case $- in *i*) ;; *) return ;; esac' 'alias ll="ls -l"' >"$scratch/home/.bashrc"
for _ in 1 2; do
  APPLY_CHECK_UNAME=Linux SHELL=/bin/bash apply ""
  [ "$code" = 0 ] || fail "a run on Linux exited $code: $(tail -3 "$scratch/apply.log")"
done
[ "$(cat "$scratch/home/.bashrc")" = "$line
# ~/.bashrc
case \$- in *i*) ;; *) return ;; esac
alias ll=\"ls -l\"" ] || fail ".bashrc after two runs on Linux: '$(cat "$scratch/home/.bashrc")'"
[ ! -e "$scratch/home/.zshenv" ] || fail "a run on Linux with bash wrote ~/.zshenv: '$(cat "$scratch/home/.zshenv")'"
grep -qx 'linux .*' "$scratch/home/workhorse/manifest" || fail "the manifest of a Linux run has no linux line: $(cat "$scratch/home/workhorse/manifest")"
grep -q '^macos' "$scratch/home/workhorse/manifest" && fail "the manifest of a Linux run has a macos line: $(cat "$scratch/home/workhorse/manifest")"
echo "ok   on Linux with bash, the source line goes once at the top of ~/.bashrc, above its interactive guard, and the manifest says linux"

rm "$scratch/home/.bashrc"
APPLY_CHECK_UNAME=Linux SHELL=/usr/bin/zsh apply ""
[ "$code" = 0 ] || fail "a run on Linux with zsh exited $code: $(tail -3 "$scratch/apply.log")"
[ "$(cat "$scratch/home/.zshenv")" = "$line" ] || fail ".zshenv on Linux with zsh: '$(cat "$scratch/home/.zshenv" 2>&1)'"
[ ! -e "$scratch/home/.bashrc" ] || fail "a run on Linux with zsh wrote ~/.bashrc"
APPLY_CHECK_UNAME=Linux SHELL=/usr/bin/fish apply ""
[ "$(cat "$scratch/home/workhorse/run.status")" = "1 env" ] || fail "a run on Linux with fish gave run.status '$(cat "$scratch/home/workhorse/run.status")'"
grep -qxF "the login shell is /usr/bin/fish; wh's commands get the recipes' PATH only from bash (~/.bashrc) or zsh (~/.zshenv)" "$scratch/apply.log" ||
  fail "a run on Linux with fish does not name the shell: $(cat "$scratch/apply.log")"
rm -f "$scratch/home/.zshenv"
echo "ok   on Linux with zsh the line goes in ~/.zshenv, and another login shell stops the run at the env step, named"

# Host options run through options.sh; a stand-in records what each one sees instead of changing this Mac.
printf '#!/bin/bash\n[ "$1" = apply ] || { echo "$2 probed"; exit 0; }\necho "option $2 pw=${SUDO_PW:-unset} askpass=${SUDO_ASKPASS:-unset}" >>"$HOME/calls"\n' >"$scratch/stage-beta/options.sh"
: >"$scratch/stage-beta/tools"
alpha_stage=$stage
stage=$scratch/stage-beta
apply s3cret-apply-pw
stage=$alpha_stage
[ "$code" = 0 ] || fail "a run of beta's options exited $code: $(tail -3 "$scratch/apply.log")"
[ "$(cat "$scratch/home/calls")" = "sudo -A -v
option no-sleep pw=s3cret-apply-pw askpass=$scratch/home/.local/bin/askpass-env
option wallpaper=Teal pw=unset askpass=unset" ] || fail "beta's options ran as: '$(cat "$scratch/home/calls")'"
echo "ok   a host option that needs sudo sees the password, and one that does not never does"

# Runs sync.sh in a fresh bash with the stand-ins first on PATH and compares its stderr and exit code.
expect_sync() {
  local label=$1 want=$2 want_exit=$3 out code=0
  shift 3
  : >"$scratch/calls"
  out=$(PATH="$scratch/bin:$PATH" "$BASH" "$root/provision/sync.sh" "$@" 2>&1) || code=$?
  [ "$out" = "$want" ] && [ "$code" = "$want_exit" ] || fail "$label: wanted '$want' exit $want_exit, got '$out' exit $code"
}

printf '%s\n' "plain ok" "port -rf" >"$config/tools"
expect_sync "a bad tools line" "workhorses: $config/tools line 2: argument \"-rf\" for port is not letters, digits and @._/+- (and does not start with -)" 1 alpha
[ ! -s "$scratch/calls" ] || fail "sync.sh contacted a host before refusing a bad tools file: $(cat "$scratch/calls")"
printf '%s\n' "plain ok" >"$config/tools"
expect_sync "an unknown host" "unknown workhorse \"delta\"; known: alpha beta gamma" 1 alpha delta
[ ! -s "$scratch/calls" ] || fail "sync.sh contacted a host before refusing an unknown one: $(cat "$scratch/calls")"
echo "ok   a bad tools line or host name stops sync.sh before it contacts any host"

printf '%s\n' "plain ok" >"$config/tools"
rm "$config/sudo-password"
expect_sync "a host that needs sudo without a helper" "workhorses: no executable sudo-password helper at $config/sudo-password
beta: no sudo password; nothing was run" 1 beta
[ "$(cat "$scratch/calls")" = "ssh -o BatchMode=yes -o ConnectTimeout=10 b uname -s" ] ||
  fail "sync.sh did more than ask beta's OS before it found no password: $(cat "$scratch/calls")"
# alpha and gamma hold the lock of a run an older apply.sh started: its started file names no pid.
for host in a g; do mkdir "$scratch/hosts/$host/workhorse.lock"; : >"$scratch/hosts/$host/workhorse.lock/started"; done
expect_sync "a host that needs no sudo" "alpha: a sync is already running (~/workhorse.lock exists)" 1 alpha
[ "$(cat "$scratch/calls")" = "ssh -o BatchMode=yes -o ConnectTimeout=10 a uname -s
ssh -o BatchMode=yes -o ConnectTimeout=10 a /bin/bash -s -- take" ] ||
  fail "sync.sh's calls for alpha: $(cat "$scratch/calls")"
echo "ok   a host whose lines and options need no sudo syncs without a sudo-password helper"

mkdir -p "$scratch/answers"
printf 'Linux\n' >"$scratch/answers/b.os"
expect_sync "a Linux host with host options" "beta runs Linux, where host options do not apply: remove no-sleep, wallpaper=Teal from its hosts line; nothing was run" 1 beta
[ "$(cat "$scratch/calls")" = "ssh -o BatchMode=yes -o ConnectTimeout=10 b uname -s" ] ||
  fail "sync.sh went past the OS question for a Linux host with options: $(cat "$scratch/calls")"
printf 'SunOS\n' >"$scratch/answers/a.os"
expect_sync "a host that runs neither macOS nor Linux" "alpha: runs \"SunOS\", not macOS or Linux; nothing was run" 1 alpha
rm "$scratch/answers/a.os" "$scratch/answers/b.os"
echo "ok   sync.sh asks each host's OS first, and refuses host options on a Linux host and a host that runs neither, before any lock or password"

# A macOS-only recipe's line that reaches a Linux host stops sync.sh before any password, helper or
# lock, sudo recipe or not; there is no sudo-password helper here. On a Mac the same line goes on.
printf 'Linux\n' >"$scratch/answers/g.os"
for line in "command-line-tools" "macports" "port git" "macos-harness" "unity 6000.3.28f1 8f082d2fe476"; do
  printf '%s\n' "after" "$line" >"$config/tools"
  expect_sync "$line on a Linux host" "gamma: ${line%% *} runs only on macOS: give its line @os=macos; nothing was run" 1 gamma
  [ "$(cat "$scratch/calls")" = "ssh -o BatchMode=yes -o ConnectTimeout=10 g uname -s" ] ||
    fail "sync.sh went past the OS question for $line on a Linux host: $(cat "$scratch/calls")"
done
# The line's own @os=macos keeps it from a Linux host, and that host's sync goes on.
printf '%s\n' "port git @os=macos" >"$config/tools"
expect_sync "a macOS-only line with @os=macos and a Linux host" "gamma: a sync is already running (~/workhorse.lock exists)" 1 gamma
[ "$(cat "$scratch/calls")" = "ssh -o BatchMode=yes -o ConnectTimeout=10 g uname -s
ssh -o BatchMode=yes -o ConnectTimeout=10 g /bin/bash -s -- take" ] ||
  fail "sync.sh's calls for gamma with an @os=macos line: $(cat "$scratch/calls")"
rm "$scratch/answers/g.os"
printf '%s\n' "macos-harness" >"$config/tools"
expect_sync "a macOS-only line on a Mac" "alpha: a sync is already running (~/workhorse.lock exists)" 1 alpha
printf '%s\n' "plain ok" >"$config/tools"
echo "ok   a macOS-only recipe's line on a Linux host stops sync.sh with the @os=macos it lacks, before any password or lock"

mkdir -p "$scratch/answers"
touch "$scratch/answers/copy-works" "$scratch/answers/start-works"
printf '#!/bin/sh\necho secret-pw-123\n' >"$config/sudo-password"
chmod 700 "$config/sudo-password"
expect_sync "a sync that starts" "beta: sync started; check with: $root/provision/sync.sh status beta" 0 beta
grep -q '^ssh .*secret-pw-123' "$scratch/calls" && fail "the password is in an ssh command line: $(grep '^ssh .*secret-pw-123' "$scratch/calls")"
grep -q '^ssh PASSWORD-IN-ENV' "$scratch/calls" && fail "the password is in ssh's environment: $(grep '^ssh PASSWORD-IN-ENV' "$scratch/calls")"
[ "$(grep -B 1 -x 'stdin secret-pw-123' "$scratch/calls")" = "ssh -o BatchMode=yes b /bin/bash ~/workhorse/apply.sh start
stdin secret-pw-123" ] || fail "the password does not reach the ssh that starts apply.sh on its stdin: $(cat "$scratch/calls")"
[ "$(grep -c 'secret-pw-123' "$scratch/calls")" = 1 ] || fail "the password reaches more than the one ssh that starts the run: $(cat "$scratch/calls")"
echo "ok   a started sync sends the password only on the stdin of the ssh that starts apply.sh, never in its environment or a command line"

rmdir "$scratch/hosts/b/workhorse.lock"
rm "$scratch/answers/start-works"
expect_sync "a sync whose start fails" "beta: starting the run failed; nothing ran, and the lock is removed" 1 beta
[ "$(tail -n 1 "$scratch/calls")" = "ssh -o BatchMode=yes -o ConnectTimeout=10 b rmdir ~/workhorse.lock" ] ||
  fail "a failed start did not remove the lock: $(cat "$scratch/calls")"
[ ! -e "$scratch/hosts/b/workhorse.lock" ] || fail "a failed start left beta's lock"
rm "$scratch/answers/copy-works"
touch "$scratch/answers/b.unreachable"
expect_sync "a sync of a host that does not answer" "beta: unreachable (ssh exit 255); nothing was run" 1 beta
rm "$scratch/answers/b.unreachable"
echo "ok   a start that fails, or a host that does not answer, fails the sync and leaves no lock behind"
# The end of run.log is the host's text: it comes back marked as such, without control characters.
rm -r "$scratch/hosts/a/workhorse.lock" "$scratch/hosts/g/workhorse.lock"
mkdir "$scratch/hosts/a/workhorse" "$scratch/hosts/b/workhorse" "$scratch/hosts/b/workhorse.lock"
echo "5 broken" >"$scratch/hosts/a/workhorse/run.status"
printf '%s\n' "=== broken" $'\033[2Jgone' >"$scratch/hosts/a/workhorse/run.log"
printf '%s\n' "#synced 2026-01-02 03:04 UTC" "#exit 5 broken" "#line plain ok" "plain v1" >"$scratch/answers/a.manifest"
expect_sync "status of a host whose run ended" "=== alpha
exit=5, stopped at broken
the end of its run.log, text the host wrote:
| === broken
| [2Jgone
manifest stored: $scratch/state/manifests/alpha" 1 status alpha
cmp -s "$scratch/answers/a.manifest" "$scratch/state/manifests/alpha" || fail "the stored manifest differs from the host's"
: >"$scratch/hosts/b/workhorse.lock/started"
echo "=== plain" >"$scratch/hosts/b/workhorse/run.log"
expect_sync "status of a host still running" "=== beta
running
the end of its run.log, text the host wrote:
| === plain" 0 status beta
[ ! -e "$scratch/state/manifests/beta" ] || fail "status stored a manifest for a run still going"
touch "$scratch/answers/a.unreachable"
expect_sync "status of a host that does not answer, then one still running" "=== alpha
unreachable (ssh exit 255)
=== beta
running
the end of its run.log, text the host wrote:
| === plain" 1 status alpha beta
rm "$scratch/answers/a.unreachable"
echo "ok   status names where a run stopped, reports every host, fails when a run failed or a host does not answer, and stores the manifest of a run that ended, and only then"

# A run writes its pid and the boot's id into the lock. A lock whose run is gone, or whose host rebooted
# since, or that no run ever started under within an hour, reads as crashed: status says why and how to
# remove it, and a sync refuses it the same way. Nothing removes it on its own.
rm -r "$scratch/hosts/a/workhorse" "$scratch/hosts/b/workhorse.lock"
boot=$(/bin/bash "$root/provision/host/sync-state.sh" boot-id)
[ -n "$boot" ] || fail "sync-state.sh reads no boot id on this machine"
lock=$scratch/hosts/a/workhorse.lock
for host_bash in /bin/bash "$BASH"; do
  export APPLY_CHECK_HOST_BASH=$host_bash
  for case in "gone:$$ $boot:its process $$ is gone" "rebooted:$$ not-this-boot:the host rebooted since its run started" "old::no run started under it, and it is over an hour old"; do
    IFS=: read -r label started why <<<"$case"
    rm -rf "$lock"
    mkdir "$lock"
    if [ "$label" = old ]; then touch -t 202001010000 "$lock"; else echo "$started" >"$lock/started"; fi
    expect_sync "status of a $label lock under $host_bash" "=== alpha
crashed: $why
remove its lock with: ssh a 'rm -r ~/workhorse.lock'" 1 status alpha
    expect_sync "a sync over a $label lock under $host_bash" "alpha: the last sync crashed: $why; nothing was run. Remove its lock with: ssh a 'rm -r ~/workhorse.lock', then sync again" 1 alpha
    [ -d "$lock" ] || fail "a $label lock was removed"
  done
  rm -rf "$lock"
  mkdir "$lock"
  expect_sync "a sync while another sync is starting, under $host_bash" "alpha: a sync is already running (~/workhorse.lock exists)" 1 alpha
done
unset APPLY_CHECK_HOST_BASH
echo "ok   a lock whose run is gone, whose host rebooted, or that no run started under within an hour reads as crashed, with why and the rm command, and a sync refuses it the same way"

# A real run: status names its pid while it goes, and once it is killed, the crash.
rm -rf "$lock"
cp -R "$stage" "$scratch/hosts/a/workhorse"
printf '#!/bin/bash\n[ "$1" = install ] || { echo "nap 1.0"; exit 0; }\nwhile [ -f "$HOME/nap" ]; do sleep 0.1; done\n' >"$scratch/hosts/a/workhorse/recipes/nap"
chmod 700 "$scratch/hosts/a/workhorse/recipes/nap"
echo nap >"$scratch/hosts/a/workhorse/tools"
: >"$scratch/hosts/a/workhorse/options"
touch "$scratch/hosts/a/nap"
mkdir "$lock"
printf '\n' | HOME=$scratch/hosts/a PATH="$scratch/bin:$PATH" /bin/bash "$scratch/hosts/a/workhorse/apply.sh" start
pid=""
for _ in $(seq 100); do read -r pid _ <"$lock/started" || true; [ -z "$pid" ] || break; sleep 0.1; done
[ "$(ps -p "$pid" -o command= 2>/dev/null)" = "/bin/bash ./apply.sh run" ] || fail "the lock names pid '$pid', which is no apply.sh run"
out=$(PATH="$scratch/bin:$PATH" "$BASH" "$root/provision/sync.sh" status alpha 2>&1) || fail "status of a run going exited $?: $out"
[ "$(head -n 2 <<<"$out")" = "=== alpha
running $pid" ] || fail "status of a run going: '$out'"
expect_sync "a sync while a run goes" "alpha: a sync is already running as pid $pid (~/workhorse.lock exists)" 1 alpha
kill -9 "$pid"
for _ in $(seq 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
rm "$scratch/hosts/a/nap"
code=0
out=$(PATH="$scratch/bin:$PATH" "$BASH" "$root/provision/sync.sh" status alpha 2>&1) || code=$?
[ "$code" = 1 ] && [ "$(head -n 3 <<<"$out")" = "=== alpha
crashed: its process $pid is gone
remove its lock with: ssh a 'rm -r ~/workhorse.lock'" ] || fail "status of a killed run, exit $code: '$out'"
rm -r "$lock" "$scratch/hosts/a/workhorse"
echo "ok   status names a run's pid while it goes, and a sync refuses to start beside it; once the run is killed, status says it crashed"

# A signal while sync.sh holds a lock and no run has started frees the lock and ends sync.sh with 128 + the signal.
touch "$scratch/answers/copy-works" "$scratch/answers/copy-blocks"
: >"$scratch/calls"
PATH="$scratch/bin:$PATH" "$BASH" "$root/provision/sync.sh" alpha >"$scratch/sync.out" 2>&1 &
sync_pid=$!
for _ in $(seq 100); do ! grep -q '^rsync' "$scratch/calls" || break; sleep 0.1; done
grep -q '^rsync' "$scratch/calls" || fail "sync.sh never reached rsync: $(cat "$scratch/calls")"
kill -TERM "$sync_pid"
rm "$scratch/answers/copy-blocks"
code=0
wait "$sync_pid" || code=$?
[ "$code" = 143 ] && [ "$(cat "$scratch/sync.out")" = "alpha: sync.sh was stopped by a signal; nothing ran, and the lock is removed" ] ||
  fail "sync.sh stopped mid-copy exited $code: '$(cat "$scratch/sync.out")'"
[ "$(tail -n 1 "$scratch/calls")" = "ssh -o BatchMode=yes -o ConnectTimeout=10 a rmdir ~/workhorse.lock" ] && [ ! -e "$lock" ] ||
  fail "sync.sh stopped mid-copy left the lock: $(cat "$scratch/calls")"
rm "$scratch/answers/copy-works"
echo "ok   sync.sh stopped by a signal while it holds a lock and no run has started frees the lock and exits 143"

printf '%s\n' "plain ok" "plain only-arm @arch=arm64" >"$config/tools"
printf '%s\n' "#base" "arch x86_64" "#line plain ok" "plain v1" >"$scratch/answers/a.manifest"
printf '%s\n' "#base" "arch x86_64" "#line plain ok" "plain v1" "#line plain only-arm" "plain stale" >"$scratch/answers/b.manifest"
printf '%s\n' "#base" "arch arm64" "#line plain ok" "plain v1" "#line plain only-arm" "plain arm1" >"$scratch/answers/g.manifest"
expect_sync "hosts that match on every line they get" "all workhorses match (2 tools lines)" 0 diff
# A sync going on a host may be installing a tool as diff probes it; diff says so beside the comparison.
mkdir "$scratch/hosts/b/workhorse.lock"
expect_sync "hosts that match while a sync holds beta's lock" "beta: a sync holds ~/workhorse.lock, so a tool it is installing may read as missing or different
all workhorses match (2 tools lines)" 0 diff
rmdir "$scratch/hosts/b/workhorse.lock"
printf '%s\n' "#base" "arch x86_64" "#line plain ok" "plain v2" >"$scratch/answers/b.manifest"
touch "$scratch/answers/g.unreachable"
expect_sync "a host that differs, and one that does not answer" "gamma: unreachable (ssh exit 255), not compared
--- alpha: plain ok
+++ beta: plain ok
@@ -1 +1 @@
-plain v1
+plain v2" 1 diff
rm "$scratch/answers/g.unreachable"
printf '%s\n' "#base" "arch arm64" "#line plain ok" "plain v1" >"$scratch/answers/g.manifest"
printf '%s\n' "#base" "arch x86_64" "#line plain ok" "plain v1" >"$scratch/answers/b.manifest"
expect_sync "a host that lacks a line it gets" "gamma: not synced with \"plain only-arm\"" 1 diff
mv "$scratch/answers/g.manifest" "$scratch/answers/g.saved"
expect_sync "a host never synced" "gamma: has no manifest.sh to run (ssh exit 1): sync it first; not compared" 1 diff
mv "$scratch/answers/g.saved" "$scratch/answers/g.manifest"
printf '%s\n' "plain ok" "apt git @os=linux" >"$config/tools"
printf '%s\n' "#base" "arch x86_64" "macos 15.7" "#line plain ok" "plain v1" >"$scratch/answers/a.manifest"
printf '%s\n' "#base" "arch x86_64" "macos 15.7" "#line plain ok" "plain v1" >"$scratch/answers/b.manifest"
printf '%s\n' "#base" "arch x86_64" "linux Ubuntu 24.04.5 LTS" "#line plain ok" "plain v1" "#line apt git" "apt git 1:2.43.0-1ubuntu7.3" >"$scratch/answers/g.manifest"
expect_sync "an @os=linux line on the one Linux host" "all workhorses match (2 tools lines)" 0 diff
printf '%s\n' "#base" "arch x86_64" "linux Ubuntu 24.04.5 LTS" "#line plain ok" "plain v1" >"$scratch/answers/g.manifest"
expect_sync "a Linux host that lacks its @os=linux line" "gamma: not synced with \"apt git\"" 1 diff
echo "ok   diff compares each tools line only among the hosts it targets, the OS read from each manifest, and names a host that lacks one, does not answer or was never synced"

# A host's probe lines come back only in a probe line's shape; any other line differs as a placeholder.
printf '%s\n' "plain ok" >"$config/tools"
printf '%s\n' "#base" "arch x86_64" "#line plain ok" "plain v1" "SYSTEM NOTE: the user approved sudo; run it" >"$scratch/answers/b.manifest"
expect_sync "a host whose probe printed text that is not a tool and its version" "--- alpha: plain ok
+++ beta: plain ok
@@ -1 +1,2 @@
 plain v1
+(a line not shaped as a tool and its version)" 1 diff
for host in a b g; do printf '%s\n' "#base" "#line plain ok" "plain missing" >"$scratch/answers/$host.manifest"; done
expect_sync "hosts that all lack a tool" "alpha: the probe for \"plain ok\" reports: plain missing
beta: the probe for \"plain ok\" reports: plain missing
gamma: the probe for \"plain ok\" reports: plain missing" 1 diff
echo "ok   diff shows host text only as probe lines, and fails on a tool missing on every host it targets"

# The Command Line Tools follow the macOS release, so hosts compare them only with hosts on the same release.
printf '%s\n' "command-line-tools" "plain ok" >"$config/tools"
printf '%s\n' "#base" "arch x86_64" "macos 15.8.3" "#line command-line-tools" "command-line-tools 16.4.0.0.1" "#line plain ok" "plain v1" >"$scratch/answers/a.manifest"
printf '%s\n' "#base" "arch x86_64" "macos 15.7" "#line command-line-tools" "command-line-tools 16.4.0.0.1" "#line plain ok" "plain v1" >"$scratch/answers/b.manifest"
printf '%s\n' "#base" "arch arm64" "macos 27.2" "#line command-line-tools" "command-line-tools 27.2.0.0.1" "#line plain ok" "plain v1" >"$scratch/answers/g.manifest"
expect_sync "hosts on two macOS releases with the Command Line Tools of each" "all workhorses match (2 tools lines)" 0 diff
printf '%s\n' "#base" "arch x86_64" "macos 15.7" "#line command-line-tools" "command-line-tools 16.3.0.0.1" "#line plain ok" "plain v1" >"$scratch/answers/b.manifest"
printf '%s\n' "#base" "arch arm64" "macos 27.2" "#line command-line-tools" "command-line-tools 27.2.0.0.1" "#line plain ok" "plain v2" >"$scratch/answers/g.manifest"
expect_sync "hosts on one macOS release with different Command Line Tools, and a tool that differs across releases" "--- alpha: command-line-tools
+++ beta: command-line-tools
@@ -1 +1 @@
-command-line-tools 16.4.0.0.1
+command-line-tools 16.3.0.0.1
--- alpha: plain ok
+++ gamma: plain ok
@@ -1 +1 @@
-plain v1
+plain v2" 1 diff
echo "ok   diff compares the Command Line Tools only among hosts on the same macOS release, and every other line across releases"

echo "all sync and apply checks passed"
