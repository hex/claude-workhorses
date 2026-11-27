#!/bin/bash
# ABOUTME: Checks wh stats: the per-host report built from a run log of finished, going, blocked and older runs; no host is contacted.
# ABOUTME: Usage: tests/stats-check.sh; exits 1 on the first wrong line.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/stats-check.XXXX")
trap 'rm -rf "$scratch"' EXIT

fail() { echo "FAIL $*" >&2; exit 1; }

# Runs wh stats with the run log in a scratch home; leaves stdout and stderr in out and the exit code in code.
stats() {
  code=0
  out=$(HOME=$scratch "$BASH" "$here/../bin/wh" stats "$@" 2>&1) || code=$?
}

stats
[ "$code" = 0 ] && [ "$out" = "wh stats: no run log at $scratch/.local/state/workhorse/runs.jsonl" ] ||
  fail "with no run log: exit $code: $out"
echo "ok   with no run log, wh stats says so"

# Times count back from now, so --since 7d keeps every run but the one ten days old.
now=$(date +%s)
day=86400
t=$((now - 3 * day))
old=$((now - 10 * day))
mkdir -p "$scratch/.local/state/workhorse"
log=$scratch/.local/state/workhorse/runs.jsonl
line() { jq -nc "$@" >>"$log"; }
# alpha, picked by load: copied in 2 s by a patch, the job ran 98 s and passed.
line --argjson at $t '{event: "start", id: "r1", at: $at, host: "alpha", pick: "auto", probe: {load: 1.5, cores: 6, runs: 0}}'
line --argjson at $((t + 2)) '{event: "synced", id: "r1", at: $at, copy: "patch", files: 3}'
line --argjson at $((t + 100)) '{event: "end", id: "r1", at: $at, exit: 0}'
# alpha, a line from before wh logged the pick or the copy: copied in 10 s, failed after 10 s.
line --argjson at $((t + 200)) '{event: "start", id: "r2", at: $at, host: "alpha"}'
line --argjson at $((t + 210)) '{event: "synced", id: "r2", at: $at}'
line --argjson at $((t + 220)) '{event: "end", id: "r2", at: $at, exit: 1}'
# alpha, named: another run held the copy, so it never synced.
line --argjson at $((t + 300)) '{event: "start", id: "r3", at: $at, host: "alpha", pick: "named"}'
line --argjson at $((t + 301)) '{event: "end", id: "r3", at: $at, exit: 3, reason: "alpha:~/work/demo is in use by another run"}'
# alpha, named: a walk in 4 s, then the job's own exit 3, which is a failure, not a block.
line --argjson at $((t + 400)) '{event: "start", id: "r4", at: $at, host: "alpha", pick: "named"}'
line --argjson at $((t + 404)) '{event: "synced", id: "r4", at: $at, copy: "walk", why: "Watchman could not answer", files: 0}'
line --argjson at $((t + 405)) '{event: "end", id: "r4", at: $at, exit: 3}'
# beta, from a list: still going, so it is left out.
line --argjson at $((t + 500)) '{event: "start", id: "r5", at: $at, host: "beta", pick: "list", probe: {load: 0.2, cores: 8, runs: 1}}'
line --argjson at $((t + 530)) '{event: "synced", id: "r5", at: $at, copy: "first", files: 9}'
# No host was free: blocked before it started.
line --argjson at $((t + 600)) '{event: "start", id: "r6", at: $at, host: "auto", pick: "auto"}'
line --argjson at $((t + 600)) '{event: "end", id: "r6", at: $at, exit: 3, reason: "no workhorse is free:"}'
# beta, named: patched in 1 s, stopped after 60 s.
line --argjson at $((t + 700)) '{event: "start", id: "r7", at: $at, host: "beta", pick: "named"}'
line --argjson at $((t + 701)) '{event: "synced", id: "r7", at: $at, copy: "patch", files: 1}'
line --argjson at $((t + 761)) '{event: "end", id: "r7", at: $at, exit: 143, reason: "stopped"}'
# gamma, ten days ago: passed after a 5 s copy and a 5 s job.
line --argjson at $old '{event: "start", id: "r8", at: $at, host: "gamma", pick: "named"}'
line --argjson at $((old + 5)) '{event: "synced", id: "r8", at: $at, copy: "patch", files: 2}'
line --argjson at $((old + 10)) '{event: "end", id: "r8", at: $at, exit: 0}'

# Medians and 90th percentiles by nearest rank: alpha's copies took 2, 4 and 10 s, its jobs 1, 10 and 98 s.
row() { printf '%-12s %5s %4s %6s %7s %7s %8s %5s %7s %5s\n' "$@"; }
want="wh stats: 7 finished runs; times in whole seconds, median and 90th percentile
$(row host runs ok failed stopped blocked "copy p50" p90 "job p50" p90)
$(row alpha 4 1 2 0 1 4 10 10 98)
$(row beta 1 0 0 1 0 1 1 60 60)
$(row gamma 1 1 0 0 0 5 5 5 5)
$(row "none free" 1 0 0 0 1 - - - -)
copies: 3 patch, 1 walk, 0 first (of the 4 finished runs that logged how)
picks: 2 auto, 0 list, 4 named (of the 6 finished runs that logged how)"
stats
[ "$code" = 0 ] && [ "$out" = "$want" ] || fail "wh stats: exit $code, wanted
$want
got
$out"
echo "ok   wh stats reports each host's finished runs, outcomes and copy and job times, and how copies went and hosts were picked"

stats --since 7d
want="wh stats: 6 finished runs in the last 7d; times in whole seconds, median and 90th percentile
$(row host runs ok failed stopped blocked "copy p50" p90 "job p50" p90)
$(row alpha 4 1 2 0 1 4 10 10 98)
$(row beta 1 0 0 1 0 1 1 60 60)
$(row "none free" 1 0 0 0 1 - - - -)
copies: 2 patch, 1 walk, 0 first (of the 3 finished runs that logged how)
picks: 2 auto, 0 list, 3 named (of the 5 finished runs that logged how)"
[ "$code" = 0 ] && [ "$out" = "$want" ] || fail "wh stats --since 7d: exit $code, wanted
$want
got
$out"
echo "ok   wh stats --since leaves out runs that started before then"

stats --since 7d --json
want='{"since":"7d","runs":6,"hosts":[{"host":"alpha","runs":4,"ok":1,"failed":2,"stopped":0,"blocked":1,"copy":{"p50":4,"p90":10},"job":{"p50":10,"p90":98}},{"host":"beta","runs":1,"ok":0,"failed":0,"stopped":1,"blocked":0,"copy":{"p50":1,"p90":1},"job":{"p50":60,"p90":60}},{"host":null,"runs":1,"ok":0,"failed":0,"stopped":0,"blocked":1,"copy":null,"job":null}],"copies":{"patch":2,"walk":1,"first":0},"picks":{"auto":2,"list":0,"named":3}}'
[ "$code" = 0 ] && [ "$out" = "$want" ] || fail "wh stats --since 7d --json: exit $code, wanted
$want
got
$out"
echo "ok   wh stats --json gives the same numbers as one JSON object, null where a host has no times"

for bad in "--since" "--since 7" "--since 0d" "--since 3w" "--json --json" "extra"; do
  # shellcheck disable=SC2086 # each case is its words
  stats $bad
  [ "$code" = 2 ] && [ "$out" = "usage: wh stats [--since <n>d|<n>h] [--json]" ] || fail "wh stats $bad: exit $code: $out"
done
echo "ok   wh stats refuses a bad --since or an unknown argument with its usage"

echo "all stats checks passed"
