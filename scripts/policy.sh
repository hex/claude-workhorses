#!/bin/bash
# ABOUTME: SessionStart hook: prints the workhorse offload policy, its host table rendered from the hosts file.
# ABOUTME: With no hosts file, or one it cannot use, it prints one line saying so instead.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
# shellcheck source=lib/hosts.sh
. "$root/scripts/lib/hosts.sh"

hosts_file="$(workhorses_config_dir)/hosts"
if [ ! -f "$hosts_file" ]; then
  echo "claude-workhorses: no workhorses are configured (no hosts file at $hosts_file), so wh cannot run; the plugin's README shows how to add one."
  exit 0
fi
if ! load_hosts 2>/dev/null; then
  echo "claude-workhorses: the hosts file is not usable, so wh cannot run: $(load_hosts 2>&1 || true)"
  exit 0
fi

# Prints $1 with every $2 in it replaced by $3, taken as plain text.
replace() {
  local text=$1 token=$2 value=$3 out=""
  while [[ $text == *"$token"* ]]; do
    out+=${text%%"$token"*}$value
    text=${text#*"$token"}
  done
  printf '%s\n' "$out$text"
}

host_table() {
  local i
  echo "| Host | ssh | Arch | Cores | RAM |"
  echo "|------|-----|------|-------|-----|"
  for i in "${!host_names[@]}"; do
    echo "| ${host_names[$i]} | ${host_ssh[$i]} | ${host_arch[$i]} | ${host_cores[$i]} | ${host_ram[$i]} GB |"
  done
}

while IFS= read -r line || [ -n "$line" ]; do
  if [ "$line" = @HOSTS@ ]; then
    host_table
    continue
  fi
  line=$(replace "$line" @SYNC@ "$root/provision/sync.sh")
  replace "$line" @MIRROR@ "$root/scripts/mirror.sh"
done <"$root/scripts/policy.md"
