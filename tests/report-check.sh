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

# wh hosts end to end, with a fake ssh first on PATH. For cayde and xur it runs the probe in a scratch
# home of that host, under bash and zsh; eris refuses the connection, slow never answers, and odd and
# mangled answer something that is not a probe's answer, and linuxy gives a Linux host's answer. The laptop's home is a scratch one too, its
# run log naming one run going, whose mirror.sh is a sleeping stand-in.
me=$(hostname -s)
cores=$(/usr/sbin/sysctl -n hw.physicalcpu)
laptop=$scratch/laptop
config=$scratch/config
mkdir -p "$scratch/bin" "$scratch/hosts/cayde/work" "$scratch/hosts/xur/work" "$laptop/.local/state/workhorse" "$config"
cat >"$config/hosts" <<'HOSTS'
cayde cayde-wsl x86_64 6 16
xur xur@Xurs-Mac-mini.local x86_64 6 16
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
trap 'pkill -P "$stand_in" 2>/dev/null || true; kill "$stand_in" 2>/dev/null || true; rm -rf "$scratch"' EXIT
batch=$laptop/proj/.claude/worktrees/ai-batch
jq -nc --argjson pid "$stand_in" --arg dir "$batch" \
  '{event: "start", id: "r1", at: 1, host: "xur", dir: $dir, sub: "", command: "gtimeout 45m make test", pid: $pid}' \
  >"$laptop/.local/state/workhorse/runs.jsonl"
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
got=$(jq -c 'if .host == "cayde" or .host == "xur" then .load = "L" else . end' "$scratch/out")
want="{\"host\":\"cayde\",\"state\":\"ok\",\"load\":\"L\",\"cores\":$cores,\"runs\":[]}
{\"host\":\"xur\",\"state\":\"ok\",\"load\":\"L\",\"cores\":$cores,\"runs\":[\
{\"work\":\"ai-batch-7f7532ed\",\"machine\":\"$me\",\"pid\":$stand_in,\"since\":\"2026-11-26 15:53:42\",\"command\":\"gtimeout 45m make test\",\"dir\":\"$batch\",\"stoppable\":true},\
{\"work\":\"bare-00000000\",\"machine\":null,\"pid\":null,\"since\":null,\"command\":\"\",\"dir\":null,\"stoppable\":false},\
{\"work\":\"esc-11111111\",\"machine\":\"$me\",\"pid\":999,\"since\":\"2026-11-26 10:00:00\",\"command\":\"printf [31mred[0m done\",\"dir\":null,\"stoppable\":false},\
{\"work\":\"other-1234abcd\",\"machine\":\"other-mac\",\"pid\":412,\"since\":\"2026-11-26 09:05:01\",\"command\":\"make test\",\"dir\":null,\"stoppable\":false}]}
{\"host\":\"eris\",\"state\":\"unreachable\"}
{\"host\":\"slow\",\"state\":\"unreachable\"}
{\"host\":\"odd\",\"state\":\"unexpected\",\"answer\":\"Last login: Thu Nov 26 [1mon ttys000 $(printf 'x%.0s' $(seq 163))\"}
{\"host\":\"mangled\",\"state\":\"unexpected\",\"answer\":\"{ 1.00 1.00 1.00 } 6 lock ok-1 owner not a lock line 1\"}
{\"host\":\"linuxy\",\"state\":\"ok\",\"load\":0.50,\"cores\":6,\"runs\":[{\"work\":\"lx-1\",\"machine\":\"other-mac\",\"pid\":7,\"since\":\"2026-11-26 08:00:00\",\"command\":\"cargo test\",\"dir\":null,\"stoppable\":false}]}"
[ "$got" = "$want" ] || fail "wh hosts --json: wanted
$want
got
$got"
echo "ok   wh hosts --json reports each host in file order: its load and runs, unreachable, or its answer made plain text"

code=0
wh hosts >"$scratch/out" 2>"$scratch/err" || code=$?
[ "$code" = 0 ] || fail "wh hosts exited $code: $(cat "$scratch/err")"
got=$(sed -E '/^(cayde|xur) /s/load [0-9]+[.][0-9]{2} of/load L of/' "$scratch/out")
want="cayde    load L of $cores cores, idle
xur      load L of $cores cores, 4 runs
         $stand_in  ~/proj/.claude/worktrees/ai-batch  since 15:53  gtimeout 45m make test
         bare-00000000: no owner recorded
         from $me pid 999 since 2026-11-26 10:00:00: printf [31mred[0m done
         from other-mac pid 412 since 2026-11-26 09:05:01: make test
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
