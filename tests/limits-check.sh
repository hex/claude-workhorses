#!/bin/bash
# ABOUTME: Checks wh's time limits without a workhorse: the probe bound in scripts/lib/bounded.sh and the job
# ABOUTME: limit in mirror.sh's run_job, run here under bash with HOME in a throwaway folder. Exits 1 on the first miss.
# The job commands below are sh scripts held as text: their $ signs are theirs, not this script's.
# shellcheck disable=SC2016
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
mirror=$here/../scripts/mirror.sh
# shellcheck source=../scripts/lib/bounded.sh
. "$here/../scripts/lib/bounded.sh"
# bash 3.2 cannot source a process substitution, so the scripts' text is evaluated.
eval "$(sed -n "/^list_copy=\$(cat <<'SCRIPT'$/,/^)$/p; /^run_job=/,/^)$/p" "$mirror")"
[ -n "${run_job:-}" ] || { echo "FAIL: no run_job script in $mirror" >&2; exit 1; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/limits-check.XXXX")
# A failing check can leave a job's processes behind; each writes its pid to a file in the copy.
cleanup() {
  local pid
  for pid in $(cat "$scratch"/work/demo/*.pid 2>/dev/null); do kill -9 "$pid" 2>/dev/null || true; done
  rm -rf "$scratch"
}
trap cleanup EXIT

fail() { echo "FAIL $*" >&2; exit 1; }

# Seconds since the epoch, for timing a run to the second.
now() { date +%s; }

start=$(now)
out=$(run_bounded 20 echo answered)
[ "$out" = answered ] || fail "run_bounded lost the command's output: '$out'"
[ $(($(now) - start)) -le 5 ] || fail "run_bounded held the output pipe open until its bound ran out"
echo "ok   a command that answers in time returns at once, with its output"

start=$(now)
code=0
run_bounded 2 sleep 30 || code=$?
[ "$code" != 0 ] || fail "run_bounded returned 0 for a command it stopped"
[ $(($(now) - start)) -le 4 ] || fail "run_bounded let a 30 s command run past its 2 s bound"
echo "ok   a command past its bound is stopped and fails"

code=0
run_bounded 5 sh -c 'exit 7' || code=$?
[ "$code" = 7 ] || fail "run_bounded changed the command's exit code 7 to $code"
echo "ok   a command's own exit code comes back"

# Runs run_job as mirror.sh does on a host: work copy ~/work/demo, lock ~/work/demo.lock, no Watchman
# clock, limit $1 seconds (0: none), then the command. stderr goes to $scratch/err.
job() {
  local limit=$1
  shift
  mkdir -p "$scratch/work/demo" "$scratch/work/demo.lock"
  HOME=$scratch /bin/bash -c "$run_job" _ work/demo . "" "node_modules" "$limit" "$@" 2>"$scratch/err"
}

code=0
job 0 sh -c 'exit 7' || code=$?
[ "$code" = 7 ] || fail "with no limit, the job's exit 7 came back as $code"
[ ! -e "$scratch/work/demo.lock" ] || fail "with no limit, the job left its lock"
echo "ok   with no limit, the job's exit code comes back and the lock goes"

start=$(now)
code=0
job 1 sh -c 'sleep 30 & echo $! >child; sleep 30' || code=$?
[ "$code" = 124 ] || fail "a job past its limit exited $code, not 124"
[ $(($(now) - start)) -le 4 ] || fail "a job with a 1 s limit ran $(($(now) - start)) s"
[ "$(cat "$scratch/err")" = "mirror.sh run: the command ran past its 1 s limit and was stopped" ] ||
  fail "a job past its limit said '$(cat "$scratch/err")'"
sleep 1
! kill -0 "$(cat "$scratch/work/demo/child")" 2>/dev/null || fail "a job past its limit left its child running"
[ ! -e "$scratch/work/demo.lock" ] || fail "a job past its limit left its lock"
echo "ok   a job past its limit is stopped with its children, exits 124, says so and frees the lock"

start=$(now)
code=0
job 1 sh -c '(trap "" TERM; exec sleep 60) & echo $! >immune.pid; sleep 60' || code=$?
immune=$(cat "$scratch/work/demo/immune.pid")
! kill -0 "$immune" 2>/dev/null || fail "a child that ignores SIGTERM outlived the run that stopped its job"
[ "$code" = 124 ] || fail "a job whose child ignores SIGTERM exited $code, not 124"
[ $(($(now) - start)) -le 15 ] || fail "a job whose child ignores SIGTERM took $(($(now) - start)) s to stop"
[ ! -e "$scratch/work/demo.lock" ] || fail "a job whose child ignores SIGTERM left its lock"
echo "ok   a child that ignores SIGTERM gets SIGKILL 10 s later, before the lock goes, even after the job itself has ended"

# The connection to the laptop drops: the shell that runs the job gets SIGHUP.
mkdir -p "$scratch/work/demo/" "$scratch/work/demo.lock"
rm -f "$scratch/work/demo/leader.pid"
HOME=$scratch /bin/bash -c "$run_job" _ work/demo . "" "node_modules" 30 sh -c 'echo $$ >leader.pid; sleep 60' 2>"$scratch/err" &
runner=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ ! -s "$scratch/work/demo/leader.pid" ] || break; sleep 0.5; done
[ -s "$scratch/work/demo/leader.pid" ] || fail "the job never started"
kill -s HUP "$runner"
code=0
wait "$runner" || code=$?
! kill -0 "$(cat "$scratch/work/demo/leader.pid")" 2>/dev/null || fail "the job outlived the shell that ran it, which exited $code on SIGHUP"
[ "$code" = 129 ] || fail "the shell that ran the job exited $code on SIGHUP, not 129"
[ ! -e "$scratch/work/demo.lock" ] || fail "the shell that ran the job left its lock on SIGHUP"
echo "ok   when the shell that runs a job with a limit dies by signal, it stops the job before it frees the lock"

start=$(now)
code=0
job 20 sh -c 'exit 3' || code=$?
[ "$code" = 3 ] || fail "a job inside its limit exited $code, not its own 3"
[ $(($(now) - start)) -le 5 ] || fail "a job inside its limit waited for the limit"
[ ! -s "$scratch/err" ] || fail "a job inside its limit added to its stderr: '$(cat "$scratch/err")'"
# A job that ends at once, a shell builtin, ends while job control is still on; bash 5 would print a
# job notice on the job's stderr.
job 20 true
[ ! -s "$scratch/err" ] || fail "a job that ended at once added to its stderr: '$(cat "$scratch/err")'"
echo "ok   a job inside its limit returns at once with its own exit code and nothing added to stderr"

out=$(echo from-the-laptop | job 20 cat)
[ "$out" = from-the-laptop ] || fail "a job with a limit did not read its stdin: '$out'"
echo "ok   a job with a limit still reads its stdin"

# Runs bin/wh from a folder inside this repository with an empty config folder, so it stops at the
# missing hosts file at the latest and never reaches a host. Compares stderr and the exit code.
expect_wh() {
  local label=$1 want=$2 want_exit=$3 out code=0
  shift 3
  out=$(cd "$here" && CLAUDE_WORKHORSES_CONFIG_DIR=$scratch/no-config "$BASH" "$here/../bin/wh" "$@" 2>&1) || code=$?
  [ "$out" = "$want" ] && [ "$code" = "$want_exit" ] || fail "$label: wanted '$want' exit $want_exit, got '$out' exit $code"
  echo "ok   $label"
}

usage="usage: wh [host] [--timeout <limit>] -- <command...>  (no host: a free workhorse, by load; limit: 90s, 30m, 2h)"
expect_wh "a limit that is not a whole number with s, m or h is refused" \
"wh: --timeout takes a whole number of seconds, minutes or hours (90s, 30m, 2h), not \"5x\"" 2 --timeout 5x -- true
expect_wh "a limit of zero is refused" \
"wh: --timeout takes a whole number of seconds, minutes or hours (90s, 30m, 2h), not \"0m\"" 2 --timeout 0m -- true
expect_wh "a limit over a week is refused" \
"wh: --timeout is at most a week (168h), not \"169h\"" 2 --timeout 169h -- true
expect_wh "a limit too large for shell arithmetic is refused, not wrapped" \
"wh: --timeout is at most a week (168h), not \"1152921504606846976h\"" 2 --timeout 1152921504606846976h -- true
expect_wh "a limit of a week gets as far as the hosts file" \
"claude-workhorses: no hosts file at $scratch/no-config/hosts; the README's First run section shows one" 2 --timeout 168h -- true
expect_wh "--timeout with no value is a usage error" "$usage" 2 --timeout
expect_wh "two hosts are a usage error" "$usage" 2 alpha beta -- true
expect_wh "a good limit, before or after the host, gets as far as the hosts file" \
"claude-workhorses: no hosts file at $scratch/no-config/hosts; the README's First run section shows one" 2 alpha --timeout 30m -- true
CLAUDE_WORKHORSES_TAILSCALE_FIRST_COPY_MB=2.5 expect_wh "a Tailscale first-copy limit that is not a whole number is refused" \
"mirror.sh run: CLAUDE_WORKHORSES_TAILSCALE_FIRST_COPY_MB takes a whole number of MB from 1 to 9999999, not \"2.5\"" 2 alpha -- true
CLAUDE_WORKHORSES_TAILSCALE_FIRST_COPY_MB=0 expect_wh "a Tailscale first-copy limit of zero is refused" \
"mirror.sh run: CLAUDE_WORKHORSES_TAILSCALE_FIRST_COPY_MB takes a whole number of MB from 1 to 9999999, not \"0\"" 2 alpha -- true
CLAUDE_WORKHORSES_TAILSCALE_FIRST_COPY_MB=10000000 expect_wh "a Tailscale first-copy limit too large for shell arithmetic is refused" \
"mirror.sh run: CLAUDE_WORKHORSES_TAILSCALE_FIRST_COPY_MB takes a whole number of MB from 1 to 9999999, not \"10000000\"" 2 alpha -- true
CLAUDE_WORKHORSES_TAILSCALE_FIRST_COPY_MB=9999999 expect_wh "the largest Tailscale first-copy limit gets as far as the hosts file" \
"claude-workhorses: no hosts file at $scratch/no-config/hosts; the README's First run section shows one" 2 alpha -- true

echo "all limit checks passed"
