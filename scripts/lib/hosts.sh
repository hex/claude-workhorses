# ABOUTME: Reads the workhorse hosts file and calls the user's sudo-password helper, for mirror.sh, sync.sh and the session-start policy.
# ABOUTME: Both live in $CLAUDE_WORKHORSES_CONFIG_DIR, by default ~/.config/claude-workhorses; values are checked here and never evaluated.
# shellcheck shell=bash

# The folder that holds the hosts file and the sudo-password helper.
workhorses_config_dir() {
  printf '%s\n' "${CLAUDE_WORKHORSES_CONFIG_DIR:-$HOME/.config/claude-workhorses}"
}

# The host options a hosts line may end with, each at most once; provision/host/options.sh applies
# them. wallpaper takes a name from /System/Library/Desktop Pictures/Solid Colors, written with _ for
# each space. Options in host_options_sudo need the workhorse user's sudo password.
host_options_known=(autologin dock firewall git-identity headless key-only-ssh maxfiles no-sleep no-spotlight screensharing tailscale wallpaper wifi-off)
# shellcheck disable=SC2034 # read by provision/sync.sh, which sources this file
host_options_sudo=(autologin firewall key-only-ssh maxfiles no-sleep no-spotlight screensharing tailscale wifi-off)

# Whether word $1 is one of the words after it.
is_one_of() {
  local word=$1 each
  shift
  for each in "$@"; do [ "$each" != "$word" ] || return 0; done
  return 1
}

# Checks one option word from a hosts line; prints the problem and fails.
check_host_option() {
  local option=$1 where=$2 name=$3 key=${1%%=*}
  case "$option" in
    wallpaper=*)
      # options.sh puts the name in a file path and an AppleScript string.
      if ! [[ ${option#wallpaper=} =~ ^[A-Za-z][A-Za-z0-9_]*$ ]]; then
        echo "$where wallpaper \"${option#wallpaper=}\" for $name is not a Solid Colors name (letters and digits, _ for a space)" >&2
        return 1
      fi ;;
    wallpaper | *=*) key="" ;;
  esac
  if [ -z "$key" ] || ! is_one_of "$key" "${host_options_known[@]}"; then
    echo "$where option \"$option\" for $name is not one of: $(printf '%s\n' "${host_options_known[@]}" | sed 's/^wallpaper$/wallpaper=<name>/' | paste -sd, - | sed 's/,/, /g')" >&2
    return 1
  fi
}

# The folder where sync.sh status stores each host's last manifest, which the session-start policy reads.
workhorses_state_dir() {
  printf '%s\n' "${CLAUDE_WORKHORSES_STATE_DIR:-$HOME/.local/state/claude-workhorses}"
}

# A host name: lower-case letters, digits and dashes.
valid_host_name() { [[ $1 =~ ^[a-z0-9][a-z0-9-]*$ ]]; }

# An alias from ~/.ssh/config or user@host. A leading dash would make ssh read it as an option.
valid_ssh_target() { [[ $1 =~ ^[A-Za-z0-9_][A-Za-z0-9._@-]*$ ]]; }

# Reads the hosts file into one array per column, in file order: host_names, host_ssh, host_arch,
# host_cores, host_ram (GB) and host_options (the line's options, space-separated, in its order). One
# host per line, fields split on whitespace; a # starts a comment. Every value is checked here,
# because each one later reaches ssh's argv, a grep pattern, a file name or an AppleScript string.
# Prints the first problem on stderr and fails.
load_hosts() {
  local file line number=0 name ssh arch cores ram rest options=() option seen i
  file="$(workhorses_config_dir)/hosts"
  host_names=() host_ssh=() host_arch=() host_cores=() host_ram=() host_options=()
  host_lines=()
  if [ ! -f "$file" ]; then
    echo "claude-workhorses: no hosts file at $file; the README's First run section shows one" >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    number=$((number + 1))
    line=${line%%#*}
    read -r name ssh arch cores ram rest <<<"$line" || true
    read -r -a options <<<"$rest" || true
    [ -n "$name" ] || continue
    local where="claude-workhorses: $file line $number:"
    if ! valid_host_name "$name"; then
      echo "$where host name \"$name\" is not lower-case letters, digits and dashes" >&2
      return 1
    fi
    for i in "${!host_names[@]}"; do
      if [ "${host_names[$i]}" = "$name" ]; then
        echo "$where host name \"$name\" is already on line ${host_lines[$i]}" >&2
        return 1
      fi
    done
    if ! valid_ssh_target "$ssh"; then
      echo "$where ssh target \"$ssh\" for $name is not an ssh alias or user@host" >&2
      return 1
    fi
    case "$arch" in
      x86_64 | arm64) ;;
      *) echo "$where arch \"$arch\" for $name is not x86_64 or arm64" >&2; return 1 ;;
    esac
    if ! [[ $cores =~ ^[1-9][0-9]*$ ]]; then
      echo "$where cores \"$cores\" for $name is not a whole number" >&2
      return 1
    fi
    if ! [[ $ram =~ ^[1-9][0-9]*$ ]]; then
      echo "$where RAM \"$ram\" for $name is not a whole number of GB" >&2
      return 1
    fi
    # The format before 2026.11.2 had a profile and a wallpaper color where the options now go.
    case "${options[0]:-}" in
      dedicated | shared)
        echo "$where \"${options[0]}\" for $name is the profile column of the hosts format before 2026.11.2, which replaced the profile and color columns with host options; the plugin's examples/hosts shows the new format" >&2
        return 1 ;;
    esac
    seen=" "
    for option in ${options[@]+"${options[@]}"}; do
      check_host_option "$option" "$where" "$name" || return 1
      if [[ $seen == *" ${option%%=*} "* ]]; then
        echo "$where option \"${option%%=*}\" for $name is given twice" >&2
        return 1
      fi
      seen+="${option%%=*} "
    done
    host_names+=("$name") host_ssh+=("$ssh") host_arch+=("$arch") host_cores+=("$cores")
    host_ram+=("$ram") host_options+=("${options[*]+${options[*]}}") host_lines+=("$number")
  done <"$file"
  if [ ${#host_names[@]} -eq 0 ]; then
    echo "claude-workhorses: $file lists no hosts" >&2
    return 1
  fi
}

# Prints the index of host $1 in the arrays load_hosts filled; an unknown name fails, naming the known ones.
host_index() {
  local i
  for i in "${!host_names[@]}"; do
    if [ "${host_names[$i]}" = "$1" ]; then
      echo "$i"
      return 0
    fi
  done
  echo "unknown workhorse \"$1\"; known: ${host_names[*]}" >&2
  return 1
}

# Prints host $1's sudo password, as the user's helper prints it. The helper is an executable in
# the config folder that the user owns and only the user can write; it gets the host name as its
# one argument and its output is the password, never run as shell text.
sudo_password() {
  local helper password status=0
  helper="$(workhorses_config_dir)/sudo-password"
  if [ ! -f "$helper" ] || [ ! -x "$helper" ]; then
    echo "claude-workhorses: no executable sudo-password helper at $helper" >&2
    return 1
  fi
  if [ ! -O "$helper" ]; then
    echo "claude-workhorses: $helper is not owned by you" >&2
    return 1
  fi
  if [ -n "$(find -L "$helper" \( -perm -020 -o -perm -002 \) -print)" ]; then
    echo "claude-workhorses: $helper is writable by others than you; chmod go-w it" >&2
    return 1
  fi
  password=$("$helper" "$1") || status=$?
  if [ $status -ne 0 ]; then
    echo "claude-workhorses: the sudo-password helper failed for $1 (exit $status)" >&2
    return 1
  fi
  if [ -z "$password" ]; then
    echo "claude-workhorses: the sudo-password helper printed nothing for $1" >&2
    return 1
  fi
  printf '%s\n' "$password"
}
