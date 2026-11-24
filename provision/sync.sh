#!/bin/bash
# ABOUTME: Brings every workhorse to the state this folder's scripts describe, so all hosts carry the same tools.
# ABOUTME: Usage: sync.sh [host...] starts a detached run; sync.sh status [host...]; sync.sh diff compares all hosts.
set -euo pipefail
cd "$(dirname "$0")"

# shellcheck source=../scripts/lib/hosts.sh
. ../scripts/lib/hosts.sh
load_hosts || exit 1
all_hosts=("${host_names[@]}")

# Each host's ssh target, profile and wallpaper colour come from the hosts file.
ssh_target() {
  local i
  i=$(host_index "$1") || exit 1
  echo "${host_ssh[$i]}"
}

# dedicated: the Mac is the workhorse's alone. shared: its owner uses it too (see setup.sh).
profile() {
  local i
  i=$(host_index "$1") || exit 1
  echo "${host_profile[$i]}"
}

show_status() {
  local target
  target=$(ssh_target "$1")
  echo "=== $1"
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" '
    if [ -d ~/workhorse.lock ]; then echo "running"; tail -3 ~/workhorse/run.log
    elif [ -f ~/workhorse/run.status ]; then echo "exit=$(cat ~/workhorse/run.status)"; tail -3 ~/workhorse/run.log
    else echo "never synced"; fi'
}

wallpaper() {
  local i
  i=$(host_index "$1") || exit 1
  echo "${host_colour[$i]}"
}

start_sync() {
  local target profile colour="" sudo_pw
  target=$(ssh_target "$1")
  profile=$(profile "$1")
  # Read before the lock: a missing password stops here instead of starting a run with no sudo password.
  sudo_pw=$(sudo_password "$1") || { echo "$1: no sudo password; nothing was run" >&2; return 1; }
  # A shared Mac keeps its owner's wallpaper and gets no Unity.
  [ "$profile" = shared ] || colour=$(wallpaper "$1")
  # One run per host: the lock directory exists until the remote run ends.
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" 'mkdir ~/workhorse.lock' ||
    { echo "$1: a sync is already running (~/workhorse.lock exists)" >&2; return 1; }
  if ! { rsync -az --delete --exclude sync.sh --exclude run.log --exclude run.status ./ "$target:workhorse/" &&
    ssh -o BatchMode=yes "$target" 'mkdir -p ~/.local/bin && cp ~/workhorse/zshenv ~/.zshenv && install -m 700 ~/workhorse/askpass-env ~/.local/bin/askpass-env'; }; then
    ssh -o BatchMode=yes "$target" 'rmdir ~/workhorse.lock'
    echo "$1: copying the workhorse files failed; nothing was run" >&2
    return 1
  fi
  LC_SUDO_PW="$sudo_pw" LC_WORKHORSE_WALLPAPER="$colour" LC_WORKHORSE_PROFILE="$profile" \
    ssh -o BatchMode=yes -o SendEnv=LC_SUDO_PW -o SendEnv=LC_WORKHORSE_WALLPAPER -o SendEnv=LC_WORKHORSE_PROFILE "$target" '
    export SUDO_PW="$LC_SUDO_PW"; unset LC_SUDO_PW
    export WORKHORSE_WALLPAPER="$LC_WORKHORSE_WALLPAPER"; unset LC_WORKHORSE_WALLPAPER
    export WORKHORSE_PROFILE="$LC_WORKHORSE_PROFILE"; unset LC_WORKHORSE_PROFILE
    export SUDO_ASKPASS=$HOME/.local/bin/askpass-env
    unity=./unity.sh; [ "$WORKHORSE_PROFILE" = dedicated ] || unity=true
    rm -f ~/workhorse/run.status
    nohup bash -c "cd ~/workhorse && ./setup.sh && ./tools.sh && $unity; echo \$? > ~/workhorse/run.status; rmdir ~/workhorse.lock" \
      > ~/workhorse/run.log 2>&1 < /dev/null &'
  echo "$1: sync started; check with: $0 status $1"
}

# Manifest lines a shared host differs on by design: what it leaves to its owner, and its macOS release.
machine_lines='^(autologin|command-line-tools|dock|firewall|macos|sshd|tailscale|unity-cli|unity-editors|unity-hub) '
# Manifest lines two hosts of different architectures differ on by design: the dependency ports.
arch_lines='^(arch|dep) '

# Exit 0 only when every host answers and reports the same tool versions as the first that answered.
# A comparison that involves a shared host leaves out the machine lines, and one across architectures
# the dependency ports.
diff_hosts() {
  local manifests first="" host status=0 a b
  manifests=$(mktemp -d "${TMPDIR:-/tmp}/workhorse-manifest.XXXX")
  for host in "${all_hosts[@]}"; do
    if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$(ssh_target "$host")" 'zsh ~/workhorse/manifest.sh' > "$manifests/$host"; then
      echo "$host: unreachable, not compared" >&2
      status=1
      continue
    fi
    if [ -z "$first" ]; then first=$host; continue; fi
    a=$manifests/$first b=$manifests/$host
    local skip='^$'
    if [ "$(profile "$first")" = shared ] || [ "$(profile "$host")" = shared ]; then skip="$skip|$machine_lines"; fi
    if [ "$(grep '^arch ' "$a")" != "$(grep '^arch ' "$b")" ]; then skip="$skip|$arch_lines"; fi
    grep -Ev "$skip" "$a" > "$a.compared" || true
    grep -Ev "$skip" "$b" > "$b.compared" || true
    a=$a.compared b=$b.compared
    diff -u --label "$first" --label "$host" "$a" "$b" || status=1
  done
  [ $status -eq 0 ] && echo "all workhorses match ($(wc -l < "$manifests/$first" | tr -d ' ') items)"
  rm -rf "$manifests"
  return $status
}

if [ "${1:-}" = status ]; then
  shift
  hosts=("$@"); [ ${#hosts[@]} -gt 0 ] || hosts=("${all_hosts[@]}")
  for host in "${hosts[@]}"; do show_status "$host"; done
elif [ "${1:-}" = diff ]; then
  diff_hosts
else
  hosts=("$@"); [ ${#hosts[@]} -gt 0 ] || hosts=("${all_hosts[@]}")
  for host in "${hosts[@]}"; do start_sync "$host"; done
fi
