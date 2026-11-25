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

expect "with none free, every host's reason is given" "" "gamma: load 7.00 of 6 cores
beta: unexpected { 1.0 } six
alpha: unreachable
delta: another run holds its copy" 1 "gamma ok 7.00 6 0 copy
beta unexpected { 1.0 } six
alpha unreachable
delta ok 0.10 6 1 busy"

echo "all host choices are right"
