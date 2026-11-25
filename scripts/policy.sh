#!/bin/bash
# ABOUTME: SessionStart hook: prints the workhorse offload policy, with the host table, each host's tools from the
# ABOUTME: manifests sync.sh status stored, and the user's notes. Reads local files only; it never contacts a host.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
sync="$root/provision/sync.sh"
# shellcheck source=lib/hosts.sh
. "$root/scripts/lib/hosts.sh"
# shellcheck source=lib/tools.sh
. "$root/scripts/lib/tools.sh"

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

# A manifest is written by the host, so its text reaches Claude only through this filter: a small set
# of characters, at most 100 of them a line.
sanitize() { tr '\t' ' ' | LC_ALL=C tr -cd 'A-Za-z0-9 ._@:/+,=()\n-' | tr -s ' ' | cut -c1-100; }

# The probe lines of manifest $1's tools blocks, filtered, sorted, each once.
manifest_tools() { awk '/^#/ {on = ($0 ~ /^#line /); next} on' "$1" | sanitize | LC_ALL=C sort -u; }

# The value of manifest $1's header line "#$2 <value>", filtered.
manifest_header() { sed -n "s/^#$2 //p" "$1" | head -n 1 | sanitize; }

# Prints the lines of $1 as a list, at most $2 of them, then how many it left out.
bullets() {
  local count
  count=$(grep -c . <<<"$1" || true)
  head -n "$2" <<<"$1" | sed 's/^/- /'
  [ "$count" -le "$2" ] || echo "- and $((count - $2)) more"
}

tools_section() {
  local manifests host file recorded=() common="" lines heading exit_code step macos stale=()
  if ! load_tools 2>/dev/null; then
    echo "The tools file is not usable, so the tools section is left out: $(load_tools 2>&1 || true)"
    return 0
  fi
  manifests="$(workhorses_state_dir)/manifests"
  for host in "${host_names[@]}"; do
    [ ! -f "$manifests/$host" ] || recorded+=("$host")
  done
  if [ ${#tool_recipe[@]} -eq 0 ] && [ ${#recorded[@]} -eq 0 ]; then
    echo "The tools file lists nothing yet, so the workhorses have only what macOS and their owners put there; the workhorse skill shows how to add a tool."
    return 0
  fi
  echo "Tools on the workhorses, as each host's last sync recorded them (\`bash $sync status\` stores the record):"
  echo
  # With two records or more, what all of them have is listed once.
  if [ ${#recorded[@]} -ge 2 ]; then
    common=$(for host in "${recorded[@]}"; do manifest_tools "$manifests/$host"; done | LC_ALL=C sort | uniq -c |
      awk -v n=${#recorded[@]} '$1 == n {sub(/^ *[0-9]+ /, ""); print}')
    if [ -n "$common" ]; then
      echo "On every host with a record:"
      bullets "$common" 40
      echo
    fi
  fi
  for host in ${recorded[@]+"${recorded[@]}"}; do
    file=$manifests/$host
    lines=$(manifest_tools "$file")
    [ -z "$common" ] || lines=$(LC_ALL=C comm -23 <(printf '%s\n' "$lines") <(printf '%s\n' "$common"))
    macos=$(awk '/^#/ {on = ($0 == "#base"); next} on' "$file" | sed -n 's/^macos //p' | head -n 1 | sanitize)
    heading="$host (macOS ${macos:-unknown}, synced $(manifest_header "$file" synced)"
    read -r exit_code step <<<"$(manifest_header "$file" exit)" || true
    [ "${exit_code:-0}" = 0 ] || heading+=", stopped at ${step:-setup} with exit $exit_code"
    heading+=")"
    if [ -z "$lines" ]; then
      echo "$heading has nothing beyond those."
    else
      if [ -n "$common" ]; then echo "$heading also has:"; else echo "$heading has:"; fi
      bullets "$lines" 20
    fi
    echo
    [ "$(sed -n 's/^#line //p' "$file")" = "$(host_tool_lines "$host")" ] || stale+=("$host")
  done
  for host in "${host_names[@]}"; do
    [ -f "$manifests/$host" ] ||
      echo "$host has no record: it was never synced, or \`bash $sync status $host\` has not stored its last run."
  done
  for host in ${stale[@]+"${stale[@]}"}; do
    echo "The tools file has changed since the last sync of $host: \`bash $sync $host\` brings it level."
  done
}

notes_section() {
  local notes
  notes="$(workhorses_config_dir)/notes"
  [ -f "$notes" ] || return 0
  echo "From the user's notes file, $notes:"
  echo
  cat "$notes"
}

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    @HOSTS@) host_table; continue ;;
    @TOOLS@) tools_section; continue ;;
    @NOTES@) notes_section; continue ;;
  esac
  line=$(replace "$line" @SYNC@ "$sync")
  line=$(replace "$line" @CONFIG@ "$(workhorses_config_dir)")
  replace "$line" @MIRROR@ "$root/scripts/mirror.sh"
done <"$root/scripts/policy.md"
