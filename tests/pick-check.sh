#!/bin/bash
# ABOUTME: Checks which workhorse mirror.sh's choose_host picks from given probe answers; no host is contacted.
# ABOUTME: Usage: tests/pick-check.sh; exits 1 on the first wrong choice.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
# bash 3.2 cannot source a process substitution, so the function's text is evaluated.
mirror=$here/../scripts/mirror.sh
eval "$(sed -n '/^choose_host() {$/,/^}$/p' "$mirror")"
declare -F choose_host >/dev/null || { echo "FAIL: no choose_host function in $mirror" >&2; exit 1; }

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
expect "a host at its core count is refused" beta "" 0 "gamma ok 6.00 6 copy
beta ok 5.99 6 none"

expect "a free host with the repo's copy beats a less loaded one without it" beta "" 0 "gamma ok 0.10 6 none
beta ok 4.00 6 copy
alpha ok 0.50 10 none"

expect "load is compared per core, not raw" alpha "" 0 "gamma ok 2.00 6 none
alpha ok 3.00 10 none"

expect "a tie goes to table order" gamma "" 0 "gamma ok 3.00 6 copy
beta ok 3.00 6 copy"

expect "numbers compare as numbers" alpha "" 0 "gamma ok 10.50 6 copy
alpha ok 9.00 10 none"

expect "unreachable and unexpected hosts are passed over" alpha "" 0 "gamma unreachable
beta unexpected { 1.0 } six
alpha ok 1.00 10 none"

expect "with none free, every host's reason is given" "" "gamma: load 7.00 of 6 cores
beta: unexpected { 1.0 } six
alpha: unreachable" 1 "gamma ok 7.00 6 copy
beta unexpected { 1.0 } six
alpha unreachable"

echo "all host choices are right"
