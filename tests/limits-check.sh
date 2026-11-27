#!/bin/bash
# ABOUTME: Checks wh's time limits and the copy's lock without a workhorse: the probe bound in scripts/lib/bounded.sh, the job
# ABOUTME: limit in run_job, and how prepare, run_job, stop_on_host and a run treat the lock, with every HOME a throwaway folder. Exits 1 on the first miss.
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

# wh stop ends a run by sending SIGTERM to the shell that runs its job, which has no limit as often as not.
mkdir -p "$scratch/work/demo/" "$scratch/work/demo.lock"
rm -f "$scratch/work/demo/leader.pid" "$scratch/work/demo/child"
HOME=$scratch /bin/bash -c "$run_job" _ work/demo . "" "node_modules" 0 sh -c 'echo $$ >leader.pid; sleep 60 & echo $! >child; wait' 2>"$scratch/err" &
runner=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ ! -s "$scratch/work/demo/child" ] || break; sleep 0.5; done
[ -s "$scratch/work/demo/child" ] || fail "the job with no limit never started"
start=$(now)
kill -s TERM "$runner"
code=0
wait "$runner" || code=$?
[ $(($(now) - start)) -le 5 ] || fail "a job with no limit took $(($(now) - start)) s to stop on SIGTERM"
! kill -0 "$(cat "$scratch/work/demo/leader.pid")" 2>/dev/null || fail "a job with no limit outlived the shell that ran it, which exited $code on SIGTERM"
! kill -0 "$(cat "$scratch/work/demo/child")" 2>/dev/null || fail "a job with no limit left its child running on SIGTERM"
[ "$code" = 143 ] || fail "the shell that ran a job with no limit exited $code on SIGTERM, not 143"
[ ! -e "$scratch/work/demo.lock" ] || fail "the shell that ran a job with no limit left its lock on SIGTERM"
echo "ok   SIGTERM to the shell that runs a job with no limit stops the job and its children before the lock goes"

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

# The lock's owner file names the run that took it. When the job ends, the lock goes only while it is
# still that run's: a run that took it over since (after someone removed it) keeps it.
owner="lap pid 1 since 2026-11-26 10:00:00: make"
mkdir -p "$scratch/work/demo" "$scratch/work/demo.lock"
echo "$owner" >"$scratch/work/demo.lock/owner"
HOME=$scratch /bin/bash -c "$run_job" _ work/demo . "" "node_modules" 0 true 2>"$scratch/err"
[ ! -e "$scratch/work/demo.lock" ] || fail "a job whose run still owns the lock left it"
mkdir -p "$scratch/work/demo.lock"
echo "$owner" >"$scratch/work/demo.lock/owner"
HOME=$scratch /bin/bash -c "$run_job" _ work/demo . "" "node_modules" 0 sh -c 'echo "lap pid 2 since 2026-11-26 10:05:00: make" >../demo.lock/owner'
[ "$(cat "$scratch/work/demo.lock/owner" 2>/dev/null)" = "lap pid 2 since 2026-11-26 10:05:00: make" ] ||
  fail "a job's end removed the lock another run had taken over"
rm -rf "$scratch/work/demo.lock"
echo "ok   a job's end frees the lock while its run owns it, and leaves one another run has taken"

# prepare takes the lock, then its answer meets a connection the laptop has closed. It frees the lock on
# the way out, under the Mac's bash 3.2 as under bash 5.
eval "$(sed -n "/^lock_state=\$(cat <<'SCRIPT'\$/,/^)\$/p; /^prepare_work_copy=/,/^)\$/p; /^stop_on_host=/,/^)\$/p" "$mirror")"
[ -n "${prepare_work_copy:-}" ] && [ -n "${stop_on_host:-}" ] || fail "no prepare_work_copy or stop_on_host script in $mirror"
for shell in /bin/bash "$BASH"; do
  rm -rf "$scratch/work/fresh" "$scratch/work/fresh.lock"
  ( HOME=$scratch SSH_CONNECTION="10.0.0.2 5000 10.0.0.9 22" "$shell" -c "$prepare_work_copy" _ work/fresh "$owner" "" "" 2>/dev/null ) | true || :
  sleep 0.2
  [ ! -e "$scratch/work/fresh.lock" ] || fail "$shell: prepare left its lock when its answer met a closed connection"
done
echo "ok   prepare frees its lock when the laptop's connection is gone"

# stop_on_host, run by /bin/sh (dash on a Debian host), signals only a run's live process from this boot.
# A pid from before a restart, or a dead one, is a stale lock: it says so and why, and signals nothing.
if [ "$(uname -s)" = Darwin ]; then boot=$(/usr/sbin/sysctl -n kern.bootsessionuuid); else boot=$(cat /proc/sys/kernel/random/boot_id); fi
for shell in /bin/sh dash; do
  command -v "$shell" >/dev/null || continue
  lock=$scratch/work/stop.lock
  stop() { "$shell" -c "$stop_on_host" _ "$lock" "lap pid 1 since 2026-11-26 10:00:00" "$@"; }
  rm -rf "$lock"
  mkdir "$lock"
  echo "$owner" >"$lock/owner"
  /bin/sleep 30 &
  bystander=$!
  echo "$bystander" >"$lock/pid"
  echo "a-boot-before-this-one" >"$lock/boot"
  got=$(stop 2 wait)
  kill -0 "$bystander" 2>/dev/null || fail "$shell: stop_on_host killed a process whose pid a lock from before a restart names"
  [ "$got" = "stale the host has restarted since the lock was taken" ] || fail "$shell: stop_on_host on a lock from before a restart said '$got'"
  [ -d "$lock" ] || fail "$shell: stop_on_host removed a stale lock"
  echo "$boot" >"$lock/boot"
  got=$(stop 2 wait)
  [ "$got" = signalled ] || fail "$shell: stop_on_host on a run going in this boot said '$got'"
  wait "$bystander" 2>/dev/null || true
  ! kill -0 "$bystander" 2>/dev/null || fail "$shell: stop_on_host left the run's process going"
  got=$(stop 2 wait)
  [ "$got" = "stale its process $bystander is gone" ] || fail "$shell: stop_on_host on a lock whose process is gone said '$got'"
  rm "$lock/pid" "$lock/boot"
  got=$(stop 1 wait)
  [ "$got" = no-pid ] && [ -d "$lock" ] || fail "$shell: stop_on_host waiting on a lock with no pid said '$got'"
  got=$(stop 1 free)
  [ "$got" = freed ] && [ ! -e "$lock" ] || fail "$shell: stop_on_host freeing a lock with no pid said '$got'"
  got=$(stop 1 wait)
  [ "$got" = gone ] || fail "$shell: stop_on_host with no lock said '$got'"
  echo "ok   $shell: stop_on_host signals a run going in this boot, and names a lock from before a restart or with its process gone stale"
done

# A run against a host whose copy is locked, with a stand-in ssh that runs the host's side in a scratch
# home under bash. The laptop's home, the run log in it, and the repository are scratch folders too.
laptop=$scratch/laptop host_home=$scratch/alpha
mkdir -p "$laptop" "$host_home/work" "$scratch/config" "$scratch/fake-bin" "$scratch/repo"
echo "alpha alpha@alpha.local x86_64 6 16" >"$scratch/config/hosts"
git -C "$scratch/repo" init -q
echo demo >"$scratch/repo/README"
git -C "$scratch/repo" add README
git -C "$scratch/repo" -c user.name=check -c user.email=check@example.com commit -qm demo
repo=$(cd "$scratch/repo" && pwd -P)
name=$(printf 'repo-%s' "$(printf '%s' "$repo" | shasum | cut -c1-8)")
# FAKE_SSH_DROP=1 runs the first command on the host, then fails as a dropped connection does.
cat >"$scratch/fake-bin/ssh" <<'SSH'
#!/bin/bash
for command; do :; done
# ssh starts the command in the home folder.
cd "$FAKE_HOST_HOME"
if [ "${FAKE_SSH_DROP:-}" = 1 ] && [ ! -e "$FAKE_SSH_STATE" ]; then
  : >"$FAKE_SSH_STATE"
  HOME=$FAKE_HOST_HOME SSH_CONNECTION="10.0.0.2 5000 10.0.0.9 22" bash -c "$command" >/dev/null 2>&1
  exit 255
fi
HOME=$FAKE_HOST_HOME SSH_CONNECTION="10.0.0.2 5000 10.0.0.9 22" exec bash -c "$command"
SSH
chmod +x "$scratch/fake-bin/ssh"
# Runs wh alpha -- true from the repository and compares the last line of its stderr and its exit code.
expect_run() {
  local label=$1 want=$2 want_exit=$3 code=0
  shift 3
  rm -f "$scratch/ssh-state"
  (cd "$scratch/repo" && HOME=$laptop WORKHORSES_CONFIG_DIR=$scratch/config FAKE_HOST_HOME=$host_home \
    FAKE_SSH_STATE=$scratch/ssh-state PATH=$scratch/fake-bin:$PATH "$@" "$BASH" "$here/../bin/wh" alpha -- true) \
    >/dev/null 2>"$scratch/err" || code=$?
  [ "$(tail -n 1 "$scratch/err")" = "$want" ] && [ "$code" = "$want_exit" ] ||
    fail "$label: wanted '$want' exit $want_exit, got exit $code:
$(cat "$scratch/err")"
  echo "ok   $label"
}
lock=$host_home/work/$name.lock
mkdir "$lock"
echo "$owner" >"$lock/owner"
/bin/sh -c 'echo $$' >"$lock/pid"
dead=$(cat "$lock/pid")
expect_run "a run refused by a stale lock says so, says why and gives the command that removes it" \
  "mirror.sh run: BLOCKED: alpha:~/work/$name.lock is stale (its process $dead is gone), left by $owner; remove it with: ssh alpha@alpha.local 'rm -r ~/work/$name.lock'" 3 env
[ "$(cat "$lock/owner")" = "$owner" ] || fail "a run refused by a stale lock removed it"
[ "$(jq -r 'select(.event == "end") | .reason' "$laptop/.local/state/workhorse/runs.jsonl" | tail -n 1)" = \
  "alpha:~/work/$name.lock is stale (its process $dead is gone), left by $owner; remove it with: ssh alpha@alpha.local 'rm -r ~/work/$name.lock'" ] ||
  fail "the run log's end line does not carry the stale lock's message"
echo $$ >"$lock/pid"
echo "$boot" >"$lock/boot"
expect_run "a run refused by a run going says that run's job runs, with its pid" \
  "mirror.sh run: BLOCKED: alpha:~/work/$name is in use by another run, its job running as pid $$ there: $owner" 3 env
rm "$lock/pid"
expect_run "a run refused by a run still copying says so" \
  "mirror.sh run: BLOCKED: alpha:~/work/$name is in use by another run still copying to it: $owner" 3 env
rm -rf "$lock"
expect_run "a run whose connection drops after the host took its lock frees the lock" \
  "mirror.sh run: BLOCKED: could not lock and refresh alpha:~/work/$name" 3 env FAKE_SSH_DROP=1
[ ! -e "$lock" ] || fail "a run whose connection dropped after the host took its lock left it: $(cat "$lock/owner")"

# Runs bin/wh from a folder inside this repository with an empty config folder, so it stops at the
# missing hosts file at the latest and never reaches a host. Compares stderr and the exit code.
expect_wh() {
  local label=$1 want=$2 want_exit=$3 out code=0
  shift 3
  out=$(cd "$here" && WORKHORSES_CONFIG_DIR=$scratch/no-config "$BASH" "$here/../bin/wh" "$@" 2>&1) || code=$?
  [ "$out" = "$want" ] && [ "$code" = "$want_exit" ] || fail "$label: wanted '$want' exit $want_exit, got '$out' exit $code"
  echo "ok   $label"
}

usage="usage: wh [host] [--timeout <limit>] -- <command...>  (no host: a free workhorse, by load; limit: 90s, 30m, 2h)
       wh ps          (the wh runs going from this machine)
       wh stop <run>  (ends a run, its job on the host included; <run> is the number wh ps shows)
       wh hosts       (each workhorse's load and the runs going on it; --json for one JSON object a host)"
expect_wh "a limit that is not a whole number with s, m or h is refused" \
"wh: --timeout takes a whole number of seconds, minutes or hours (90s, 30m, 2h), not \"5x\"" 2 --timeout 5x -- true
expect_wh "a limit of zero is refused" \
"wh: --timeout takes a whole number of seconds, minutes or hours (90s, 30m, 2h), not \"0m\"" 2 --timeout 0m -- true
expect_wh "a limit over a week is refused" \
"wh: --timeout is at most a week (168h), not \"169h\"" 2 --timeout 169h -- true
expect_wh "a limit too large for shell arithmetic is refused, not wrapped" \
"wh: --timeout is at most a week (168h), not \"1152921504606846976h\"" 2 --timeout 1152921504606846976h -- true
expect_wh "a limit of a week gets as far as the hosts file" \
"workhorses: no hosts file at $scratch/no-config/hosts; the README's First run section shows one" 2 --timeout 168h -- true
expect_wh "--timeout with no value is a usage error" "$usage" 2 --timeout
expect_wh "two hosts are a usage error" "$usage" 2 alpha beta -- true
expect_wh "wh hosts gets as far as the hosts file" \
"workhorses: no hosts file at $scratch/no-config/hosts; the README's First run section shows one" 2 hosts
expect_wh "a good limit, before or after the host, gets as far as the hosts file" \
"workhorses: no hosts file at $scratch/no-config/hosts; the README's First run section shows one" 2 alpha --timeout 30m -- true
WORKHORSES_TAILSCALE_FIRST_COPY_MB=2.5 expect_wh "a Tailscale first-copy limit that is not a whole number is refused" \
"mirror.sh run: WORKHORSES_TAILSCALE_FIRST_COPY_MB takes a whole number of MB from 1 to 9999999, not \"2.5\"" 2 alpha -- true
WORKHORSES_TAILSCALE_FIRST_COPY_MB=0 expect_wh "a Tailscale first-copy limit of zero is refused" \
"mirror.sh run: WORKHORSES_TAILSCALE_FIRST_COPY_MB takes a whole number of MB from 1 to 9999999, not \"0\"" 2 alpha -- true
WORKHORSES_TAILSCALE_FIRST_COPY_MB=10000000 expect_wh "a Tailscale first-copy limit too large for shell arithmetic is refused" \
"mirror.sh run: WORKHORSES_TAILSCALE_FIRST_COPY_MB takes a whole number of MB from 1 to 9999999, not \"10000000\"" 2 alpha -- true
WORKHORSES_TAILSCALE_FIRST_COPY_MB=9999999 expect_wh "the largest Tailscale first-copy limit gets as far as the hosts file" \
"workhorses: no hosts file at $scratch/no-config/hosts; the README's First run section shows one" 2 alpha -- true

echo "all limit checks passed"
