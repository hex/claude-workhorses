#!/bin/bash
# ABOUTME: Says what state a workhorse's sync is in; sync.sh sends it on stdin to the host's /bin/bash, and apply.sh runs it there.
# ABOUTME: Usage: sync-state.sh status | take | boot-id. Runs under macOS's bash 3.2 and Linux's bash 5.
set -uo pipefail

lock=$HOME/workhorse.lock

# Prints this boot's id, or nothing when the system gives none.
boot_id() {
  if [ -r /proc/sys/kernel/random/boot_id ]; then
    tr -cd '0-9a-f-' </proc/sys/kernel/random/boot_id
  else
    /usr/sbin/sysctl -n kern.bootsessionuuid 2>/dev/null | tr -cd '0-9A-Fa-f-'
  fi
}

# Prints the sync's state, one of:
#   never synced
#   ended <run.status>
#   running [<pid>]          no pid when an apply.sh older than the pid record started the run, or
#                            when sync.sh has taken the lock and is still copying
#   crashed rebooted <pid>   the host booted again since the run started
#   crashed gone <pid>       no apply.sh run has that pid
#   crashed old              no run ever started under a lock over an hour old
state() {
  local pid="" boot="" now
  if ! [ -d "$lock" ]; then
    if [ -f "$HOME/workhorse/run.status" ]; then echo "ended $(cat "$HOME/workhorse/run.status")"; else echo "never synced"; fi
    return 0
  fi
  if ! [ -f "$lock/started" ]; then
    if [ -n "$(find "$lock" -maxdepth 0 -mmin +60)" ]; then echo "crashed old"; else echo running; fi
    return 0
  fi
  read -r pid boot <"$lock/started" || true
  if ! [[ $pid =~ ^[0-9]+$ ]]; then
    echo running
    return 0
  fi
  now=$(boot_id)
  if [ -n "$boot" ] && [ -n "$now" ] && [ "$boot" != "$now" ]; then
    echo "crashed rebooted $pid"
  elif ! ps -p "$pid" -o command= 2>/dev/null | grep -q 'apply\.sh run'; then
    echo "crashed gone $pid"
  else
    echo "running $pid"
  fi
}

case "${1:-}" in
  status)
    state
    [ ! -f "$HOME/workhorse/run.log" ] || tail -3 "$HOME/workhorse/run.log" ;;
  # Takes the lock for a sync and prints "taken", or prints the state that holds it.
  take) if mkdir "$lock" 2>/dev/null; then echo taken; else state; fi ;;
  boot-id) boot_id; echo ;;
  *) echo "usage: sync-state.sh status|take|boot-id" >&2; exit 2 ;;
esac
