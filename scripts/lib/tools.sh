# ABOUTME: Reads the tools file, which says what each workhorse gets, and finds each line's recipe; for sync.sh and the policy.
# ABOUTME: Every name, argument and filter is checked here, before anything reaches a host; source hosts.sh and run load_hosts first.
# shellcheck shell=bash
# host_names, host_arch, host_os, host_options and host_options_sudo come from hosts.sh.
# shellcheck disable=SC2154

# The recipes that ship with the plugin, and the folder for the user's own.
recipes_builtin_dir() { (cd "$(dirname "${BASH_SOURCE[0]}")/../../provision/recipes" && pwd -P); }
recipes_user_dir() { printf '%s\n' "$(workhorses_config_dir)/recipes"; }

# Fails unless $1 is the user's and nobody else can write it; prints the problem.
owned_by_user_alone() {
  if [ ! -O "$1" ]; then
    echo "$1 is not owned by you"
    return 1
  fi
  if [ -n "$(find -L "$1" -maxdepth 0 \( -perm -020 -o -perm -002 \) -print)" ]; then
    echo "$1 is writable by others than you; chmod go-w it"
    return 1
  fi
}

# Prints the path of recipe $1: the built-in one, else the user's. A user recipe, its folder and the
# config folder above it must all be the user's alone, since the recipe runs on every host it targets.
# Prints the problem and fails otherwise.
recipe_path() {
  local name=$1 builtin user problem
  builtin="$(recipes_builtin_dir)/$name"
  user="$(recipes_user_dir)/$name"
  if [ -f "$builtin" ]; then
    if [ -e "$user" ] || [ -L "$user" ]; then
      echo "user recipe $user has the name of a built-in recipe; rename it"
      return 1
    fi
    printf '%s\n' "$builtin"
    return 0
  fi
  if [ ! -e "$user" ] && [ ! -L "$user" ]; then
    echo "no recipe \"$name\" in $(recipes_builtin_dir) or $(recipes_user_dir)"
    return 1
  fi
  # The checks below would follow a symlink, and the copy would send whatever it points at.
  if [ -L "$user" ]; then
    echo "recipe $user is a symlink; put the file itself there"
    return 1
  fi
  problem=$(owned_by_user_alone "$(workhorses_config_dir)") &&
    problem=$(owned_by_user_alone "$(recipes_user_dir)") &&
    problem=$(owned_by_user_alone "$user") || { echo "$problem"; return 1; }
  if [ ! -f "$user" ] || [ ! -x "$user" ]; then
    echo "recipe $user is not an executable file"
    return 1
  fi
  printf '%s\n' "$user"
}

# Whether line $1, which a host wrote, has the shape of a probe line once probe_line_shaped sets
# probe_line to it with tabs as spaces, each run of spaces as one and none at either end: a lower-case
# name, then at most seven words of letters, digits and ._@:/+,()- with a digit among them, or the
# word "missing" last; 100 characters at most. A job on a host can write what a probe prints, so host
# text reaches Claude only in this shape.
probe_line_shaped() {
  local shape='^[a-z0-9][a-z0-9._+-]*( [A-Za-z0-9._@:/+,()-]+){1,7}$'
  probe_line=${1//$'\t'/ }
  while [[ $probe_line == *"  "* ]]; do probe_line=${probe_line//  / }; done
  probe_line=${probe_line# }
  probe_line=${probe_line% }
  [ ${#probe_line} -le 100 ] && [[ $probe_line =~ $shape ]] &&
    [[ ${probe_line#* } =~ [0-9] || $probe_line == *" missing" ]]
}

# Prints the lines on stdin that probe_line_shaped takes, in its spacing.
shaped_probe_lines() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    ! probe_line_shaped "$line" || printf '%s\n' "$probe_line"
  done
}

# Whether recipe file $1 says, in its first lines, that it runs sudo: a line "# needs: sudo".
recipe_declares_sudo() { head -n 10 "$1" | grep -qx '# needs: sudo'; }

# Reads the tools file into one array per field, in file order: tool_recipe, tool_args (the
# arguments, space-separated), tool_arch (empty: any), tool_os (macos, linux or empty: any),
# tool_hosts (space-separated names; empty: any) and tool_path (the recipe file). A line is a recipe
# name, its arguments, and at most one each of the filters @arch=<arch>, @os=<os> and
# @hosts=<name>,<name>...; a # starts a comment. A missing file is an empty one. Prints the first
# problem on stderr and fails.
load_tools() {
  local file line number=0 words word recipe args arch os hosts host path problem where i
  file="$(workhorses_config_dir)/tools"
  tool_recipe=() tool_args=() tool_arch=() tool_os=() tool_hosts=() tool_path=()
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    number=$((number + 1))
    line=${line%%#*}
    words=()
    read -r -a words <<<"$line" || true
    [ ${#words[@]} -gt 0 ] || continue
    where="claude-workhorses: $file line $number:"
    recipe=${words[0]}
    if ! [[ $recipe =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
      echo "$where recipe \"$recipe\" is not lower-case letters, digits and dashes" >&2
      return 1
    fi
    path=$(recipe_path "$recipe") || { echo "$where $path" >&2; return 1; }
    args="" arch="" os="" hosts=""
    for word in "${words[@]:1}"; do
      case "$word" in
        @*=*)
          if [[ $word =~ ^@arch=(x86_64|arm64)$ ]]; then
            [ -z "$arch" ] || { echo "$where filter @arch for $recipe is given twice" >&2; return 1; }
            arch=${word#@arch=}
          elif [[ $word =~ ^@os=(macos|linux)$ ]]; then
            [ -z "$os" ] || { echo "$where filter @os for $recipe is given twice" >&2; return 1; }
            os=${word#@os=}
          elif [[ $word =~ ^@hosts=[a-z0-9][a-z0-9-]*(,[a-z0-9][a-z0-9-]*)*$ ]]; then
            [ -z "$hosts" ] || { echo "$where filter @hosts for $recipe is given twice" >&2; return 1; }
            hosts=$(tr , ' ' <<<"${word#@hosts=}")
            for host in $hosts; do
              is_one_of "$host" "${host_names[@]}" ||
                { echo "$where filter @hosts names \"$host\", which is not in the hosts file" >&2; return 1; }
            done
          else
            echo "$where filter \"$word\" for $recipe is not @arch=x86_64|arm64, @os=macos|linux or @hosts=<name>,..." >&2
            return 1
          fi ;;
        *)
          # A leading dash would make the recipe's tool read the argument as an option.
          if ! [[ $word =~ ^[A-Za-z0-9@._/+][A-Za-z0-9@._/+-]*$ ]]; then
            echo "$where argument \"$word\" for $recipe is not letters, digits and @._/+- (and does not start with -)" >&2
            return 1
          fi
          if [[ $word == @* && $word != */* ]]; then
            echo "$where argument \"$word\" for $recipe starts with @ but is not a scoped package (@scope/name); a host filter is @arch=<arch>, @os=<os> or @hosts=<names>" >&2
            return 1
          fi
          args+=${args:+ }$word ;;
      esac
    done
    i=${#tool_recipe[@]}
    tool_recipe[i]=$recipe tool_args[i]=$args tool_arch[i]=$arch tool_os[i]=$os tool_hosts[i]=$hosts
    tool_path[i]=$path
  done <"$file"
}

# Whether tools line $1 (an index into the arrays load_tools filled) targets host $2. A line with
# @os needs the host's OS in host_os; without it the line does not target the host, and stderr says so.
tool_targets() {
  local i=$1 host=$2 index
  index=$(host_index "$host") || return 1
  [ -z "${tool_arch[i]}" ] || [ "${tool_arch[i]}" = "${host_arch[index]}" ] || return 1
  if [ -n "${tool_os[i]}" ]; then
    if [ -z "${host_os[index]:-}" ]; then
      echo "claude-workhorses: the OS $host runs is not known, so the @os=${tool_os[i]} filter of ${tool_recipe[i]} cannot be checked" >&2
      return 1
    fi
    [ "${tool_os[i]}" = "${host_os[index]}" ] || return 1
  fi
  # shellcheck disable=SC2086 # the host list is names checked by load_tools, split on purpose
  [ -z "${tool_hosts[i]}" ] || is_one_of "$host" ${tool_hosts[i]}
}

# Prints the tools lines host $1 gets, in file order, without their filters: "<recipe> <args>".
host_tool_lines() {
  local i
  for i in "${!tool_recipe[@]}"; do
    tool_targets "$i" "$1" || continue
    echo "${tool_recipe[i]}${tool_args[i]:+ ${tool_args[i]}}"
  done
}

# Whether a sync of host $1 needs the workhorse user's sudo password: one of its host options needs
# it, or a recipe on one of its lines declares sudo.
host_needs_sudo() {
  local host=$1 index option i
  index=$(host_index "$host") || return 1
  for option in ${host_options[index]}; do
    ! is_one_of "${option%%=*}" "${host_options_sudo[@]}" || return 0
  done
  for i in "${!tool_recipe[@]}"; do
    tool_targets "$i" "$host" || continue
    ! recipe_declares_sudo "${tool_path[i]}" || return 0
  done
  return 1
}
