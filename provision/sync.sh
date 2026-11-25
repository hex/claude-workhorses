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
    cp "${tool_path[i]}" "$stage/recipes/${tool_recipe[i]}"
    chmod 755 "$stage/recipes/${tool_recipe[i]}"
  done
  host_tool_lines "$host" >"$stage/tools"
  : >"$stage/options"
  for option in ${host_options[index]}; do
    if is_one_of "${option%%=*}" "${host_options_sudo[@]}"; then echo "$option sudo"; else echo "$option"; fi
  done >"$stage/options"
}

start_sync() {
  local host=$1 target sudo_pw="" stage
  target=$(ssh_target "$host")
  # Read before the lock: a missing password stops here instead of starting a run that fails at sudo.
  if host_needs_sudo "$host"; then
    sudo_pw=$(sudo_password "$host") || { echo "$host: no sudo password; nothing was run" >&2; return 1; }
  fi
  # One run per host: the lock directory exists until the remote run ends.
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" 'mkdir ~/workhorse.lock' ||
    { echo "$host: a sync is already running (~/workhorse.lock exists)" >&2; return 1; }
  stage=$(mktemp -d "${TMPDIR:-/tmp}/workhorse-stage.XXXX")
  if ! { stage_host "$host" "$stage" &&
    rsync -a --delete --exclude /run.log --exclude /run.status --exclude /manifest "$stage/" "$target:workhorse/"; }; then
    rm -rf "$stage"
    ssh -o BatchMode=yes "$target" 'rmdir ~/workhorse.lock'
    echo "$host: copying the workhorse files failed; nothing was run" >&2
    return 1
  fi
  rm -rf "$stage"
  # The password crosses in the ssh session's environment, never in a command line; apply.sh hands it
  # only to the steps that need it.
  LC_SUDO_PW="$sudo_pw" ssh -o BatchMode=yes -o SendEnv=LC_SUDO_PW "$target" '
    export SUDO_PW="${LC_SUDO_PW:-}"; unset LC_SUDO_PW
    rm -f ~/workhorse/run.status
    nohup /bin/bash ~/workhorse/apply.sh > ~/workhorse/run.log 2>&1 < /dev/null &'
  echo "$host: sync started; check with: $0 status $host"
}

# Shows how host $1's last run went. Once the run has ended, stores the manifest it wrote as
# <state dir>/manifests/<host>, which the session-start policy reads.
show_status() {
  local host=$1 target answer manifests
  target=$(ssh_target "$host")
  echo "=== $host"
  answer=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" '
    if [ -d ~/workhorse.lock ]; then echo "running"
    elif [ -f ~/workhorse/run.status ]; then echo "ended $(cat ~/workhorse/run.status)"
    else echo "never synced"; fi
    [ ! -f ~/workhorse/run.log ] || tail -3 ~/workhorse/run.log')
  case "$answer" in
    "ended 0"*) echo "exit=0" ;;
    ended*) read -r _ code step <<<"$answer"; echo "exit=$code, stopped at $step" ;;
    *) head -n 1 <<<"$answer" ;;
  esac
  tail -n +2 <<<"$answer"
  [[ $answer == ended* ]] || return 0
  manifests="$(workhorses_state_dir)/manifests"
  mkdir -p "$manifests"
  if ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" 'cat ~/workhorse/manifest' >"$manifests/$host.new" &&
    grep -q '^#synced ' "$manifests/$host.new"; then
    mv "$manifests/$host.new" "$manifests/$host"
    echo "manifest stored: $manifests/$host"
  else
    rm -f "$manifests/$host.new"
    echo "$host has no manifest from its last run; sync it again to get one" >&2
  fi
}

# Prints the probe lines under tools line $2 in manifest file $1, or fails when the manifest has no such line.
manifest_block() {
  grep -qxF "#line $2" "$1" || return 1
  awk -v want="#line $2" '$0 == want {on = 1; next} /^#/ {on = 0} on' "$1"
}

# Exit 0 only when every host answers and, for each tools line, every host the line targets reports
# the same probe output as the first of them.
diff_hosts() {
  local manifests host status=0 i line first block lines=0
  manifests=$(mktemp -d "${TMPDIR:-/tmp}/workhorse-manifest.XXXX")
  for host in "${host_names[@]}"; do
    if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$(ssh_target "$host")" '/bin/bash ~/workhorse/manifest.sh' >"$manifests/$host"; then
      echo "$host: unreachable, not compared" >&2
      rm -f "$manifests/$host"
      status=1
    fi
  done
  for i in "${!tool_recipe[@]}"; do
    line="${tool_recipe[i]}${tool_args[i]:+ ${tool_args[i]}}"
    first=""
    lines=$((lines + 1))
    for host in "${host_names[@]}"; do
      [ -f "$manifests/$host" ] && tool_targets "$i" "$host" || continue
      if ! manifest_block "$manifests/$host" "$line" >"$manifests/$host.block"; then
        echo "$host: not synced with \"$line\"" >&2
        status=1
        continue
      fi
      if [ -z "$first" ]; then first=$host; continue; fi
      block=$(diff -u --label "$first: $line" --label "$host: $line" "$manifests/$first.block" "$manifests/$host.block") ||
        { echo "$block"; status=1; }
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
    status) for host in "${hosts[@]}"; do show_status "$host"; done ;;
    diff) diff_hosts ;;
    sync)
      local status=0
      for host in "${hosts[@]}"; do start_sync "$host" || status=1; done
      return $status ;;
  esac
}

# Sourced by the checks for its functions; run, it syncs.
[ "${BASH_SOURCE[0]}" != "$0" ] || main "$@"
