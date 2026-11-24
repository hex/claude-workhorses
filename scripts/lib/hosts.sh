# ABOUTME: Reads the workhorse hosts file and calls the user's sudo-password helper, for mirror.sh, sync.sh and the session-start policy.
# ABOUTME: Both live in $CLAUDE_WORKHORSES_CONFIG_DIR, by default ~/.config/claude-workhorses; values are checked here and never evaluated.

# The folder that holds the hosts file and the sudo-password helper.
workhorses_config_dir() {
  printf '%s\n' "${CLAUDE_WORKHORSES_CONFIG_DIR:-$HOME/.config/claude-workhorses}"
}

# Reads the hosts file into one array per column, in file order: host_names, host_ssh, host_arch,
# host_cores, host_ram (GB), host_profile and host_colour. One host per line, fields split on
# whitespace, the colour last so it can hold spaces; a # starts a comment. Every value is checked
# here, because each one later reaches ssh's argv, a grep pattern, a file name or an AppleScript
# string. Prints the first problem on stderr and fails.
load_hosts() {
  local file line number=0 name ssh arch cores ram profile colour i
  file="$(workhorses_config_dir)/hosts"
  host_names=() host_ssh=() host_arch=() host_cores=() host_ram=() host_profile=() host_colour=()
  host_lines=()
  if [ ! -f "$file" ]; then
    echo "claude-workhorses: no hosts file at $file; the README's First run section shows one" >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    number=$((number + 1))
    line=${line%%#*}
    read -r name ssh arch cores ram profile colour <<<"$line" || true
    [ -n "$name" ] || continue
    local where="claude-workhorses: $file line $number:"
    if ! [[ $name =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
      echo "$where host name \"$name\" is not lower-case letters, digits and dashes" >&2
      return 1
    fi
    for i in "${!host_names[@]}"; do
      if [ "${host_names[$i]}" = "$name" ]; then
        echo "$where host name \"$name\" is already on line ${host_lines[$i]}" >&2
        return 1
      fi
    done
    # An alias from ~/.ssh/config or user@host. A leading dash would make ssh read it as an option.
    if ! [[ $ssh =~ ^[A-Za-z0-9_][A-Za-z0-9._@-]*$ ]]; then
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
    case "$profile" in
      # setup.sh puts the colour in a wallpaper path and an AppleScript string: letters and spaces only.
      dedicated)
        if ! [[ $colour =~ ^[A-Za-z][A-Za-z\ ]*$ ]]; then
          echo "$where colour \"$colour\" for $name is not a wallpaper colour name (letters and spaces)" >&2
          return 1
        fi ;;
      shared)
        if [ "$colour" != - ]; then
          echo "$where colour \"$colour\" for $name must be - on a shared host, which keeps its owner's wallpaper" >&2
          return 1
        fi ;;
      *) echo "$where profile \"$profile\" for $name is not dedicated or shared" >&2; return 1 ;;
    esac
    host_names+=("$name") host_ssh+=("$ssh") host_arch+=("$arch") host_cores+=("$cores")
    host_ram+=("$ram") host_profile+=("$profile") host_colour+=("$colour") host_lines+=("$number")
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
