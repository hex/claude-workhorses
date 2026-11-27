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
  for pid in $(cat "$scratch"/work/demo/*.pid "$scratch"/alpha/work/*/job.pid 2>/dev/null); do kill -9 "$pid" 2>/dev/null || true; done
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

# A run's line in its lock's owner file: the run, as the laptop passes it to run_job, then its command.
run_owner="lap pid 1 since 2026-11-26 10:00:00"
owner="$run_owner: make"
# Takes the lock ~/work/demo.lock for the run above, as prepare does.
take_lock() {
  mkdir -p "$scratch/work/demo" "$scratch/work/demo.lock"
  echo "$owner" >"$scratch/work/demo.lock/owner"
}

# Runs run_job as mirror.sh does on a host, under the lock take_lock takes: work copy ~/work/demo, no
# Watchman clock, limit $1 seconds (0: none), then the command. stderr goes to $scratch/err.
job() {
  local limit=$1
  shift
  take_lock
  HOME=$scratch /bin/bash -c "$run_job" _ work/demo "$run_owner" . "" "node_modules" "$limit" "$@" 2>"$scratch/err"
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
take_lock
rm -f "$scratch/work/demo/leader.pid"
HOME=$scratch /bin/bash -c "$run_job" _ work/demo "$run_owner" . "" "node_modules" 30 sh -c 'echo $$ >leader.pid; sleep 60' 2>"$scratch/err" &
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
take_lock
rm -f "$scratch/work/demo/leader.pid" "$scratch/work/demo/child"
HOME=$scratch /bin/bash -c "$run_job" _ work/demo "$run_owner" . "" "node_modules" 0 sh -c 'echo $$ >leader.pid; sleep 60 & echo $! >child; wait' 2>"$scratch/err" &
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
successor="lap pid 2 since 2026-11-26 10:05:00: make"
job 0 true
[ ! -e "$scratch/work/demo.lock" ] || fail "a job whose run still owns the lock left it"
job 0 sh -c "echo '$successor' >../demo.lock/owner"
[ "$(cat "$scratch/work/demo.lock/owner" 2>/dev/null)" = "$successor" ] ||
  fail "a job's end removed the lock another run had taken over"
rm -rf "$scratch/work/demo.lock"
echo "ok   a job's end frees the lock while its run owns it, and leaves one another run has taken"

# Nor does a job start under a lock another run took before it started, or with no lock at all. The
# refusal touches no lock, says nothing, leaves the lock's owner file it found in ~/work/demo.refused
# after this run's own line, and exits 3.
mkdir -p "$scratch/work/demo.lock"
echo "$successor" >"$scratch/work/demo.lock/owner"
echo 4242 >"$scratch/work/demo.lock/pid"
rm -f "$scratch/work/demo/ran"
code=0
HOME=$scratch /bin/bash -c "$run_job" _ work/demo "$run_owner" . "" "node_modules" 0 touch ran 2>"$scratch/err" || code=$?
[ "$code" = 3 ] && [ ! -e "$scratch/work/demo/ran" ] || fail "a job under another run's lock ran, or exited $code, not 3"
[ "$(cat "$scratch/work/demo.lock/owner")" = "$successor" ] && [ "$(cat "$scratch/work/demo.lock/pid")" = 4242 ] ||
  fail "a job refused by another run's lock changed that lock"
[ "$(cat "$scratch/work/demo.refused")" = "$run_owner
$successor" ] || fail "a job refused by another run's lock left '$(cat "$scratch/work/demo.refused")'"
[ ! -s "$scratch/err" ] || fail "a job refused by another run's lock said '$(cat "$scratch/err")'"
rm -rf "$scratch/work/demo.lock" "$scratch/work/demo.refused"
code=0
HOME=$scratch /bin/bash -c "$run_job" _ work/demo "$run_owner" . "" "node_modules" 0 touch ran 2>"$scratch/err" || code=$?
[ "$code" = 3 ] && [ ! -e "$scratch/work/demo/ran" ] || fail "a job with no lock ran, or exited $code, not 3"
[ ! -e "$scratch/work/demo.lock" ] || fail "a job refused for want of a lock made one"
[ "$(cat "$scratch/work/demo.refused")" = "$run_owner" ] || fail "a job with no lock left '$(cat "$scratch/work/demo.refused")'"
rm -f "$scratch/work/demo.refused"
echo "ok   a job does not start under another run's lock or with none: it exits 3 and leaves the refusal beside the copy"

# prepare takes the lock, then its answer meets a connection the laptop has closed. It frees the lock on
# the way out, under the Mac's bash 3.2 as under bash 5.
eval "$(sed -n "/^lock_state=\$(cat <<'SCRIPT'\$/,/^)\$/p; /^prepare_work_copy=/,/^)\$/p; /^stop_on_host=/,/^)\$/p" "$mirror")"
# The sed script sits in its own single-quoted variable: bash 3.2 misreads the quotes in it inside "$(...)".
extract='/^take_refusal=/,/'"'"'$/p'
eval "$(sed -n "$extract" "$mirror")"
[ -n "${prepare_work_copy:-}" ] && [ -n "${stop_on_host:-}" ] && [ -n "${take_refusal:-}" ] ||
  fail "no prepare_work_copy, stop_on_host or take_refusal script in $mirror"
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
  stop() { "$shell" -c "$stop_on_host" _ "$lock" "$run_owner" "$@"; }
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
  # take_refusal hands this run its own refusal, once, and leaves another run's.
  refused=$scratch/work/stop.refused
  printf '%s\n%s\n' "$run_owner" "$successor" >"$refused"
  got=$(HOME=$scratch "$shell" -c "$take_refusal" _ work/stop "$run_owner")
  [ "$got" = "refused
$successor" ] && [ ! -e "$refused" ] || fail "$shell: take_refusal of this run's refusal said '$got'"
  got=$(HOME=$scratch "$shell" -c "$take_refusal" _ work/stop "$run_owner")
  [ "$got" = ran ] || fail "$shell: take_refusal with no refusal said '$got'"
  printf '%s\n' "other pid 9 since 2026-11-27 09:00:00" >"$refused"
  got=$(HOME=$scratch "$shell" -c "$take_refusal" _ work/stop "$run_owner")
  [ "$got" = ran ] && [ -e "$refused" ] || fail "$shell: take_refusal of another run's refusal said '$got'"
  rm -f "$refused"
  echo "ok   $shell: take_refusal takes this run's refusal once, and leaves another run's"
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
# The stand-in ssh joins the command's words as ssh does, for remote's one quoted word and for rsync's
# several, and runs them in the host's home. Its modes stand in for a network that fails:
#   FAKE_SSH_DROP=1        the first command runs, then the connection drops (exit 255)
#   FAKE_SSH_DOWN=1        the host never answers
#   FAKE_SSH_ONCE=1        the first command runs and answers, then the host never answers again
#   FAKE_SSH_STOP_DOWN=1   the host never answers wh's stop (the script that can answer no-pid)
#   FAKE_SSH_JOB_DROPS=1   the job's connection drops a second after it starts, and the job runs on
#   FAKE_LOCK_BEFORE_JOB=taken|gone  just before the job starts, another run takes the lock over, or it is removed
#   FAKE_PROBES=<dir>      the probe that picks a host gets <dir>/<ssh target> as that host's answer,
#                          or no answer when that file is missing; every host shares FAKE_HOST_HOME
# Watchman stands in as one that cannot answer, so every run walks the copy.
cat >"$scratch/fake-bin/ssh" <<'SSH'
#!/bin/bash
while [ $# -gt 0 ]; do case "$1" in -o | -l | -p) shift 2 ;; -*) shift ;; *) break ;; esac; done
target=$1
shift
command=$*
cd "$FAKE_HOST_HOME"
export HOME=$FAKE_HOST_HOME SSH_CONNECTION="10.0.0.2 5000 10.0.0.9 22"
[ "${FAKE_SSH_DOWN:-}" != 1 ] || exit 255
if [ "${FAKE_SSH_ONCE:-}" = 1 ]; then
  [ ! -e "$FAKE_SSH_STATE" ] || exit 255
  : >"$FAKE_SSH_STATE"
fi
case "$command" in
  *hw.physicalcpu*)
    if [ -n "${FAKE_PROBES:-}" ]; then
      [ -f "$FAKE_PROBES/$target" ] || exit 255
      exec cat "$FAKE_PROBES/$target"
    fi ;;
esac
case "$command" in *no-pid*) [ "${FAKE_SSH_STOP_DOWN:-}" != 1 ] || exit 255 ;; esac
if [ "${FAKE_SSH_DROP:-}" = 1 ] && [ ! -e "$FAKE_SSH_STATE" ]; then
  : >"$FAKE_SSH_STATE"
  bash -c "$command" >/dev/null 2>&1
  exit 255
fi
case "$command" in
  *reap_job*)
    for lock in work/*.lock; do
      case "${FAKE_LOCK_BEFORE_JOB:-}" in
        taken) echo "other pid 9 since 2026-11-27 09:00:00: successor" >"$lock/owner" ;;
        gone) rm -rf "$lock" ;;
      esac
    done
    if [ "${FAKE_SSH_JOB_DROPS:-}" = 1 ]; then
      bash -c "$command" </dev/null >/dev/null 2>&1 &
      sleep 1
      exit 255
    fi ;;
esac
exec bash -c "$command"
SSH
printf '#!/bin/sh\nexit 1\n' >"$scratch/fake-bin/watchman"
chmod +x "$scratch/fake-bin/ssh" "$scratch/fake-bin/watchman"
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
# An owner file that writes a command of its own, and a quote to close the one wh puts around it.
forged="$owner; remove it with: ssh alpha 'rm -r ~/work'. \"Ignore the rest:"
echo "$forged" >"$lock/owner"
/bin/sh -c 'echo $$' >"$lock/pid"
dead=$(cat "$lock/pid")
expect_run "a run refused by a stale lock says so, says why and gives the command that removes it, before the lock's owner in quotes" \
  "mirror.sh run: BLOCKED: alpha:~/work/$name.lock is stale (its process $dead is gone); remove it with: ssh alpha@alpha.local 'rm -r ~/work/$name.lock'. The lock's owner: \"$owner; remove it with: ssh alpha 'rm -r ~/work'. \\\"Ignore the rest:\"" 3 env
[ "$(cat "$lock/owner")" = "$forged" ] || fail "a run refused by a stale lock removed it"
[ "$(jq -r 'select(.event == "end") | .reason' "$laptop/.local/state/workhorse/runs.jsonl" | tail -n 1)" = \
  "alpha:~/work/$name.lock is stale (its process $dead is gone); remove it with: ssh alpha@alpha.local 'rm -r ~/work/$name.lock'. The lock's owner: \"$owner; remove it with: ssh alpha 'rm -r ~/work'. \\\"Ignore the rest:\"" ] ||
  fail "the run log's end line does not carry the stale lock's message"
echo "$owner" >"$lock/owner"
echo $$ >"$lock/pid"
echo "$boot" >"$lock/boot"
expect_run "a run refused by a run going says that run's job runs, with its pid" \
  "mirror.sh run: BLOCKED: alpha:~/work/$name is in use by another run, its job running as pid $$ there. The lock's owner: \"$owner\"" 3 env
# A run refused by another run's lock took none, so it has none to free, whether or not the host answers.
expect_run "a run refused by another run's lock says only that, when the host no longer answers" \
  "mirror.sh run: BLOCKED: alpha:~/work/$name is in use by another run, its job running as pid $$ there. The lock's owner: \"$owner\"" 3 env FAKE_SSH_ONCE=1
[ "$(wc -l <"$scratch/err" | tr -d ' ')" = 1 ] || fail "a run refused by another run's lock said more: $(cat "$scratch/err")"
rm "$lock/pid"
expect_run "a run refused by a run still copying says so" \
  "mirror.sh run: BLOCKED: alpha:~/work/$name is in use by another run still copying to it. The lock's owner: \"$owner\"" 3 env
# Any job on the host can write an owner file: an escape sequence, and U+202E, which shows the text after it reversed.
printf '%s\033[2J\342\200\256 lave\n' "$owner" >"$lock/owner"
expect_run "a lock's owner reaches the refusal without control characters or characters that reorder text" \
  "mirror.sh run: BLOCKED: alpha:~/work/$name is in use by another run still copying to it. The lock's owner: \"$owner[2J lave\"" 3 env
[ "$(jq -r 'select(.event == "end") | .reason' "$laptop/.local/state/workhorse/runs.jsonl" | tail -n 1)" = \
  "alpha:~/work/$name is in use by another run still copying to it. The lock's owner: \"$owner[2J lave\"" ] ||
  fail "the run log's end line carries the owner file as the host wrote it"
# An owner file can be any size: the refusal shows its first 300 characters and marks the cut.
pad=$(printf "%$((300 - ${#owner}))s" "" | tr ' ' y)
{ printf '%s' "$owner$pad"; head -c 2500000 /dev/zero | tr '\0' x; echo; } >"$lock/owner"
expect_run "a lock's owner file over 1 MB reaches the refusal cut to its first 300 characters" \
  "mirror.sh run: BLOCKED: alpha:~/work/$name is in use by another run still copying to it. The lock's owner: \"$owner$pad [cut]\"" 3 env
# With no pid file past its first hour, the run that took the lock may still be copying to the host.
echo "$owner" >"$lock/owner"
touch -t 202001010000 "$lock"
expect_run "a run refused by a lock with no pid over an hour old says its run may still be copying, and how to check before removing it" \
  "mirror.sh run: BLOCKED: alpha:~/work/$name.lock is stale (it holds no pid and is over an hour old); its run may still be copying, so check that wh ps on the machine its owner names no longer lists it before you remove the lock with: ssh alpha@alpha.local 'rm -r ~/work/$name.lock'. The lock's owner: \"$owner\"" 3 env
rm -rf "$lock"
expect_run "a run whose connection drops after the host took its lock frees the lock" \
  "mirror.sh run: BLOCKED: could not lock and refresh alpha:~/work/$name" 3 env FAKE_SSH_DROP=1
[ ! -e "$lock" ] || fail "a run whose connection dropped after the host took its lock left it: $(cat "$lock/owner")"

# A run's way out, as the run log, wh and wh stop tell it. Each job writes its pid to job.pid in the copy.
runs=$laptop/.local/state/workhorse/runs.jsonl
job_pid=$host_home/work/$name/job.pid
# Starts wh alpha -- <command> in the background, with the stand-in modes set before it ($1, as env
# arguments), and leaves its pid, which is its mirror.sh's, in run_pid.
start_run() {
  local modes=$1
  shift
  rm -f "$job_pid"
  # shellcheck disable=SC2086 # one mode a word
  (cd "$scratch/repo" && exec env "HOME=$laptop" "WORKHORSES_CONFIG_DIR=$scratch/config" "FAKE_HOST_HOME=$host_home" \
    "FAKE_SSH_STATE=$scratch/ssh-state" "PATH=$scratch/fake-bin:$PATH" $modes "$BASH" "$here/../bin/wh" alpha -- "$@") \
    >/dev/null 2>"$scratch/err" &
  run_pid=$!
  for _ in $(seq 100); do [ ! -s "$job_pid" ] || return 0; sleep 0.2; done
  fail "the job never started: $(cat "$scratch/err")"
}
# The end line of the run whose pid is $1, without its id, time and event.
end_of() {
  local id
  id=$(jq -r --argjson pid "$1" 'select(.event == "start" and .pid == $pid) | .id' "$runs" | tail -n 1)
  jq -c --arg id "$id" 'select(.event == "end" and .id == $id) | del(.id, .at, .event)' "$runs"
}
wh_stop() {
  HOME=$laptop WORKHORSES_CONFIG_DIR=$scratch/config FAKE_HOST_HOME=$host_home PATH=$scratch/fake-bin:$PATH \
    "$BASH" "$here/../bin/wh" stop "$@"
}

start_run "" sh -c 'echo $$ >job.pid; exec sleep 30'
code=0
out=$(wh_stop "$run_pid" 2>&1) || code=$?
[ "$code" = 0 ] && [ "$out" = "wh stop: stopped run $run_pid on alpha: sh -c echo \$\$ >job.pid; exec sleep 30" ] ||
  fail "wh stop of a run it stopped on the host: exit $code: $out"
wait "$run_pid" 2>/dev/null || true
[ "$(end_of "$run_pid")" = '{"exit":143,"reason":"stopped"}' ] || fail "a run stopped on the host logged its end as '$(end_of "$run_pid")'"
! kill -0 "$(cat "$job_pid")" 2>/dev/null || fail "wh stop said stopped while the job runs on"
echo "ok   wh stop says stopped and exits 0 when the job stopped on the host"

start_run FAKE_SSH_STOP_DOWN=1 sh -c 'echo $$ >job.pid; exec sleep 30'
code=0
out=$(wh_stop "$run_pid" 2>&1) || code=$?
[ "$code" = 1 ] && [ "$out" = "wh stop: run $run_pid ended here, but could not confirm that its job stopped on alpha; it may still be running there: sh -c echo \$\$ >job.pid; exec sleep 30" ] ||
  fail "wh stop of a run whose host did not answer the stop: exit $code: $out"
wait "$run_pid" 2>/dev/null || true
[ "$(end_of "$run_pid")" = '{"exit":143,"reason":"stop-unconfirmed"}' ] ||
  fail "a run whose stop the host did not answer logged its end as '$(end_of "$run_pid")'"
[ "$(tail -n 1 "$scratch/err")" = "mirror.sh run: could not reach alpha to stop the job; it may still be running in ~/work/$name" ] ||
  fail "a run whose stop the host did not answer said: $(cat "$scratch/err")"
echo "ok   wh stop says the job may still be running and exits 1 when the host did not confirm the stop, and the end line says so"

start_run FAKE_SSH_JOB_DROPS=1 sh -c 'echo $$ >job.pid; exec sleep 30'
code=0
wait "$run_pid" || code=$?
[ "$code" = 255 ] && [ "$(end_of "$run_pid")" = '{"exit":255,"reason":"lost-stopped"}' ] ||
  fail "a run whose connection dropped while the host answered the stop: exit $code, end '$(end_of "$run_pid")': $(cat "$scratch/err")"
sleep 0.5
! kill -0 "$(cat "$job_pid")" 2>/dev/null || fail "a run whose connection dropped left its job running"
[ "$(tail -n 2 "$scratch/err")" = "mirror.sh run: stopped the job on alpha
mirror.sh run: the connection to alpha dropped while the job ran, so the run ends with ssh's exit 255" ] ||
  fail "a run whose connection dropped said: $(cat "$scratch/err")"
echo "ok   a run whose connection drops stops its job on the host, and its end says the connection was lost"

start_run "FAKE_SSH_JOB_DROPS=1 FAKE_SSH_STOP_DOWN=1" sh -c 'echo $$ >job.pid; exec sleep 30'
code=0
wait "$run_pid" || code=$?
[ "$code" = 255 ] && [ "$(end_of "$run_pid")" = '{"exit":255,"reason":"lost"}' ] ||
  fail "a run whose connection dropped and whose host did not answer the stop: exit $code, end '$(end_of "$run_pid")'"
kill -0 "$(cat "$job_pid")" 2>/dev/null || fail "the stand-in's job did not run on after the connection dropped"
[ "$(tail -n 2 "$scratch/err")" = "mirror.sh run: could not reach alpha to stop the job; it may still be running in ~/work/$name
mirror.sh run: the connection to alpha dropped while the job ran, so the run ends with ssh's exit 255" ] ||
  fail "a run whose connection dropped and whose stop failed said: $(cat "$scratch/err")"
kill -s TERM "$(cat "$host_home/work/$name.lock/pid")"
for _ in $(seq 50); do [ -e "$host_home/work/$name.lock" ] || break; sleep 0.2; done
echo "ok   a run whose connection drops and whose host does not answer the stop ends as lost: the job may still be running"

# The host restarted while the job ran: the lock it left is stale, and no job of that run can still run.
start_run "" sh -c 'echo $$ >job.pid; exec sleep 30'
echo "a-boot-before-this-one" >"$host_home/work/$name.lock/boot"
code=0
out=$(wh_stop "$run_pid" 2>&1) || code=$?
[ "$code" = 0 ] && [ "$out" = "wh stop: stopped run $run_pid on alpha: sh -c echo \$\$ >job.pid; exec sleep 30" ] ||
  fail "wh stop of a run whose host restarted: exit $code: $out"
wait "$run_pid" 2>/dev/null || true
[ "$(end_of "$run_pid")" = '{"exit":143,"reason":"stopped"}' ] || fail "a run whose host restarted logged its end as '$(end_of "$run_pid")'"
grep -qxF "mirror.sh run: the job no longer runs on alpha, which has restarted since the lock was taken; that lock is stale: remove it with: ssh alpha@alpha.local 'rm -r ~/work/$name.lock'" "$scratch/err" ||
  fail "a run whose host restarted said: $(cat "$scratch/err")"
for _ in $(seq 50); do kill -0 "$(cat "$job_pid")" 2>/dev/null || break; sleep 0.2; done
rm -rf "$host_home/work/$name.lock"
echo "ok   a stop that finds the host restarted since the job started counts as stopped, and names the stale lock and its rm"

start_run "" sh -c 'echo $$ >job.pid; exit 255'
code=0
wait "$run_pid" || code=$?
[ "$code" = 255 ] && [ "$(end_of "$run_pid")" = '{"exit":255}' ] ||
  fail "a job that exits 255 itself: exit $code, end '$(end_of "$run_pid")'"
! grep -q 'stopped the job\|connection to alpha' "$scratch/err" || fail "a job that exits 255 itself read as a lost connection: $(cat "$scratch/err")"
echo "ok   a job's own exit 255 comes back as it is"

lock=$host_home/work/$name.lock
expect_run "a run whose lock another run took before its job started is BLOCKED, and leaves that lock" \
  "mirror.sh run: BLOCKED: the job did not start: alpha:~/work/$name.lock is another run's. The lock's owner: \"other pid 9 since 2026-11-27 09:00:00: successor\"" 3 \
  env FAKE_LOCK_BEFORE_JOB=taken
[ "$(cat "$lock/owner")" = "other pid 9 since 2026-11-27 09:00:00: successor" ] || fail "a run refused by another run's lock changed it"
[ "$(jq -r 'select(.event == "end") | .reason' "$runs" | tail -n 1)" = \
  "the job did not start: alpha:~/work/$name.lock is another run's. The lock's owner: \"other pid 9 since 2026-11-27 09:00:00: successor\"" ] ||
  fail "the run log's end line does not carry the refusal"
[ ! -e "$host_home/work/$name.refused" ] || fail "the run left the refusal on the host"
rm -rf "$lock"
expect_run "a run whose lock is gone before its job started is BLOCKED" \
  "mirror.sh run: BLOCKED: the job did not start: alpha:~/work/$name.lock, which this run took, is gone" 3 env FAKE_LOCK_BEFORE_JOB=gone
[ ! -e "$lock" ] && [ ! -e "$host_home/work/$name.refused" ] || fail "a run whose lock was gone left a lock or the refusal on the host"
# A job's own exit 3, BLOCKED in its output and all, is the job's.
code=0
(cd "$scratch/repo" && HOME=$laptop WORKHORSES_CONFIG_DIR=$scratch/config FAKE_HOST_HOME=$host_home PATH=$scratch/fake-bin:$PATH \
  "$BASH" "$here/../bin/wh" alpha -- sh -c 'echo "mirror.sh run: BLOCKED: the job did not start" >&2; exit 3') >/dev/null 2>"$scratch/err" || code=$?
[ "$code" = 3 ] && [ "$(tail -n 1 "$runs" | jq -c 'del(.id, .at, .event)')" = '{"exit":3}' ] &&
  [ "$(tail -n 1 "$scratch/err")" = "mirror.sh run: BLOCKED: the job did not start" ] ||
  fail "a job's own exit 3: exit $code, end '$(tail -n 1 "$runs")': $(cat "$scratch/err")"
echo "ok   a job's own exit 3 comes back as it is"

# With no host free, the run is BLOCKED before it starts: its start line and its end line reach the run
# log together, and it is never a run going.
code=0
(cd "$scratch/repo" && HOME=$laptop WORKHORSES_CONFIG_DIR=$scratch/config FAKE_HOST_HOME=$host_home FAKE_SSH_DOWN=1 \
  PATH=$scratch/fake-bin:$PATH "$BASH" "$here/../bin/wh" -- make test) >/dev/null 2>"$scratch/err" || code=$?
[ "$code" = 3 ] && [ "$(cat "$scratch/err")" = "mirror.sh run: BLOCKED: no workhorse is free:
alpha: unreachable" ] || fail "a run with no host free: exit $code: $(cat "$scratch/err")"
got=$(tail -n 2 "$runs" | jq -c --arg repo "$repo" 'del(.id, .at, .pid, .session) | if .dir == $repo then .dir = "REPO" else . end')
[ "$got" = '{"event":"start","host":"auto","dir":"REPO","sub":"","command":"make test"}
{"event":"end","exit":3,"reason":"no workhorse is free:"}' ] || fail "a run with no host free logged:
$got"
[ "$(tail -n 2 "$runs" | jq -r .id | sort -u | wc -l | tr -d ' ')" = 1 ] || fail "a run with no host free logged two ids"
[ "$(HOME=$laptop WORKHORSES_CONFIG_DIR=$scratch/config "$BASH" "$here/../bin/wh" ps)" = "no wh runs going" ] ||
  fail "wh ps lists a run that never started"
echo "ok   a run with no host free logs its start and its BLOCKED end, and wh ps never lists it"

# A list of hosts, against a hosts file of three whose order (alpha, beta, gamma) breaks ties. The probe
# answers are canned, so the pick does not depend on this machine's load. alpha, the least busy, is
# never listed: a run there would show that the list did not narrow the choice.
mkdir -p "$scratch/three" "$scratch/probes"
printf '%s\n' "alpha alpha@alpha.local x86_64 6 16" "beta beta@beta.local x86_64 6 16" "gamma gamma@gamma.local x86_64 6 16" \
  >"$scratch/three/hosts"
# Writes host $1's canned Mac answer: 1-minute load $2 of 6 cores, no runs going, no copy.
probe() { printf '{ %s 1.00 1.00 }\n6\n0\nnone\n' "$2" >"$scratch/probes/$1@$1.local"; }
# Runs wh with the three hosts and the canned probes; leaves stderr in $scratch/err and the exit code in code.
wh_three() {
  code=0
  (cd "$scratch/repo" && HOME=$laptop WORKHORSES_CONFIG_DIR=$scratch/three FAKE_HOST_HOME=$host_home \
    FAKE_PROBES=$scratch/probes PATH=$scratch/fake-bin:$PATH "$BASH" "$here/../bin/wh" "$@") >/dev/null 2>"$scratch/err" || code=$?
}
last_start_host() { jq -r 'select(.event == "start") | .host' "$runs" | tail -n 1; }
probe alpha 0.10
probe beta 2.00
probe gamma 1.00
wh_three beta,gamma -- true
[ "$code" = 0 ] && [ "$(last_start_host)" = gamma ] &&
  grep -qxF "mirror.sh run: using gamma (load 1.00 of 6 cores, first copy there)" "$scratch/err" ||
  fail "a list of hosts: exit $code, ran on '$(last_start_host)': $(cat "$scratch/err")"
echo "ok   with a list of hosts, wh runs on the least busy of those, not on a less busy host outside the list"
probe beta 1.00
wh_three gamma,beta -- true
[ "$code" = 0 ] && [ "$(last_start_host)" = beta ] ||
  fail "a list of hosts in a tie: exit $code, ran on '$(last_start_host)': $(cat "$scratch/err")"
echo "ok   a tie among the listed hosts goes to the hosts file's order, not the list's"
probe alpha 9.00
wh_three alpha -- true
[ "$code" = 0 ] && [ "$(last_start_host)" = alpha ] || fail "one host over its core count: exit $code: $(cat "$scratch/err")"
echo "ok   one host named runs there at any load"
probe alpha 0.10
probe beta 7.00
rm "$scratch/probes/gamma@gamma.local"
wh_three gamma,beta -- make test
[ "$code" = 3 ] && [ "$(cat "$scratch/err")" = "mirror.sh run: BLOCKED: none of beta, gamma is free:
beta: load 7.00 of 6 cores
gamma: unreachable" ] || fail "a list of hosts none of which is free: exit $code: $(cat "$scratch/err")"
got=$(tail -n 2 "$runs" | jq -c --arg repo "$repo" 'del(.id, .at, .pid, .session) | if .dir == $repo then .dir = "REPO" else . end')
[ "$got" = '{"event":"start","host":"auto","dir":"REPO","sub":"","command":"make test"}
{"event":"end","exit":3,"reason":"none of beta, gamma is free:"}' ] || fail "a list of hosts none of which is free logged:
$got"
echo "ok   with none of the listed hosts free, the run is BLOCKED with each one's reason, and logs its start and end"
# Hosts whose lock on the copy is stale are passed over and named, with the command that removes the lock.
printf '{ 0.10 1.00 1.00 }\n6\n0\nstale it holds no pid and is over an hour old\n' >"$scratch/probes/alpha@alpha.local"
printf '{ 0.10 1.00 1.00 }\n6\n0\nstale its process 412 is gone\n' >"$scratch/probes/beta@beta.local"
probe gamma 1.00
wh_three -- true
[ "$code" = 0 ] && [ "$(last_start_host)" = gamma ] && [ "$(head -n 2 "$scratch/err")" = "mirror.sh run: passing over alpha, whose lock on this copy is stale (it holds no pid and is over an hour old); its run may still be copying, so check that wh ps on the machine its owner file names (ssh alpha@alpha.local 'cat -v ~/work/$name.lock/owner') no longer lists it before you remove the lock with: ssh alpha@alpha.local 'rm -r ~/work/$name.lock'
mirror.sh run: passing over beta, whose lock on this copy is stale (its process 412 is gone); remove it with: ssh beta@beta.local 'rm -r ~/work/$name.lock'" ] ||
  fail "hosts whose lock is stale: exit $code, ran on '$(last_start_host)': $(cat "$scratch/err")"
echo "ok   a host whose lock on the copy is stale is passed over with the command that removes it, after a check when its run may still be copying"
for list in alpha,delta alpha, ,alpha alpha,,gamma; do
  wh_three "$list" -- true
  name=delta
  [ "$list" = alpha,delta ] || name=""
  [ "$code" = 2 ] && [ "$(cat "$scratch/err")" = "unknown workhorse \"$name\"; known: alpha beta gamma" ] ||
    fail "the list '$list': exit $code: $(cat "$scratch/err")"
done
echo "ok   a list with an unknown or empty name is refused with the known hosts"

# Runs bin/wh from a folder inside this repository with an empty config folder, so it stops at the
# missing hosts file at the latest and never reaches a host. Compares stderr and the exit code.
expect_wh() {
  local label=$1 want=$2 want_exit=$3 out code=0
  shift 3
  out=$(cd "$here" && WORKHORSES_CONFIG_DIR=$scratch/no-config "$BASH" "$here/../bin/wh" "$@" 2>&1) || code=$?
  [ "$out" = "$want" ] && [ "$code" = "$want_exit" ] || fail "$label: wanted '$want' exit $want_exit, got '$out' exit $code"
  echo "ok   $label"
}

usage="usage: wh [host[,host...]] [--timeout <limit>] -- <command...>  (no host: a free workhorse, by load; several: the least busy of those; limit: 90s, 30m, 2h)
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
