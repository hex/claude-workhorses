#!/bin/bash
# ABOUTME: Brings each workhorse to what its hosts-file options and the tools file ask for: copies the host scripts and
# ABOUTME: recipes over, runs them detached. Usage: sync.sh [host...]; sync.sh status [host...]; sync.sh diff.
set -euo pipefail

provision=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=../scripts/lib/hosts.sh
. "$provision/../scripts/lib/hosts.sh"
# shellcheck source=../scripts/lib/tools.sh
. "$provision/../scripts/lib/tools.sh"

ssh_target() {
  local i
  i=$(host_index "$1") || exit 1
  echo "${host_ssh[$i]}"
}

# Fills the empty folder $2 with everything a run on host $1 needs, and nothing else: the scripts in
# provision/host, the recipes its tools lines name, its tools lines without filters, and its host
# options, one per line, with "sudo" after those that need the password. The folder that holds the
# hosts file and the sudo-password helper never goes to a host.
stage_host() {
  local host=$1 stage=$2 index i option
  index=$(host_index "$host")
  cp "$provision"/host/* "$stage/"
  mkdir "$stage/recipes"
  for i in "${!tool_recipe[@]}"; do
    tool_targets "$i" "$host" || continue
    # load_tools refused a symlinked recipe; one swapped in since is copied as a link, then refused.
    cp -P "${tool_path[i]}" "$stage/recipes/${tool_recipe[i]}"
    if [ -L "$stage/recipes/${tool_recipe[i]}" ]; then
      echo "recipe ${tool_path[i]} became a symlink; nothing was sent" >&2
      return 1
    fi
    chmod 755 "$stage/recipes/${tool_recipe[i]}"
  done
  host_tool_lines "$host" >"$stage/tools"
  : >"$stage/options"
  for option in ${host_options[index]}; do
    if is_one_of "${option%%=*}" "${host_options_sudo[@]}"; then echo "$option sudo"; else echo "$option"; fi
  done >"$stage/options"
}

# Removes host $1's lock, at ssh target $2, after a sync that took it failed to start a run, and says
# so with $3, the reason. apply.sh puts a file in the lock as it starts, so a run that did start, though
# its ssh reported a failure, keeps its lock: rmdir refuses a folder that is not empty.
release_lock() {
  local host=$1 target=$2 reason=$3
  if ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" 'rmdir ~/workhorse.lock' 2>/dev/null; then
    echo "$host: $reason; nothing ran, and the lock is removed" >&2
  else
    echo "$host: $reason, and ~/workhorse.lock stays: a run may have started; \`$0 status $host\` shows it, and if none runs, \`ssh $target 'rm -r ~/workhorse.lock'\` removes it" >&2
  fi
}

# Runs provision/host/sync-state.sh with argument $2 (status or take) on host $1's /bin/bash, sent on stdin,
# so a host synced by an older sync.sh answers the same.
sync_state() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$1" "/bin/bash -s -- $2" <"$provision/host/sync-state.sh"
}

# Prints why the state line $1, "crashed <reason> [<pid>]" from sync-state.sh, reads as crashed.
crashed_why() {
  local _ reason pid
  read -r _ reason pid <<<"$1"
  [[ $pid =~ ^[0-9]+$ ]] || pid="unknown"
  case $reason in
    rebooted) echo "the host rebooted since its run started" ;;
    gone) echo "its process $pid is gone" ;;
    old) echo "no run started under it, and it is over an hour old" ;;
    *) echo "for a reason it gives unreadably" ;;
  esac
}

# Ends sync.sh with exit $1, 128 + the signal that stopped it while start_sync held a host's lock and
# no run had started: removes the staging folder and the lock. It runs inside start_sync, so it reads
# that function's host, target and stage.
stop_holding_lock() {
  trap - INT TERM HUP
  [ -z "${stage:-}" ] || rm -rf "$stage"
  release_lock "$host" "$target" "sync.sh was stopped by a signal"
  exit "$1"
}

# Asks host $1 which OS it runs and records it in host_os, macos or linux. Fails, saying why, when
# the host does not answer or runs another system.
learn_host_os() {
  local host=$1 index answer code=0
  index=$(host_index "$host") || return 1
  answer=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$(ssh_target "$host")" uname -s) || code=$?
  case "$code:$answer" in
    0:Darwin) host_os[index]=macos ;;
    0:Linux) host_os[index]=linux ;;
    255:*) echo "$host: unreachable (ssh exit 255); nothing was run" >&2; return 1 ;;
    0:*) echo "$host: runs \"$(printf '%s' "$answer" | LC_ALL=C tr -cd 'A-Za-z0-9._ -' | cut -c1-40)\", not macOS or Linux; nothing was run" >&2; return 1 ;;
    *) echo "$host: could not tell which OS it runs (ssh exit $code); nothing was run" >&2; return 1 ;;
  esac
}

# Starts a run on host $1. Its caller tests its result, which turns set -e off in here, so every step
# checks its own.
start_sync() {
  local host=$1 target sudo_pw="" stage="" code=0 index i answer pid failed=""
  target=$(ssh_target "$host") || return 1
  index=$(host_index "$host") || return 1
  # The host's OS decides which tools lines it gets, and so whether it needs the password.
  learn_host_os "$host" || return 1
  if [ "${host_os[index]}" = linux ] && [ -n "${host_options[index]}" ]; then
    echo "$host runs Linux, where host options do not apply: remove ${host_options[index]// /, } from its hosts line; nothing was run" >&2
    return 1
  fi
  # A line for a recipe that runs only on macOS stops a Linux host here, before the password or the lock.
  if [ "${host_os[index]}" = linux ]; then
    for i in "${!tool_recipe[@]}"; do
      tool_targets "$i" "$host" && recipe_macos_only "${tool_path[i]}" || continue
      echo "$host: ${tool_recipe[i]} runs only on macOS: give its line @os=macos; nothing was run" >&2
      return 1
    done
  fi
  # Read before the lock: a missing password stops here instead of starting a run that fails at sudo.
  if host_needs_sudo "$host"; then
    sudo_pw=$(sudo_password "$host") || { echo "$host: no sudo password; nothing was run" >&2; return 1; }
  fi
  # One run per host: the lock directory exists until the remote run ends. ssh exits 255 when it
  # cannot reach the host. A lock already there says what holds it.
  answer=$(sync_state "$target" take) || code=$?
  case $code in
    0) ;;
    255) echo "$host: unreachable (ssh exit 255); nothing was run" >&2; return 1 ;;
    *) echo "$host: could not take ~/workhorse.lock (ssh exit $code); nothing was run" >&2; return 1 ;;
  esac
  case $answer in
    taken) ;;
    running) echo "$host: a sync is already running (~/workhorse.lock exists)" >&2; return 1 ;;
    "running "*)
      pid=${answer#running }
      [[ $pid =~ ^[0-9]+$ ]] || pid="an unreadable pid"
      echo "$host: a sync is already running as pid $pid (~/workhorse.lock exists)" >&2
      return 1 ;;
    "crashed "*)
      echo "$host: the last sync crashed: $(crashed_why "$answer"); nothing was run. Remove its lock with: ssh $target 'rm -r ~/workhorse.lock', then sync again" >&2
      return 1 ;;
    *) echo "$host: could not create ~/workhorse.lock; nothing was run" >&2; return 1 ;;
  esac
  # From here until the run starts, a signal frees the lock: nothing else would.
  trap 'stop_holding_lock 130' INT
  trap 'stop_holding_lock 143' TERM
  trap 'stop_holding_lock 129' HUP
  if ! stage=$(mktemp -d "${TMPDIR:-/tmp}/workhorse-stage.XXXX"); then
    failed="making a staging folder failed"
  elif ! { stage_host "$host" "$stage" &&
    rsync -a --delete --exclude /run.log --exclude /run.status --exclude /manifest "$stage/" "$target:workhorse/"; }; then
    failed="copying the workhorse files failed"
  # The password crosses on the ssh session's stdin, from the printf builtin: never in an environment
  # variable the host's login shell would hold while it reads its startup file, never in a command line.
  # apply.sh hands it only to the steps that need it.
  elif ! printf '%s\n' "$sudo_pw" | ssh -o BatchMode=yes "$target" '/bin/bash ~/workhorse/apply.sh start'; then
    failed="starting the run failed"
  fi
  trap - INT TERM HUP
  [ -z "$stage" ] || rm -rf "$stage"
  if [ -n "$failed" ]; then
    release_lock "$host" "$target" "$failed"
    return 1
  fi
  echo "$host: sync started; check with: $0 status $host"
}

# Shows how host $1's last run went. Once the run has ended, stores the manifest it wrote as
# <state dir>/manifests/<host>, which the session-start policy reads. Fails when the host does not
# answer or its last run failed; a run still going or a host never synced is no failure. Its caller
# tests its result, which turns set -e off in here, so every step checks its own.
show_status() {
  local host=$1 target answer manifests code=0 result=0 pid
  target=$(ssh_target "$host") || return 1
  echo "=== $host"
  answer=$(sync_state "$target" status) || code=$?
  if [ $code -ne 0 ]; then
    echo "unreachable (ssh exit $code)"
    return 1
  fi
  case "$(head -n 1 <<<"$answer")" in
    "ended 0") echo "exit=0" ;;
    ended*)
      read -r _ code step <<<"$answer"
      [[ $code =~ ^[0-9]+$ ]] || code=unknown
      [[ $step =~ ^[a-z0-9][A-Za-z0-9:=_-]*$ ]] || step="an unreadable step"
      echo "exit=$code, stopped at $step"
      result=1 ;;
    "running" | "never synced") head -n 1 <<<"$answer" ;;
    "running "*)
      read -r _ pid <<<"$answer"
      [[ $pid =~ ^[0-9]+$ ]] || pid="with an unreadable pid"
      echo "running $pid" ;;
    "crashed "*)
      echo "crashed: $(crashed_why "$(head -n 1 <<<"$answer")")"
      echo "remove its lock with: ssh $target 'rm -r ~/workhorse.lock'"
      result=1 ;;
    *) echo "in a state it gives unreadably"; result=1 ;;
  esac
  # The end of run.log is whatever the run's steps printed on the host: it is marked as the host's
  # text, and loses its control characters.
  if [ -n "$(tail -n +2 <<<"$answer")" ]; then
    echo "the end of its run.log, text the host wrote:"
    tail -n +2 <<<"$answer" | LC_ALL=C tr -d '\000-\010\013-\037\177' | cut -c1-200 | sed 's/^/| /'
  fi
  [[ $answer == ended* ]] || return $result
  manifests="$(workhorses_state_dir)/manifests"
  mkdir -p "$manifests" || return 1
  if ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" 'cat ~/workhorse/manifest' >"$manifests/$host.new" &&
    grep -q '^#synced ' "$manifests/$host.new" && mv "$manifests/$host.new" "$manifests/$host"; then
    echo "manifest stored: $manifests/$host"
  else
    rm -f "$manifests/$host.new"
    echo "$host has no manifest from its last run; sync it again to get one" >&2
  fi
  return $result
}

# Prints the probe lines under tools line $2 in manifest file $1, or fails when the manifest has no such line.
manifest_block() {
  grep -qxF "#line $2" "$1" || return 1
  awk -v want="#line $2" '$0 == want {on = 1; next} /^#/ {on = 0} on' "$1"
}

# Prints diff -u output from stdin with each line a host wrote replaced by a placeholder unless it has
# a probe line's shape. The two header lines name a host and a tools line, both checked locally.
shaped_diff() {
  local line number=0
  while IFS= read -r line; do
    number=$((number + 1))
    if [ $number -le 2 ] || [[ $line == "@@ "* ]]; then
      printf '%s\n' "$line"
    elif probe_line_shaped "${line:1}"; then
      printf '%s\n' "${line:0:1}$probe_line"
    else
      printf '%s\n' "${line:0:1}(a line not shaped as a tool and its version)"
    fi
  done
}

# Recipes whose version follows the macOS release, so diff compares them only among hosts on the same major release.
macos_release_recipes=" command-line-tools "

# Prints the major macOS release that manifest $1 records, or "unknown".
manifest_macos_major() {
  local major
  major=$(awk '/^#line /{exit} /^macos /{print $2; exit}' "$1")
  major=${major%%.*}
  [[ $major =~ ^[0-9]+$ ]] || major=unknown
  echo "$major"
}

# Exit 0 only when every host answers and, for each tools line, every host the line targets reports
# the same probe output as the first of them (the first on the same macOS release, for a recipe that
# follows it), and none reports the tool missing or its probe failed.
# Hosts are compared on what they wrote; what is shown of it has a probe line's shape.
diff_hosts() {
  local manifests host status=0 i line first firsts group entry block lines=0 code report
  manifests=$(mktemp -d "${TMPDIR:-/tmp}/workhorse-manifest.XXXX")
  for host in "${host_names[@]}"; do
    code=0
    # A first line "#sync-lock" marks a host whose sync holds its lock, which may be mid-install.
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$(ssh_target "$host")" '[ ! -d ~/workhorse.lock ] || echo "#sync-lock"; /bin/bash ~/workhorse/manifest.sh' >"$manifests/$host" || code=$?
    case $code in
      0)
        [ "$(head -n 1 "$manifests/$host")" != "#sync-lock" ] ||
          echo "$host: a sync holds ~/workhorse.lock, so a tool it is installing may read as missing or different" >&2
        continue ;;
      255) echo "$host: unreachable (ssh exit 255), not compared" >&2 ;;
      *) echo "$host: has no manifest.sh to run (ssh exit $code): sync it first; not compared" >&2 ;;
    esac
    rm -f "$manifests/$host"
    status=1
  done
  # Each host's OS, for the @os filters, comes from the manifest it just wrote.
  for host in "${host_names[@]}"; do
    [ ! -f "$manifests/$host" ] || host_os[$(host_index "$host")]=$(manifest_os "$manifests/$host")
  done
  for i in "${!tool_recipe[@]}"; do
    line="${tool_recipe[i]}${tool_args[i]:+ ${tool_args[i]}}"
    firsts=""
    lines=$((lines + 1))
    for host in "${host_names[@]}"; do
      [ -f "$manifests/$host" ] && tool_targets "$i" "$host" || continue
      if ! manifest_block "$manifests/$host" "$line" >"$manifests/$host.block"; then
        echo "$host: not synced with \"$line\"" >&2
        status=1
        continue
      fi
      # A tool every host lacks would match everywhere, so each host's report is checked on its own.
      while IFS= read -r report; do
        echo "$host: the probe for \"$line\" reports: $report"
        status=1
      done < <(grep -E ' (missing|probe-failed [0-9]+)$' "$manifests/$host.block" | shaped_probe_lines)
      group=all
      [[ $macos_release_recipes != *" ${tool_recipe[i]} "* ]] || group=macos-$(manifest_macos_major "$manifests/$host")
      first=""
      for entry in $firsts; do [ "${entry%%=*}" != "$group" ] || first=${entry#*=}; done
      if [ -z "$first" ]; then firsts="$firsts $group=$host"; continue; fi
      block=$(diff -u --label "$first: $line" --label "$host: $line" "$manifests/$first.block" "$manifests/$host.block") ||
        { shaped_diff <<<"$block"; status=1; }
    done
    for host in "${host_names[@]}"; do rm -f "$manifests/$host.block"; done
  done
  rm -rf "$manifests"
  [ $status -ne 0 ] || echo "all workhorses match ($lines tools lines)"
  return $status
}

main() {
  # Everything is checked before any host is contacted.
  load_hosts || exit 1
  load_tools || exit 1
  local command=sync host hosts=()
  case "${1:-}" in
    status | diff) command=$1; shift ;;
  esac
  hosts=("$@")
  [ ${#hosts[@]} -gt 0 ] || hosts=("${host_names[@]}")
  for host in "${hosts[@]}"; do host_index "$host" >/dev/null || exit 1; done
  case "$command" in
    status)
      local status=0
      for host in "${hosts[@]}"; do show_status "$host" || status=1; done
      return $status ;;
    diff) diff_hosts ;;
    sync)
      local status=0
      for host in "${hosts[@]}"; do start_sync "$host" || status=1; done
      return $status ;;
  esac
}

# Sourced by the checks for its functions; run, it syncs.
[ "${BASH_SOURCE[0]}" != "$0" ] || main "$@"
