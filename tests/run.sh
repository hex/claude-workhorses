#!/bin/bash
# ABOUTME: Runs every check that needs no workhorse: host choice, time limits, the hosts and tools files, a sync, the session-start policy, the mod's tests.
# ABOUTME: Usage: tests/run.sh; exits non-zero on the first failing check. wh-check.sh needs a host and runs on its own.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
for check in pick-check limits-check hosts-check tools-check apply-check policy-check; do
  echo "=== $check"
  "$BASH" "$here/$check.sh"
done
echo "=== mod tests"
claude plugin test "$here/.."
