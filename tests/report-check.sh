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

# The host side: count_runs with list=1 prints a line for each lock of a run going, then the count.
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
  got=$(HOME=$home "$shell" -c "list=1; $count_runs" 2>"$scratch/err")
  # The count comes last; the lock lines before it come in find's order.
  got="$(sed '$d' <<<"$got" | LC_ALL=C sort)"$'\n'"$(tail -n 1 <<<"$got")"
  [ "$got" = "$want" ] || fail "$shell lists runs going: wanted
$want
got
$got"
  [ ! -s "$scratch/err" ] || fail "$shell listing wrote to stderr: $(cat "$scratch/err")"
  echo "ok   $shell lists a live lock with its owner on one line and a young lock without one, not a dead or abandoned lock"
done

echo "wh hosts reports are right"
