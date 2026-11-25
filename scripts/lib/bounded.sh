# ABOUTME: run_bounded: runs a command for at most a given number of seconds, with nothing but bash and sleep.
# ABOUTME: wh's host probes use it, so neither this machine nor a workhorse needs gtimeout for them.
# shellcheck shell=bash

# Runs $2... and stops it with SIGTERM after $1 seconds. Returns the command's exit code, which is
# non-zero when it was stopped. The timer's own output goes to /dev/null: a timer holding the
# caller's output pipe would keep a $(...) around this call waiting until the bound ran out.
run_bounded() {
  local seconds=$1 command timer status=0
  shift
  "$@" &
  command=$!
  (sleep "$seconds" && kill -TERM "$command") </dev/null >/dev/null 2>&1 &
  timer=$!
  # bash reports a command it stopped ("Terminated: 15") on wait's stderr; the exit code says it.
  wait "$command" 2>/dev/null || status=$?
  kill "$timer" 2>/dev/null || true
  wait "$timer" 2>/dev/null || true
  return $status
}
