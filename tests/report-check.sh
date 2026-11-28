#!/bin/bash
# ABOUTME: Checks wh hosts: the host-side listing of runs going, and the report built from each host's answer; no host is contacted.
# ABOUTME: Usage: tests/report-check.sh; exits 1 on the first wrong line.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
mirror=$here/../scripts/mirror.sh
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

fail() {
  echo "FAIL $*" >&2
  exit 1
}

# The host side: count_runs with wh_list=1 prints a line for each lock of a run going, then the count.
# It runs under bash and zsh, the login shells hosts have.
eval "$(sed -n "/^lock_state=\$(cat <<'SCRIPT'\$/,/^)\$/p; /^count_runs=/p" "$mirror")"
home=$scratch/home
mkdir -p "$home/work/live-1a2b3c4d.lock" "$home/work/dead.lock" "$home/work/copying.lock" "$home/work/abandoned.lock" \
  "$home/work/rebooted.lock"
echo $$ >"$home/work/live-1a2b3c4d.lock/pid"
# Its pid lives, but the host has restarted since: the pid is another process's now.
echo $$ >"$home/work/rebooted.lock/pid"
echo "a-boot-before-this-one" >"$home/work/rebooted.lock/boot"
echo "other-mac pid 2 since 2026-11-26 09:00:00: before the restart" >"$home/work/rebooted.lock/owner"
printf 'erp-mac pid 3875 since 2026-11-26 15:53:42: sh -c make\n\ttest\n' >"$home/work/live-1a2b3c4d.lock/owner"
/bin/sh -c 'echo $$' >"$home/work/dead.lock/pid"
echo "other-mac pid 1 since 2026-11-26 10:00:00: gone" >"$home/work/dead.lock/owner"
touch -t 202001010000 "$home/work/abandoned.lock"
want=$(printf 'lock\tcopying\t\nlock\tlive-1a2b3c4d\terp-mac pid 3875 since 2026-11-26 15:53:42: sh -c make  test \n2')
for shell in bash zsh; do
  command -v "$shell" >/dev/null || continue
  got=$(HOME=$home "$shell" -c "wh_list=1; $count_runs" 2>"$scratch/err")
  # The count comes last; the lock lines before it come in find's order.
  got="$(sed '$d' <<<"$got" | LC_ALL=C sort)"$'\n'"$(tail -n 1 <<<"$got")"
  [ "$got" = "$want" ] || fail "$shell lists runs going: wanted
$want
got
$got"
  [ ! -s "$scratch/err" ] || fail "$shell listing wrote to stderr: $(cat "$scratch/err")"
  echo "ok   $shell lists a live lock with its owner on one line and a young lock without one, not a dead, abandoned or rebooted lock"
done

# A run's start line names the Claude Code session that started it when CLAUDE_CODE_SESSION_ID holds an
# id, and leaves the key out when it is unset or holds anything else.
eval "$(sed -n '/^run_id=/p; /^start_line() {$/,/^}$/p; /^log_start() {$/,/^}$/p' "$mirror")"
for case in "sess-1A-b2|sess-1A-b2" "|" "bad id;rm|" "$(printf 'x%.0s' $(seq 65))|"; do
  value=${case%|*} want=${case#*|}
  run_log=$scratch/runs-$RANDOM.jsonl
  if [ -n "$value" ]; then CLAUDE_CODE_SESSION_ID=$value log_start xur /repo "" make test; else (unset CLAUDE_CODE_SESSION_ID; log_start xur /repo "" make test); fi
  got=$(jq -r 'if has("session") then .session else "" end' "$run_log")
  [ "$got" = "$want" ] || fail "a start line with CLAUDE_CODE_SESSION_ID='$value' gave session '$got', wanted '$want'"
done
echo "ok   a start line names the session from CLAUDE_CODE_SESSION_ID only when it is an id"

# wh hosts end to end, with a fake ssh first on PATH. For cayde, xur and ikora it runs the probe in a
# scratch home of that host, under bash and (xur, where zsh is installed) zsh; eris refuses the connection, slow never answers, and odd and
# mangled answer something that is not a probe's answer, and linuxy gives a Linux host's answer. The laptop's home is a scratch one too, its
# run log naming the runs going, each one's mirror.sh a sleeping stand-in: two from the same folder
# started by different Claude Code sessions (on xur and ikora, since a folder has one lock a host), one
# whose start line names no session, and one on twice. A run's lock on a host is named as run names it: the folder's
# name and the first 8 hex digits of the SHA-1 of its path. On xur a decoy lock's owner names the xur
# run's pid. twice lists its run's lock twice, and the lock of a run whose start line is older than the
# xur run's and names the same pid, as when a pid is used again: that start is the stale one.
me=$(hostname -s)
work_of() { printf '%s-%s' "${1##*/}" "$(printf '%s' "$1" | shasum | cut -c1-8)"; }
# The fake hosts run the probe on this machine, so they answer with its physical cores.
if [ "$(uname -s)" = Darwin ]; then cores=$(/usr/sbin/sysctl -n hw.physicalcpu)
else cores=$(grep -E '^(physical id|core id)' /proc/cpuinfo | paste - - | sort -u | wc -l | tr -d ' '); fi
laptop=$scratch/laptop
config=$scratch/config
mkdir -p "$scratch/bin" "$scratch/hosts/cayde/work" "$scratch/hosts/xur/work" "$scratch/hosts/ikora/work" \
  "$laptop/.local/state/workhorse" "$config"
cat >"$config/hosts" <<'HOSTS'
cayde cayde-wsl x86_64 6 16
xur xur@Xurs-Mac-mini.local x86_64 6 16
ikora ikora@Ikoras-Mac-mini.local x86_64 6 16
eris eris@192.168.1.98 arm64 10 16
slow slow@slow.local x86_64 6 16
odd odd@odd.local x86_64 6 16
mangled mangled@mangled.local x86_64 6 16
twice twice@twice.local x86_64 6 16
linuxy linuxy@linuxy.local x86_64 6 16
HOSTS
cat >"$scratch/bin/ssh" <<'SSH'
#!/bin/bash
for script; do :; done
case "$5" in
  cayde-wsl) HOME=$FAKE_HOSTS/cayde exec bash -c "$script" ;;
  xur@Xurs-Mac-mini.local) shell=bash; command -v zsh >/dev/null && shell=zsh; HOME=$FAKE_HOSTS/xur exec "$shell" -c "$script" ;;
  ikora@Ikoras-Mac-mini.local) HOME=$FAKE_HOSTS/ikora exec bash -c "$script" ;;
  eris@192.168.1.98) exit 255 ;;
  slow@slow.local) exec sleep 30 ;;
  odd@odd.local) printf 'Last login: Thu Nov 26 \033[1mon ttys000\n%s\n' "$(printf 'x%.0s' $(seq 250))" ;;
  mangled@mangled.local) printf '{ 1.00 1.00 1.00 }\n6\nlock\tok-1\towner\nnot a lock line\n1\n' ;;
  twice@twice.local) printf '0.50 0.40 0.30 1/215 1245\n6\n%s\n%s\n%s\n3\n' "$TWICE_LOCK" "$TWICE_LOCK" "$TWICE_STALE" ;;
  linuxy@linuxy.local) printf '0.50 0.40 0.30 1/215 1245\n6\nlock\tlx-1\tother-mac pid 7 since 2026-11-26 08:00:00: cargo test\n1\n' ;;
  *) echo "fake ssh: unexpected arguments: $*" >&2; exit 99 ;;
esac
SSH
chmod +x "$scratch/bin/ssh"
printf '#!/bin/bash\nsleep 60\n' >"$scratch/mirror.sh"
chmod +x "$scratch/mirror.sh"
"$scratch/mirror.sh" run 2>/dev/null &
stand_in=$!
"$scratch/mirror.sh" run 2>/dev/null &
stand_in_b=$!
"$scratch/mirror.sh" run 2>/dev/null &
stand_in_c=$!
"$scratch/mirror.sh" run 2>/dev/null &
stand_in_d=$!
trap 'for p in $stand_in $stand_in_b $stand_in_c $stand_in_d; do pkill -P "$p" 2>/dev/null || true; kill "$p" 2>/dev/null || true; done; rm -rf "$scratch"' EXIT
batch=$laptop/proj/.claude/worktrees/ai-batch
{
  jq -nc --argjson pid "$stand_in" --arg dir "$laptop/proj" \
    '{event: "start", id: "r0", at: 0, host: "twice", dir: $dir, sub: "", command: "make stale", pid: $pid}'
  jq -nc --argjson pid "$stand_in" --arg dir "$batch" \
    '{event: "start", id: "r1", at: 1, host: "xur", dir: $dir, sub: "", command: "gtimeout 45m make test", pid: $pid, session: "sess-A1"}'
  jq -nc --argjson pid "$stand_in_b" --arg dir "$batch" \
    '{event: "start", id: "r2", at: 2, host: "ikora", dir: $dir, sub: "", command: "make lint", pid: $pid, session: "sess-B2"}'
  jq -nc --argjson pid "$stand_in_c" --arg dir "$laptop/proj" \
    '{event: "start", id: "r3", at: 3, host: "ikora", dir: $dir, sub: "", command: "make docs", pid: $pid}'
  jq -nc --argjson pid "$stand_in_d" --arg dir "$batch" \
    '{event: "start", id: "r4", at: 4, host: "twice", dir: $dir, sub: "", command: "make twice", pid: $pid, session: "sess-D4"}'
} >"$laptop/.local/state/workhorse/runs.jsonl"
batch_work=$(work_of "$batch")
proj_work=$(work_of "$laptop/proj")
locks=$scratch/hosts/ikora/work
mkdir "$locks/$batch_work.lock" "$locks/$proj_work.lock"
for lock in "$batch_work" "$proj_work"; do echo $$ >"$locks/$lock.lock/pid"; done
echo "$me pid $stand_in_b since 2026-11-26 15:54:00: make lint" >"$locks/$batch_work.lock/owner"
echo "$me pid $stand_in_c since 2026-11-26 15:55:00: make docs" >"$locks/$proj_work.lock/owner"
locks=$scratch/hosts/xur/work
mkdir "$locks/$batch_work.lock" "$locks/other-1234abcd.lock" "$locks/bare-00000000.lock" "$locks/esc-11111111.lock" "$locks/decoy-22222222.lock"
for lock in "$batch_work" other-1234abcd esc-11111111 decoy-22222222; do echo $$ >"$locks/$lock.lock/pid"; done
echo "$me pid $stand_in since 2026-11-26 15:53:42: gtimeout 45m make test" >"$locks/$batch_work.lock/owner"
echo "$me pid $stand_in since 2026-11-26 15:53:42: harmless looking" >"$locks/decoy-22222222.lock/owner"
printf 'other-mac pid 412 since 2026-11-26 09:05:01: make\ttest\n' >"$locks/other-1234abcd.lock/owner"
# Escape sequences, C1 and CR, and the characters that reorder or hide text: U+202E, U+200B, U+FEFF, U+2066.
printf '%s pid 999 since 2026-11-26 10:00:00: printf \033[31mred\033[0m \302\233d\342\200\256o\342\200\213n\357\273\277e\342\201\246\r\n' "$me" >"$locks/esc-11111111.lock/owner"

twice_lock=$(printf 'lock\t%s\t%s pid %s since 2026-11-26 16:00:00: make twice' "$batch_work" "$me" "$stand_in_d")
twice_stale=$(printf 'lock\t%s\t%s pid %s since 2026-11-26 08:00:00: make stale' "$proj_work" "$me" "$stand_in")

mkdir "$scratch/tmp"
wh() {
  HOME=$laptop WORKHORSES_CONFIG_DIR=$config FAKE_HOSTS=$scratch/hosts TWICE_LOCK=$twice_lock TWICE_STALE=$twice_stale TMPDIR=$scratch/tmp PATH=$scratch/bin:$PATH \
    "$BASH" "$here/../bin/wh" "$@"
}

started=$(date +%s)
code=0
wh hosts --json >"$scratch/out" 2>"$scratch/err" || code=$?
[ "$code" = 0 ] || fail "wh hosts --json exited $code: $(cat "$scratch/err")"
[ ! -s "$scratch/err" ] || fail "wh hosts --json wrote to stderr: $(cat "$scratch/err")"
[ $(($(date +%s) - started)) -le 15 ] || fail "wh hosts --json took $(($(date +%s) - started)) s with a host that never answers"
loads=$(jq -r 'select(.state == "ok") | .load | type' "$scratch/out" | sort -u)
[ "$loads" = number ] || fail "wh hosts --json gave loads of type '$loads', not number"
got=$(jq -c 'if .host == "cayde" or .host == "xur" or .host == "ikora" then .load = "L" else . end' "$scratch/out")
want="{\"host\":\"cayde\",\"state\":\"ok\",\"load\":\"L\",\"cores\":$cores,\"runs\":[]}
{\"host\":\"xur\",\"state\":\"ok\",\"load\":\"L\",\"cores\":$cores,\"runs\":[\
{\"work\":\"$batch_work\",\"machine\":\"$me\",\"pid\":$stand_in,\"since\":\"2026-11-26 15:53:42\",\"command\":\"gtimeout 45m make test\",\"dir\":\"$batch\",\"session\":\"sess-A1\",\"stoppable\":true},\
{\"work\":\"bare-00000000\",\"machine\":null,\"pid\":null,\"since\":null,\"command\":\"\",\"dir\":null,\"session\":null,\"stoppable\":false},\
{\"work\":\"decoy-22222222\",\"machine\":\"$me\",\"pid\":$stand_in,\"since\":\"2026-11-26 15:53:42\",\"command\":\"harmless looking\",\"dir\":null,\"session\":null,\"stoppable\":false},\
{\"work\":\"esc-11111111\",\"machine\":\"$me\",\"pid\":999,\"since\":\"2026-11-26 10:00:00\",\"command\":\"printf [31mred[0m done\",\"dir\":null,\"session\":null,\"stoppable\":false},\
{\"work\":\"other-1234abcd\",\"machine\":\"other-mac\",\"pid\":412,\"since\":\"2026-11-26 09:05:01\",\"command\":\"make test\",\"dir\":null,\"session\":null,\"stoppable\":false}]}
{\"host\":\"ikora\",\"state\":\"ok\",\"load\":\"L\",\"cores\":$cores,\"runs\":[\
{\"work\":\"$batch_work\",\"machine\":\"$me\",\"pid\":$stand_in_b,\"since\":\"2026-11-26 15:54:00\",\"command\":\"make lint\",\"dir\":\"$batch\",\"session\":\"sess-B2\",\"stoppable\":true},\
{\"work\":\"$proj_work\",\"machine\":\"$me\",\"pid\":$stand_in_c,\"since\":\"2026-11-26 15:55:00\",\"command\":\"make docs\",\"dir\":\"$laptop/proj\",\"session\":null,\"stoppable\":true}]}
{\"host\":\"eris\",\"state\":\"unreachable\"}
{\"host\":\"slow\",\"state\":\"unreachable\"}
{\"host\":\"odd\",\"state\":\"unexpected\",\"answer\":\"Last login: Thu Nov 26 [1mon ttys000 $(printf 'x%.0s' $(seq 163))\"}
{\"host\":\"mangled\",\"state\":\"unexpected\",\"answer\":\"{ 1.00 1.00 1.00 } 6 lock ok-1 owner not a lock line 1\"}
{\"host\":\"twice\",\"state\":\"ok\",\"load\":0.50,\"cores\":6,\"runs\":[\
{\"work\":\"$batch_work\",\"machine\":\"$me\",\"pid\":$stand_in_d,\"since\":\"2026-11-26 16:00:00\",\"command\":\"make twice\",\"dir\":\"$batch\",\"session\":\"sess-D4\",\"stoppable\":true},\
{\"work\":\"$batch_work\",\"machine\":\"$me\",\"pid\":$stand_in_d,\"since\":\"2026-11-26 16:00:00\",\"command\":\"make twice\",\"dir\":null,\"session\":null,\"stoppable\":false},\
{\"work\":\"$proj_work\",\"machine\":\"$me\",\"pid\":$stand_in,\"since\":\"2026-11-26 08:00:00\",\"command\":\"make stale\",\"dir\":null,\"session\":null,\"stoppable\":false}]}
{\"host\":\"linuxy\",\"state\":\"ok\",\"load\":0.50,\"cores\":6,\"runs\":[{\"work\":\"lx-1\",\"machine\":\"other-mac\",\"pid\":7,\"since\":\"2026-11-26 08:00:00\",\"command\":\"cargo test\",\"dir\":null,\"session\":null,\"stoppable\":false}]}"
[ "$got" = "$want" ] || fail "wh hosts --json: wanted
$want
got
$got"
echo "ok   wh hosts --json reports each host in file order: its load and runs, unreachable, or its answer made plain text"
twice_stoppable=$(jq -s '[.[] | select(.state == "ok") | .runs[] | select(.stoppable) | .pid] | group_by(.) | map(select(length > 1) | .[0])' "$scratch/out")
[ "$twice_stoppable" = "[]" ] || fail "wh hosts --json has more than one Stop for pids $twice_stoppable"
echo "ok   only the lock named for a run's folder gets its folder, session and Stop, and a pid gets one Stop across hosts"

code=0
wh hosts >"$scratch/out" 2>"$scratch/err" || code=$?
[ "$code" = 0 ] || fail "wh hosts exited $code: $(cat "$scratch/err")"
got=$(sed -E '/^(cayde|xur|ikora) /s/load [0-9]+[.][0-9]{2} of/load L of/' "$scratch/out")
want="cayde    load L of $cores cores, idle
xur      load L of $cores cores, 5 runs
         $stand_in  ~/proj/.claude/worktrees/ai-batch  since 15:53  gtimeout 45m make test
         bare-00000000: no owner recorded
         from $me pid $stand_in since 2026-11-26 15:53:42: harmless looking
         from $me pid 999 since 2026-11-26 10:00:00: printf [31mred[0m done
         from other-mac pid 412 since 2026-11-26 09:05:01: make test
ikora    load L of $cores cores, 2 runs
         $stand_in_b  ~/proj/.claude/worktrees/ai-batch  since 15:54  make lint
         $stand_in_c  ~/proj  since 15:55  make docs
eris     unreachable
slow     unreachable
odd      unexpected answer: Last login: Thu Nov 26 [1mon ttys000 $(printf 'x%.0s' $(seq 163))
mangled  unexpected answer: { 1.00 1.00 1.00 } 6 lock ok-1 owner not a lock line 1
twice    load 0.50 of 6 cores, 3 runs
         $stand_in_d  ~/proj/.claude/worktrees/ai-batch  since 16:00  make twice
         from $me pid $stand_in_d since 2026-11-26 16:00:00: make twice
         from $me pid $stand_in since 2026-11-26 08:00:00: make stale
linuxy   load 0.50 of 6 cores, 1 run
         from other-mac pid 7 since 2026-11-26 08:00:00: cargo test"
[ "$got" = "$want" ] || fail "wh hosts: wanted
$want
got
$got"
echo "ok   wh hosts prints each host's load and runs, this laptop's with the number wh stop takes and the folder"

for args in "hosts extra" "hosts --json extra" "hosts --jsonx"; do
  code=0
  # shellcheck disable=SC2086 # one argument a word
  wh $args >"$scratch/out" 2>"$scratch/err" || code=$?
  [ "$code" = 2 ] && [ "$(cat "$scratch/err")" = "usage: wh hosts [--json]" ] && [ ! -s "$scratch/out" ] ||
    fail "wh $args: wanted exit 2 and the usage line, got exit $code: $(cat "$scratch/err")"
done
echo "ok   wh hosts with an argument other than --json is a usage error"

# wh hosts leaves no folder of answers behind: not when it reports, not when building a host's report fails
# (a jq that fails where it reads a host's answer stands in for that), and not when it is stopped mid-probe
# (the mod stops a wh hosts that runs past its time limit).
[ -z "$(ls -A "$scratch/tmp")" ] || fail "wh hosts left $(ls -A "$scratch/tmp") in TMPDIR"
mkdir "$scratch/failing-jq"
cat >"$scratch/failing-jq/jq" <<JQ
#!/bin/bash
for arg; do [ "\$arg" != --rawfile ] || exit 5; done
exec $(command -v jq) "\$@"
JQ
chmod +x "$scratch/failing-jq/jq"
code=0
PATH=$scratch/failing-jq:$PATH wh hosts --json >"$scratch/out" 2>"$scratch/err" || code=$?
[ "$code" = 1 ] || fail "wh hosts with a failing report exited $code, wanted 1: $(cat "$scratch/err")"
[ -z "$(ls -A "$scratch/tmp")" ] || fail "wh hosts left $(ls -A "$scratch/tmp") in TMPDIR when a host's report failed"
# Not through the wh function: in the background that is a subshell, and the TERM must reach mirror.sh,
# which bin/wh execs.
HOME=$laptop WORKHORSES_CONFIG_DIR=$config FAKE_HOSTS=$scratch/hosts TWICE_LOCK=$twice_lock TWICE_STALE=$twice_stale TMPDIR=$scratch/tmp PATH=$scratch/bin:$PATH \
  "$BASH" "$here/../bin/wh" hosts --json >/dev/null 2>&1 &
stopped=$!
for _ in $(seq 50); do [ -z "$(ls -A "$scratch/tmp")" ] || break; sleep 0.1; done
[ -n "$(ls -A "$scratch/tmp")" ] || fail "wh hosts made no folder of answers to stop it in"
kill -s TERM "$stopped"
wait "$stopped" 2>/dev/null || true
[ -z "$(ls -A "$scratch/tmp")" ] || fail "wh hosts left $(ls -A "$scratch/tmp") in TMPDIR when stopped"
# A TERM can land while mktemp is making the folder, before the EXIT trap could know its name. A mktemp
# that makes the folder and then waits a second holds that moment open.
mkdir "$scratch/slow-mktemp"
cat >"$scratch/slow-mktemp/mktemp" <<MKTEMP
#!/bin/bash
made=\$($(command -v mktemp) "\$@") || exit
sleep 1
printf '%s\n' "\$made"
MKTEMP
chmod +x "$scratch/slow-mktemp/mktemp"
HOME=$laptop WORKHORSES_CONFIG_DIR=$config FAKE_HOSTS=$scratch/hosts TWICE_LOCK=$twice_lock TWICE_STALE=$twice_stale TMPDIR=$scratch/tmp PATH=$scratch/slow-mktemp:$scratch/bin:$PATH \
  "$BASH" "$here/../bin/wh" hosts --json >/dev/null 2>&1 &
stopped=$!
for _ in $(seq 50); do [ -z "$(ls -A "$scratch/tmp")" ] || break; sleep 0.1; done
[ -n "$(ls -A "$scratch/tmp")" ] || fail "wh hosts made no folder of answers to stop it in"
kill -s TERM "$stopped"
wait "$stopped" 2>/dev/null || true
# The stand-in's own wait ends before the folder is looked at.
sleep 1.5
[ -z "$(ls -A "$scratch/tmp")" ] || fail "wh hosts left $(ls -A "$scratch/tmp") in TMPDIR when stopped while making it"
echo "ok   wh hosts removes its folder of answers when it reports, fails or is stopped, even while making it"

echo "wh hosts reports are right"
