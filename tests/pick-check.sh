#!/bin/bash
# ABOUTME: Checks which workhorse mirror.sh's choose_host picks from given probe answers; no host is contacted.
# ABOUTME: Usage: tests/pick-check.sh; exits 1 on the first wrong choice.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
# bash 3.2 cannot source a process substitution, so the function's text is evaluated.
mirror=$here/../scripts/mirror.sh
eval "$(sed -n '/^probe_answer() {$/,/^}$/p; /^choose_host() {$/,/^}$/p' "$mirror")"
declare -F choose_host >/dev/null || { echo "FAIL: no choose_host function in $mirror" >&2; exit 1; }
declare -F probe_answer >/dev/null || { echo "FAIL: no probe_answer function in $mirror" >&2; exit 1; }

# Feeds one host's raw probe answer to probe_answer and compares the line it prints for choose_host.
expect_answer() {
  local label=$1 want=$2 out
  shift 2
  out=$(probe_answer "$@")
  if [ "$out" != "$want" ]; then
    echo "FAIL $label: wanted '$want', got '$out'" >&2
    exit 1
  fi
  echo "ok   $label"
}

# pick_host joins each answer's lines with spaces, so every answer ends in one.
expect_answer "a Mac's answer gives its 1-minute load, physical cores and runs going" "gamma ok 1.39 6 2 copy" \
  gamma 0 "{ 1.39 1.37 1.32 } 6 2 copy "
expect_answer "a Linux host's answer gives the 1-minute load of /proc/loadavg, physical cores and runs going" "delta ok 0.52 6 0 none" \
  delta 0 "0.52 0.40 0.30 1/215 1245 6 0 none "
expect_answer "a Linux host that counts no cores, as when lscpu is missing, is unexpected" \
  "delta unexpected 0.52 0.40 0.30 1/215 1245 0 0 none " delta 0 "0.52 0.40 0.30 1/215 1245 0 0 none "
expect_answer "a host whose copy another run holds says busy" "gamma ok 1.39 6 1 busy" \
  gamma 0 "{ 1.39 1.37 1.32 } 6 1 busy "
expect_answer "a host whose copy's lock is stale says stale and why" "gamma ok 1.39 6 0 stale its process 412 is gone" \
  gamma 0 "{ 1.39 1.37 1.32 } 6 0 stale its process 412 is gone "
expect_answer "stale without a reason is unexpected" "gamma unexpected { 1.39 1.37 1.32 } 6 0 stale " \
  gamma 0 "{ 1.39 1.37 1.32 } 6 0 stale "
expect_answer "words after busy are unexpected" "gamma unexpected { 1.39 1.37 1.32 } 6 1 busy now " \
  gamma 0 "{ 1.39 1.37 1.32 } 6 1 busy now "
expect_answer "a count of runs going that is not a number is unexpected" \
  "gamma unexpected { 1.39 1.37 1.32 } 6 x copy " gamma 0 "{ 1.39 1.37 1.32 } 6 x copy "
expect_answer "a host whose ssh failed is unreachable" "beta unreachable" beta 255 ""
expect_answer "an answer of another shape is unexpected" "beta unexpected Linux 12 none " beta 0 "Linux 12 none "

# Feeds probe lines to choose_host and compares what it prints on stdout and stderr, and its exit code.
expect() {
  local label=$1 want_out=$2 want_err=$3 want_exit=$4 probes=$5 out err code
  err=$(mktemp)
  set +e
  out=$(choose_host <<<"$probes" 2>"$err")
  code=$?
  set -e
  if [ "$out" != "$want_out" ] || [ "$(cat "$err")" != "$want_err" ] || [ "$code" != "$want_exit" ]; then
    echo "FAIL $label: wanted '$want_out' / '$want_err' exit $want_exit, got '$out' / '$(cat "$err")' exit $code" >&2
    rm -f "$err"
    exit 1
  fi
  rm -f "$err"
  echo "ok   $label"
}

# The hosts are listed against alphabetical order (gamma, beta, alpha), so a pick that went by name
# instead of by the table would show.
expect "a host at its core count is refused" beta "" 0 "gamma ok 6.00 6 0 copy
beta ok 5.99 6 0 none"

expect "a lightly loaded host with the repo's copy beats a less loaded one without it" beta "" 0 "gamma ok 0.10 6 0 none
beta ok 2.00 6 0 copy
alpha ok 0.50 10 0 none"

expect "a host with the copy at half its cores or more loses to the least loaded host" gamma "" 0 "gamma ok 0.10 6 0 none
beta ok 3.00 6 0 copy
alpha ok 1.50 10 0 none"

expect "runs going count as load the 1-minute average has not caught up with" alpha "" 0 "gamma ok 0.10 6 3 none
alpha ok 1.00 10 0 none"

expect "runs going take away the pull of the copy" gamma "" 0 "gamma ok 0.50 6 0 none
beta ok 0.10 6 3 copy"

expect "a host whose copy another run holds is passed over, since the run would find it locked" alpha "" 0 "gamma ok 0.10 6 1 busy
alpha ok 4.00 10 0 none"

expect "load is compared per core, not raw" alpha "" 0 "gamma ok 2.00 6 0 none
alpha ok 3.00 10 0 none"

expect "a tie goes to table order" gamma "" 0 "gamma ok 1.00 6 0 copy
beta ok 1.00 6 0 copy"

expect "numbers compare as numbers" alpha "" 0 "gamma ok 10.50 6 0 copy
alpha ok 9.00 10 0 none"

expect "unreachable and unexpected hosts are passed over" alpha "" 0 "gamma unreachable
beta unexpected { 1.0 } six
alpha ok 1.00 10 0 none"

expect "a host whose copy's lock is stale is passed over, and the reason says why" alpha "" 0 "gamma ok 0.10 6 0 stale its process 412 is gone
alpha ok 4.00 10 0 none"

expect "with none free, every host's reason is given" "" "gamma: load 7.00 of 6 cores
beta: unexpected { 1.0 } six
alpha: unreachable
delta: another run holds its copy
eta: its copy's lock is stale: the host has restarted since the lock was taken" 1 "gamma ok 7.00 6 0 copy
beta unexpected { 1.0 } six
alpha unreachable
delta ok 0.10 6 1 busy
eta ok 0.10 6 0 stale the host has restarted since the lock was taken"

# The host side, run in a scratch home under the shells hosts have: the login shell (bash, or zsh on a
# Mac) runs the probe. A lock is a run going while its pid file names a live process and its boot file,
# when it has one, names this boot; or, with no pid file, while it is under an hour old. Every other lock
# is stale. This boot's id comes from the system here, not from mirror.sh.
# The sed script sits in its own single-quoted variable: bash 3.2 misreads the quotes in it inside "$(...)".
extract='/^lock_state=$(cat <<'"'"'SCRIPT'"'"'$/,/^)$/p; /^count_runs=/p; /^copy_probe() {$/,/^}$/p'
eval "$(sed -n "$extract" "$mirror")"
[ -n "${count_runs:-}" ] || { echo "FAIL: no count_runs in $mirror" >&2; exit 1; }
declare -F copy_probe >/dev/null || { echo "FAIL: no copy_probe function in $mirror" >&2; exit 1; }
if [ "$(uname -s)" = Darwin ]; then boot=$(/usr/sbin/sysctl -n kern.bootsessionuuid); else boot=$(cat /proc/sys/kernel/random/boot_id); fi
home=$(mktemp -d)
mkdir -p "$home/work/live.lock" "$home/work/dead.lock" "$home/work/copying.lock" "$home/work/abandoned.lock" "$home/work/repo" \
  "$home/work/thisboot.lock" "$home/work/rebooted.lock" "$home/work/nonsense.lock"
echo $$ >"$home/work/live.lock/pid"
/bin/sh -c 'echo $$' >"$home/work/dead.lock/pid"
touch -t 202001010000 "$home/work/abandoned.lock"
echo $$ >"$home/work/thisboot.lock/pid"
echo "$boot" >"$home/work/thisboot.lock/boot"
# A pid used again after a restart: the process lives, but it is not the run's.
echo $$ >"$home/work/rebooted.lock/pid"
echo "a-boot-before-this-one" >"$home/work/rebooted.lock/boot"
# kill -0 -1 would succeed: it asks about every process.
echo -1 >"$home/work/nonsense.lock/pid"
for shell in bash zsh; do
  command -v "$shell" >/dev/null || continue
  got=$(HOME=$home "$shell" -c "$count_runs")
  if [ "$got" != 3 ]; then
    echo "FAIL $shell counts runs going: wanted 3 (a lock whose pid lives with no boot file, one whose pid lives in this boot, and one still copying under an hour old), got '$got'" >&2
    rm -rf "$home"
    exit 1
  fi
  echo "ok   $shell counts a lock whose run lives in this boot and one still copying, not a stale one"
done

# The probe's last line: whether the host holds the copy, and whether a run holds its lock.
dead=$(cat "$home/work/dead.lock/pid")
for shell in bash zsh; do
  command -v "$shell" >/dev/null || continue
  for case in "repo|copy" "absent|none" "live|busy" "copying|busy" "thisboot|busy" "dead|stale its process $dead is gone" \
    "abandoned|stale it holds no pid and is over an hour old" "rebooted|stale the host has restarted since the lock was taken" \
    "nonsense|stale its pid file holds no process id"; do
    name=${case%%|*} want=${case#*|}
    got=$(HOME=$home "$shell" -c "$lock_state"$'\n'"$(copy_probe "work/$name")")
    if [ "$got" != "$want" ]; then
      echo "FAIL $shell probes the copy work/$name: wanted '$want', got '$got'" >&2
      rm -rf "$home"
      exit 1
    fi
  done
  echo "ok   $shell probes a copy as none, copy, busy for a run going, or stale with the reason"
done
rm -rf "$home"

echo "all host choices are right"
