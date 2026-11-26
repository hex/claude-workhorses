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
eval "$(sed -n "/^count_runs='/p" "$mirror")"
home=$scratch/home
mkdir -p "$home/work/live-1a2b3c4d.lock" "$home/work/dead.lock" "$home/work/copying.lock" "$home/work/abandoned.lock"
echo $$ >"$home/work/live-1a2b3c4d.lock/pid"
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
  echo "ok   $shell lists a live lock with its owner on one line and a young lock without one, not a dead or abandoned lock"
done

# A run's start line names the Claude Code session that started it when CLAUDE_CODE_SESSION_ID holds an
# id, and leaves the key out when it is unset or holds anything else.
eval "$(sed -n '/^log_start() {$/,/^}$/p' "$mirror")"
for case in "sess-1A-b2|sess-1A-b2" "|" "bad id;rm|" "$(printf 'x%.0s' $(seq 65))|"; do
  value=${case%|*} want=${case#*|}
  run_log=$scratch/runs-$RANDOM.jsonl
  if [ -n "$value" ]; then CLAUDE_CODE_SESSION_ID=$value log_start xur /repo "" make test; else (unset CLAUDE_CODE_SESSION_ID; log_start xur /repo "" make test); fi
  got=$(jq -r 'if has("session") then .session else "" end' "$run_log")
  [ "$got" = "$want" ] || fail "a start line with CLAUDE_CODE_SESSION_ID='$value' gave session '$got', wanted '$want'"
done
echo "ok   a start line names the session from CLAUDE_CODE_SESSION_ID only when it is an id"

# wh hosts end to end, with a fake ssh first on PATH. For cayde, xur and ikora it runs the probe in a
# scratch home of that host, under bash and zsh; eris refuses the connection, slow never answers, and odd and
# mangled answer something that is not a probe's answer, and linuxy gives a Linux host's answer. The laptop's home is a scratch one too, its
# run log naming three runs going, each one's mirror.sh a sleeping stand-in: two from the same folder
# started by different Claude Code sessions (on xur and ikora, since a folder has one lock a host), and
# one whose start line names no session.
me=$(hostname -s)
cores=$(/usr/sbin/sysctl -n hw.physicalcpu)
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
linuxy linuxy@linuxy.local x86_64 6 16
HOSTS
cat >"$scratch/bin/ssh" <<'SSH'
#!/bin/bash
for script; do :; done
case "$5" in
  cayde-wsl) HOME=$FAKE_HOSTS/cayde exec bash -c "$script" ;;
  xur@Xurs-Mac-mini.local) HOME=$FAKE_HOSTS/xur exec zsh -c "$script" ;;
  ikora@Ikoras-Mac-mini.local) HOME=$FAKE_HOSTS/ikora exec bash -c "$script" ;;
  eris@192.168.1.98) exit 255 ;;
  slow@slow.local) exec sleep 30 ;;
  odd@odd.local) printf 'Last login: Thu Nov 26 \033[1mon ttys000\n%s\n' "$(printf 'x%.0s' $(seq 250))" ;;
  mangled@mangled.local) printf '{ 1.00 1.00 1.00 }\n6\nlock\tok-1\towner\nnot a lock line\n1\n' ;;
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
trap 'for p in $stand_in $stand_in_b $stand_in_c; do pkill -P "$p" 2>/dev/null || true; kill "$p" 2>/dev/null || true; done; rm -rf "$scratch"' EXIT
batch=$laptop/proj/.claude/worktrees/ai-batch
{
  jq -nc --argjson pid "$stand_in" --arg dir "$batch" \
    '{event: "start", id: "r1", at: 1, host: "xur", dir: $dir, sub: "", command: "gtimeout 45m make test", pid: $pid, session: "sess-A1"}'
  jq -nc --argjson pid "$stand_in_b" --arg dir "$batch" \
    '{event: "start", id: "r2", at: 2, host: "ikora", dir: $dir, sub: "", command: "make lint", pid: $pid, session: "sess-B2"}'
  jq -nc --argjson pid "$stand_in_c" --arg dir "$laptop/proj" \
    '{event: "start", id: "r3", at: 3, host: "ikora", dir: $dir, sub: "", command: "make docs", pid: $pid}'
} >"$laptop/.local/state/workhorse/runs.jsonl"
locks=$scratch/hosts/ikora/work
mkdir "$locks/ai-batch-7f7532ed.lock" "$locks/proj-5e5e5e5e.lock"
for lock in ai-batch-7f7532ed proj-5e5e5e5e; do echo $$ >"$locks/$lock.lock/pid"; done
echo "$me pid $stand_in_b since 2026-11-26 15:54:00: make lint" >"$locks/ai-batch-7f7532ed.lock/owner"
echo "$me pid $stand_in_c since 2026-11-26 15:55:00: make docs" >"$locks/proj-5e5e5e5e.lock/owner"
locks=$scratch/hosts/xur/work
mkdir "$locks/ai-batch-7f7532ed.lock" "$locks/other-1234abcd.lock" "$locks/bare-00000000.lock" "$locks/esc-11111111.lock"
for lock in ai-batch-7f7532ed other-1234abcd esc-11111111; do echo $$ >"$locks/$lock.lock/pid"; done
echo "$me pid $stand_in since 2026-11-26 15:53:42: gtimeout 45m make test" >"$locks/ai-batch-7f7532ed.lock/owner"
printf 'other-mac pid 412 since 2026-11-26 09:05:01: make\ttest\n' >"$locks/other-1234abcd.lock/owner"
printf '%s pid 999 since 2026-11-26 10:00:00: printf \033[31mred\033[0m \302\233done\r\n' "$me" >"$locks/esc-11111111.lock/owner"

wh() {
  HOME=$laptop WORKHORSES_CONFIG_DIR=$config FAKE_HOSTS=$scratch/hosts PATH=$scratch/bin:$PATH \
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
{\"work\":\"ai-batch-7f7532ed\",\"machine\":\"$me\",\"pid\":$stand_in,\"since\":\"2026-11-26 15:53:42\",\"command\":\"gtimeout 45m make test\",\"dir\":\"$batch\",\"session\":\"sess-A1\",\"stoppable\":true},\
{\"work\":\"bare-00000000\",\"machine\":null,\"pid\":null,\"since\":null,\"command\":\"\",\"dir\":null,\"session\":null,\"stoppable\":false},\
{\"work\":\"esc-11111111\",\"machine\":\"$me\",\"pid\":999,\"since\":\"2026-11-26 10:00:00\",\"command\":\"printf [31mred[0m done\",\"dir\":null,\"session\":null,\"stoppable\":false},\
{\"work\":\"other-1234abcd\",\"machine\":\"other-mac\",\"pid\":412,\"since\":\"2026-11-26 09:05:01\",\"command\":\"make test\",\"dir\":null,\"session\":null,\"stoppable\":false}]}
{\"host\":\"ikora\",\"state\":\"ok\",\"load\":\"L\",\"cores\":$cores,\"runs\":[\
{\"work\":\"ai-batch-7f7532ed\",\"machine\":\"$me\",\"pid\":$stand_in_b,\"since\":\"2026-11-26 15:54:00\",\"command\":\"make lint\",\"dir\":\"$batch\",\"session\":\"sess-B2\",\"stoppable\":true},\
{\"work\":\"proj-5e5e5e5e\",\"machine\":\"$me\",\"pid\":$stand_in_c,\"since\":\"2026-11-26 15:55:00\",\"command\":\"make docs\",\"dir\":\"$laptop/proj\",\"session\":null,\"stoppable\":true}]}
{\"host\":\"eris\",\"state\":\"unreachable\"}
{\"host\":\"slow\",\"state\":\"unreachable\"}
{\"host\":\"odd\",\"state\":\"unexpected\",\"answer\":\"Last login: Thu Nov 26 [1mon ttys000 $(printf 'x%.0s' $(seq 163))\"}
{\"host\":\"mangled\",\"state\":\"unexpected\",\"answer\":\"{ 1.00 1.00 1.00 } 6 lock ok-1 owner not a lock line 1\"}
{\"host\":\"linuxy\",\"state\":\"ok\",\"load\":0.50,\"cores\":6,\"runs\":[{\"work\":\"lx-1\",\"machine\":\"other-mac\",\"pid\":7,\"since\":\"2026-11-26 08:00:00\",\"command\":\"cargo test\",\"dir\":null,\"session\":null,\"stoppable\":false}]}"
[ "$got" = "$want" ] || fail "wh hosts --json: wanted
$want
got
$got"
echo "ok   wh hosts --json reports each host in file order: its load and runs, unreachable, or its answer made plain text"

code=0
wh hosts >"$scratch/out" 2>"$scratch/err" || code=$?
[ "$code" = 0 ] || fail "wh hosts exited $code: $(cat "$scratch/err")"
got=$(sed -E '/^(cayde|xur|ikora) /s/load [0-9]+[.][0-9]{2} of/load L of/' "$scratch/out")
want="cayde    load L of $cores cores, idle
xur      load L of $cores cores, 4 runs
         $stand_in  ~/proj/.claude/worktrees/ai-batch  since 15:53  gtimeout 45m make test
         bare-00000000: no owner recorded
         from $me pid 999 since 2026-11-26 10:00:00: printf [31mred[0m done
         from other-mac pid 412 since 2026-11-26 09:05:01: make test
ikora    load L of $cores cores, 2 runs
         $stand_in_b  ~/proj/.claude/worktrees/ai-batch  since 15:54  make lint
         $stand_in_c  ~/proj  since 15:55  make docs
eris     unreachable
slow     unreachable
odd      unexpected answer: Last login: Thu Nov 26 [1mon ttys000 $(printf 'x%.0s' $(seq 163))
mangled  unexpected answer: { 1.00 1.00 1.00 } 6 lock ok-1 owner not a lock line 1
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

echo "wh hosts reports are right"
