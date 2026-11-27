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
stats --json
[ "$code" = 0 ] && [ "$out" = '{"since":null,"runs":0,"hosts":[],"copies":{"patch":0,"walk":0,"first":0},"picks":{"auto":0,"list":0,"named":0}}' ] ||
  fail "with no run log, --json: exit $code: $out"
echo "ok   with no run log, wh stats says so, and --json prints a report of no runs"

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
# delta, picked by load six hours ago, ten times: the copies took 1 to 10 s and the jobs 10 to 100 s, so the
# nearest-rank median is the 5th of each and the 90th percentile the 9th. The last one's stop went unconfirmed.
for i in 0 1 2 3 4 5 6 7 8 9; do
  s=$((now - 21600 + i * 60)) y=$((now - 21600 + i * 60 + i + 1))
  line --arg id "d$i" --argjson at $s '{event: "start", id: $id, at: $at, host: "delta", pick: "auto", probe: {load: 0.5, cores: 4, runs: 0}}'
  line --arg id "d$i" --argjson at $y '{event: "synced", id: $id, at: $at, copy: "patch", files: 1}'
  if [ $i = 9 ]; then
    line --arg id "d$i" --argjson at $((y + 100)) '{event: "end", id: $id, at: $at, exit: 143, reason: "stop-unconfirmed"}'
  else
    line --arg id "d$i" --argjson at $((y + 10 * (i + 1))) '{event: "end", id: $id, at: $at, exit: 0}'
  fi
done
# epsilon, named, started 13 hours ago and ended 11 hours ago: --since 12h leaves it out by its start.
line --argjson at $((now - 46800)) '{event: "start", id: "e1", at: $at, host: "epsilon", pick: "named"}'
line --argjson at $((now - 46799)) '{event: "synced", id: "e1", at: $at, copy: "walk", why: "Watchman could not answer", files: 0}'
line --argjson at $((now - 39600)) '{event: "end", id: "e1", at: $at, exit: 0}'
# gamma, ten days ago: passed after a 5 s copy and a 5 s job.
line --argjson at $old '{event: "start", id: "r8", at: $at, host: "gamma", pick: "named"}'
line --argjson at $((old + 5)) '{event: "synced", id: "r8", at: $at, copy: "patch", files: 2}'
line --argjson at $((old + 10)) '{event: "end", id: "r8", at: $at, exit: 0}'

# Medians and 90th percentiles by nearest rank: alpha's copies took 2, 4 and 10 s, its jobs 1, 10 and 98 s.
row() { printf '%-12s %5s %4s %6s %7s %7s %8s %5s %7s %5s\n' "$@"; }
want="wh stats: 18 finished runs; times in whole seconds, median and 90th percentile
$(row host runs ok failed stopped blocked "copy p50" p90 "job p50" p90)
$(row delta 10 9 0 1 0 5 9 50 90)
$(row alpha 4 1 2 0 1 4 10 10 98)
$(row beta 1 0 0 1 0 1 1 60 60)
$(row epsilon 1 1 0 0 0 1 1 7199 7199)
$(row gamma 1 1 0 0 0 5 5 5 5)
$(row "none free" 1 0 0 0 1 - - - -)
copies: 13 patch, 2 walk, 0 first (of the 15 finished runs that logged how)
picks: 12 auto, 0 list, 5 named (of the 17 finished runs that logged how)"
stats
[ "$code" = 0 ] && [ "$out" = "$want" ] || fail "wh stats: exit $code, wanted
$want
got
$out"
echo "ok   wh stats reports each host's finished runs, outcomes and copy and job times, and how copies went and hosts were picked"

stats --since 7d
want="wh stats: 17 finished runs in the last 7d; times in whole seconds, median and 90th percentile
$(row host runs ok failed stopped blocked "copy p50" p90 "job p50" p90)
$(row delta 10 9 0 1 0 5 9 50 90)
$(row alpha 4 1 2 0 1 4 10 10 98)
$(row beta 1 0 0 1 0 1 1 60 60)
$(row epsilon 1 1 0 0 0 1 1 7199 7199)
$(row "none free" 1 0 0 0 1 - - - -)
copies: 12 patch, 2 walk, 0 first (of the 14 finished runs that logged how)
picks: 12 auto, 0 list, 4 named (of the 16 finished runs that logged how)"
[ "$code" = 0 ] && [ "$out" = "$want" ] || fail "wh stats --since 7d: exit $code, wanted
$want
got
$out"
stats --since 12h
want="wh stats: 10 finished runs in the last 12h; times in whole seconds, median and 90th percentile
$(row host runs ok failed stopped blocked "copy p50" p90 "job p50" p90)
$(row delta 10 9 0 1 0 5 9 50 90)
copies: 10 patch, 0 walk, 0 first (of the 10 finished runs that logged how)
picks: 10 auto, 0 list, 0 named (of the 10 finished runs that logged how)"
[ "$code" = 0 ] && [ "$out" = "$want" ] || fail "wh stats --since 12h: exit $code, wanted
$want
got
$out"
echo "ok   wh stats --since, in days or hours, leaves out runs that started before then, though they ended after"

stats --since 7d --json
want='{"since":"7d","runs":17,"hosts":[{"host":"delta","runs":10,"ok":9,"failed":0,"stopped":1,"blocked":0,"copy":{"p50":5,"p90":9},"job":{"p50":50,"p90":90}},{"host":"alpha","runs":4,"ok":1,"failed":2,"stopped":0,"blocked":1,"copy":{"p50":4,"p90":10},"job":{"p50":10,"p90":98}},{"host":"beta","runs":1,"ok":0,"failed":0,"stopped":1,"blocked":0,"copy":{"p50":1,"p90":1},"job":{"p50":60,"p90":60}},{"host":"epsilon","runs":1,"ok":1,"failed":0,"stopped":0,"blocked":0,"copy":{"p50":1,"p90":1},"job":{"p50":7199,"p90":7199}},{"host":null,"runs":1,"ok":0,"failed":0,"stopped":0,"blocked":1,"copy":null,"job":null}],"copies":{"patch":12,"walk":2,"first":0},"picks":{"auto":12,"list":0,"named":4}}'
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
