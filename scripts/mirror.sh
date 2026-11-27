#!/bin/bash
# ABOUTME: Runs a command on a workhorse in its own copy of a laptop repository, brought level with the laptop first,
# ABOUTME: .git included. Usage: mirror.sh run [--timeout <seconds>] <host[,host...]|auto> <dir> <command...>; wh is the short form.
set -euo pipefail

# shellcheck source=lib/hosts.sh
. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/lib/hosts.sh"
# shellcheck source=lib/bounded.sh
. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/lib/bounded.sh"

# The hosts, in the hosts file's order, which breaks ties when wh picks one. run fills it.
all_hosts=()

# The ssh target the hosts file gives a workhorse. The laptop's ~/.ssh/config decides the route: a
# LAN name where the host answers on one, since Tailscale encrypts in a userspace network extension
# and a bulk copy through it kept about 2.5 laptop cores busy.
ssh_target() {
  local i
  i=$(host_index "$1") || exit 2
  echo "${host_ssh[$i]}"
}

# Dependency and build caches that are machine-specific (arm64 on the laptop, x86_64 on a mini):
# each side keeps its own, and the mini rebuilds them. .cs/ is cs session state (locks, heartbeats,
# narratives) that the laptop rewrites constantly and that means nothing on another machine.
ignores=(node_modules/ target/ .venv/ venv/ Library/ .build/ .gradle/ DerivedData/ __pycache__/ .DS_Store .cs/)

# A first copy sends the whole repository. Through Tailscale that keeps laptop cores busy (WireGuard
# runs in userspace), so a copy with no .git yet whose first copy, .git and files together, is larger
# than this many MB waits for a network that reaches the host without Tailscale. run checks the value.
tailscale_first_copy_mb=${WORKHORSES_TAILSCALE_FIRST_COPY_MB:-1024}

# Whether address $1 is in Tailscale's range, 100.64.0.0/10.
in_tailscale_range() {
  case "$1" in
    100.6[4-9].* | 100.[7-9][0-9].* | 100.1[01][0-9].* | 100.12[0-7].*) return 0 ;;
    *) return 1 ;;
  esac
}

# Print the route for the first-copy warning. Several VPNs use utun interfaces, so check
# the interface's own IPv4 addresses before counting a route to a host's LAN address.
tailscale_route() {
  local server=$1 interface addresses address
  if in_tailscale_range "$server"; then
    echo "$server"
    return 0
  fi
  [ "$(uname -s)" = Darwin ] && [[ $server =~ ^[0-9a-fA-F:.]+$ ]] || return 1
  interface=$(route -n get "$server" 2>/dev/null | awk '$1 == "interface:" {print $2}') || return 1
  [ -n "$interface" ] || return 1
  addresses=$(ifconfig "$interface" 2>/dev/null | awk '$1 == "inet" {print $2}') || return 1
  while read -r address; do
    if in_tailscale_range "$address"; then
      echo "$server via $interface"
      return 0
    fi
  done <<<"$addresses"
  return 1
}

# The copy of the repository at $1 on a workhorse, a path under ~: its folder name and a hash of its laptop path.
work_name() { echo "work/$(printf '%s' "${1##*/}" | tr -c 'A-Za-z0-9._-' '_')-$(printf '%s' "$1" | shasum | cut -c1-8)"; }

# Runs an argv on a workhorse. Each argument is quoted for the host's login shell (zsh on a Mac, which
# reads ~/.zshenv for PATH; bash on Linux, which reads the top of ~/.bashrc when sshd starts it), so
# paths and commands cross SSH as data, never as shell text.
remote() {
  local target=$1 command
  shift
  # printf -v, not a command substitution: after a write to a closed stderr, bash 3.2 would put the
  # failed text in front of the command.
  printf -v command '%q ' "$@"
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" "$command"
}

blocked() {
  echo "mirror.sh run: BLOCKED: $*" >&2
  end_reason=$(head -n 1 <<<"$*")
  exit 3
}

# Every run appends a start line and an end line, one JSON object each, to the run log that the
# workhorse-runs mod reads: which mini, which repository and subfolder, which command, and how the
# run ended. The start line carries this script's pid, so a run killed before it could write its end
# line (SIGKILL, power loss) can be told apart from one still going, and the Claude Code session that
# started the run when CLAUDE_CODE_SESSION_ID holds one (Claude Code sets it for the commands it runs;
# other agents and terminals do not).
run_log=$HOME/.local/state/workhorse/runs.jsonl
run_id="" run_ended=0 end_reason=""
# What a signal or the way out acts on: the phase (prepare while the host takes the lock, copy while the
# copy is made, then job; refused when another run's lock turned this run away, so it holds none), the
# host, the copy and this run's line in its lock's owner file, and the ssh that runs the job.
phase="" run_host="" run_target="" run_work="" run_owner="" job_ssh=""

# Prints a run's start line and sets run_id.
start_line() {
  local host=$1 dir=$2 sub=$3 session=""
  shift 3
  run_id="$(hostname -s)-$$-$(date +%s)"
  [[ ${CLAUDE_CODE_SESSION_ID:-} =~ ^[A-Za-z0-9-]{1,64}$ ]] && session=$CLAUDE_CODE_SESSION_ID
  jq -nc --arg id "$run_id" --argjson at "$(date +%s)" --arg host "$host" --arg dir "$dir" --arg sub "$sub" \
    --arg command "$*" --argjson pid "$$" --arg session "$session" \
    '{event: "start", id: $id, at: $at, host: $host, dir: $dir, sub: $sub, command: $command, pid: $pid}
      + (if $session == "" then {} else {session: $session} end)'
}

log_start() {
  mkdir -p "$(dirname "$run_log")"
  start_line "$@" >>"$run_log"
}

log_synced() {
  jq -nc --arg id "$run_id" --argjson at "$(date +%s)" '{event: "synced", id: $id, at: $at}' >>"$run_log"
}

# Prints the run's end line, exit $1 and end_reason, once: later calls print nothing.
end_line() {
  [ -n "$run_id" ] && [ "$run_ended" = 0 ] || return 0
  run_ended=1
  jq -nc --arg id "$run_id" --argjson at "$(date +%s)" --argjson exit "$1" --arg reason "$end_reason" \
    '{event: "end", id: $id, at: $at, exit: $exit} + (if $reason == "" then {} else {reason: $reason} end)'
}

log_end() {
  end_line "$1" >>"$run_log"
}

# BLOCKED before the run's start line was written (no workhorse free, say): the start line and its end
# line go to the run log one right after the other, through one append, so the mod still toasts the end
# and no reader ever sees the run going. Takes the host, the folder and subfolder, the message, then the
# command.
blocked_unstarted() {
  local host=$1 dir=$2 sub=$3 message=$4
  shift 4
  end_reason=$(head -n 1 <<<"$message")
  mkdir -p "$(dirname "$run_log")"
  { start_line "$host" "$dir" "$sub" "$@"; end_line 3; } >>"$run_log"
  blocked "$message"
}

# Narrows all_hosts to the hosts in the comma-separated list $1, in the hosts file's order. An unknown
# name or an empty one fails, naming the known hosts.
narrow_hosts() {
  local list=$1 rest=$1, name kept=()
  while [ -n "$rest" ]; do
    name=${rest%%,*}
    rest=${rest#*,}
    host_index "$name" >/dev/null || return 1
  done
  for name in "${host_names[@]}"; do
    [[ ,$list, != *",$name,"* ]] || kept+=("$name")
  done
  all_hosts=("${kept[@]}")
}

# What a host sends is data. plain, a jq function, makes a string one line of text: tabs and line breaks
# become spaces, and control characters and the characters that reorder or hide text (bidi controls,
# zero-width characters) go.
plain_jq='def plain: gsub("[\\t\\n\\r]"; " ")
  | gsub("[\\x{0}-\\x{1f}\\x{7f}-\\x{9f}\\x{200b}-\\x{200f}\\x{202a}-\\x{202e}\\x{2066}-\\x{2069}\\x{feff}]"; "")
  | sub("^ +"; "") | sub(" +$"; "");'
# plain <max> prints the host's text on its stdin as plain text of at most <max> characters, with " [cut]"
# after a cut. It reads the text from stdin, as a host's answer can be larger than a command's
# arguments may be, and makes plain only its first 4 * <max> characters: gsub's time grows with the
# square of the characters it removes.
plain() {
  jq -Rrs --argjson max "$1" "$plain_jq"' rtrimstr("\n") as $all | ($all[:4 * $max] | plain) as $text
    | if ($all | length) > 4 * $max or ($text | length) > $max then $text[:$max] + " [cut]" else $text end'
}
# Prints the lock owner file on stdin as messages show it, after all of wh's own words: plain, at most 300
# characters, in double quotes with any quote or backslash inside escaped, so no text a host wrote can
# close the quote and pass for wh's. Prints nothing for an empty owner file.
quoted_owner() { plain 300 | jq -R 'select(length > 0)'; }

# The reasons lock_state gives for a stale lock. A host's answer that names a stale lock is taken only
# with one of these.
stale_why='(the host has restarted since the lock was taken|its process [0-9]+ is gone|its pid file holds no process id|it holds no pid and is over an hour old)'
# The one stale reason that does not mean the run has ended: a run copies before its job writes a pid, and
# a first copy of a large repository can take over an hour. Every message that names it says so.
no_pid_why='it holds no pid and is over an hour old'

# Turns host $1's answer to pick_host's probe, from an ssh that exited $2, into one probe line for
# choose_host. The answer's lines come joined by spaces: the load line, the physical core count, the
# number of runs going there (locks in ~/work), and whether it holds the copy: copy, busy when another
# run holds the copy's lock, "stale <why>" when its lock is stale, or none. A Mac's load line is vm.loadavg's "{ 1.39 1.37 1.32 }"; a Linux host's is /proc/loadavg's
# "0.52 0.40 0.30 1/215 1245". Either way the first number is the 1-minute load.
probe_answer() {
  local host=$1 status=$2 answer=$3 load cores runs copy
  if [ "$status" != 0 ]; then
    echo "$host unreachable"
    return 0
  fi
  case "$answer" in
    "{ "*) read -r _ load _ _ _ cores runs copy <<<"$answer" ;;
    *) read -r load _ _ _ _ cores runs copy <<<"$answer" ;;
  esac
  if [[ $load =~ ^[0-9]+([.][0-9]+)?$ && $cores =~ ^[1-9][0-9]*$ && $runs =~ ^[0-9]+$ && $copy =~ ^(copy|busy|none|stale\ $stale_why)$ ]]; then
    echo "$host ok $load $cores $runs $copy"
  else
    echo "$host unexpected $(plain 200 <<<"$answer")"
  fi
}

# Picks the workhorse for a job from one probe line per host, in all_hosts order: "<host> ok <load>
# <cores> <runs> copy|busy|none|stale <why>", "<host> unreachable" or "<host> unexpected <answer>". It
# passes over a host whose copy another run holds, or a stale lock holds, since this run would find it locked. Among the hosts whose
# 1-minute load is below their physical core count, it ranks each by its load plus its runs going, per
# core: the 1-minute average lags, so a run that started seconds ago counts as one busy core. A host
# that holds the repository's copy (and so its installed dependencies) comes first while that figure
# is under half; past it, the least busy host wins, so work spreads over the hosts instead of piling on
# the one with the copy. Ties go to table order. Prints the host; when none is free, prints each host's
# reason on stderr and fails.
choose_host() {
  awk -v no_pid_why="$no_pid_why" '
    $2 != "ok" { reasons[NR] = $1 ": " substr($0, length($1) + 2); next }
    !($3 < $4) { reasons[NR] = $1 ": load " $3 " of " $4 " cores"; next }
    $6 == "busy" { reasons[NR] = $1 ": another run holds its copy"; next }
    $6 == "stale" { why = $0; sub(/^[^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+ /, "", why); reasons[NR] = $1 ": its copy\047s lock is stale: " why (why == no_pid_why ? ", and its run may still be copying" : ""); next }
    {
      ratio = ($3 + $5) / $4
      rank = ($6 == "copy" && ratio < 0.5) ? 0 : 1
      if (best == "" || rank < best_rank || (rank == best_rank && ratio < best_ratio)) {
        best = $1; best_rank = rank; best_ratio = ratio
      }
    }
    END {
      if (best != "") { print best; exit 0 }
      for (i = 1; i <= NR; i++) if (i in reasons) print reasons[i] > "/dev/stderr"
      exit 1
    }'
}

# The one definition of a work copy's lock, for every script that reads one on a host: prepare, the
# probe, wh hosts and wh stop. Plain sh, since a host runs it under dash, zsh, and bash 3.2 or 5.
# lock_state <lock> prints one line:
#   free              no lock
#   preparing         no pid file yet, under an hour old: a run takes the lock and copies
#   running <pid>     its pid file names a live process, and its boot file, if any, this boot
#   stale <why>       any other lock: the host restarted since, its process is gone, its pid file holds
#                     no pid, or it has no pid file and is over an hour old
# A lock written before boot files existed has none and reads as this boot, as it did then. A stale lock
# is never removed here: whoever reads one says so and names the command that removes it.
lock_state=$(cat <<'SCRIPT'
wh_boot_id() {
  if [ "$(/usr/bin/uname -s)" = Darwin ]; then /usr/sbin/sysctl -n kern.bootsessionuuid; else cat /proc/sys/kernel/random/boot_id; fi 2>/dev/null || :
}
lock_state() {
  if [ ! -d "$1" ]; then
    echo free
    return 0
  fi
  wh_boot=$(wh_boot_id)
  if [ -s "$1/boot" ] && [ -n "$wh_boot" ] && [ "$(cat "$1/boot")" != "$wh_boot" ]; then
    echo "stale the host has restarted since the lock was taken"
  elif [ -s "$1/pid" ]; then
    wh_pid=$(cat "$1/pid")
    case "$wh_pid" in
      ("" | 0* | *[!0-9]*) echo "stale its pid file holds no process id" ;;
      (*) if kill -0 "$wh_pid" 2>/dev/null; then echo "running $wh_pid"; else echo "stale its process $wh_pid is gone"; fi ;;
    esac
  elif [ -n "$(find "$1" -maxdepth 0 -mmin -60)" ]; then
    echo preparing
  else
    echo "stale it holds no pid and is over an hour old"
  fi
}
SCRIPT
)

# The probe's count of runs going on a host, run by the host's login shell: the locks in ~/work that
# lock_state calls preparing or running. With wh_list=1 set before it, it first prints each counted lock
# as a line of three tab-separated fields: "lock", the lock's name without .lock, and its owner file with
# newlines and tabs made spaces (empty without an owner file).
count_runs="$lock_state"$'\n''n=0; for l in $(find ~/work -maxdepth 1 -name "*.lock" -type d 2>/dev/null); do case "$(lock_state "$l")" in preparing | "running "*) ;; *) continue ;; esac; n=$((n + 1)); if [ "${wh_list:-}" = 1 ]; then w=${l##*/}; printf "lock\t%s\t%s\n" "${w%.lock}" "$(if [ -f "$l/owner" ]; then tr "\n\t" "  " <"$l/owner"; fi)"; fi; done; echo $n'

# The probe's last line for the copy at $1, a path under ~, after count_runs has defined lock_state:
# busy while a run holds its lock, "stale <why>" for a stale lock, else copy when the copy exists or none.
copy_probe() {
  local lock work
  lock=$(printf '%q' "$1.lock") work=$(printf '%q' "$1")
  echo "wh_copy=\$(lock_state ~/$lock); case \"\$wh_copy\" in preparing | \"running \"*) echo busy ;; \"stale \"*) echo \"\$wh_copy\" ;; *) if test -d ~/$work; then echo copy; else echo none; fi ;; esac"
}

# A host's load line, then its physical core count, run by the host's login shell. Linux counts
# physical cores as the distinct core and socket pairs lscpu lists, since nproc counts each core's
# hyperthreads.
load_and_cores='if [ "$(uname -s)" = Darwin ]; then /usr/sbin/sysctl -n vm.loadavg hw.physicalcpu; else cat /proc/loadavg; lscpu -p=core,socket | grep -v "^#" | sort -u | wc -l; fi'

# Runs shell text $2 on every workhorse at once, each ssh stopped after $1 seconds, and leaves each
# host's answer in folder $3: its output in <host> and the ssh's exit code in <host>.status. A host
# that has not answered by then counts as unreachable: ssh's ConnectTimeout does not cover the name
# lookup, and a .local name that nobody answers takes 5 seconds to fail.
probe_hosts() {
  local seconds=$1 script=$2 answers=$3 host
  for host in "${all_hosts[@]}"; do
    {
      # set -e would end this subshell on a failed probe before it wrote the status.
      local status=0
      run_bounded "$seconds" ssh -o BatchMode=yes -o ConnectTimeout="$seconds" "$(ssh_target "$host")" "$script" \
        >"$answers/$host" 2>/dev/null || status=$?
      echo "$status" >"$answers/$host.status"
    } &
  done
  wait
}

# Asks every workhorse at once, for at most 2 seconds, for its load, its physical core count, its runs
# going and whether it holds the copy $1 (a path under ~), lets choose_host pick, and names the choice
# on stderr. When none is free, prints each host's reason instead and fails.
pick_host() {
  local work=$1 answers host answer load cores runs copy probes="" chosen state why target
  answers=$(mktemp -d "${TMPDIR:-/tmp}/wh-pick.XXXX")
  probe_hosts 2 "$load_and_cores; $count_runs; $(copy_probe "$work")" "$answers"
  for host in "${all_hosts[@]}"; do
    answer=$(tr '\n' ' ' <"$answers/$host")
    probes+="$(probe_answer "$host" "$(cat "$answers/$host.status")" "$answer")"$'\n'
  done
  rm -rf "$answers"
  # A stale lock bars the copy until someone removes it, so it is named whichever host runs the job.
  while read -r host state _ _ _ copy why; do
    [ "$state $copy" = "ok stale" ] || continue
    target=$(ssh_target "$host")
    if [ "$why" = "$no_pid_why" ]; then
      echo "mirror.sh run: passing over $host, whose lock on this copy is stale ($why); its run may still be copying, so check that wh ps on the machine its owner file names (ssh $target 'cat -v ~/$work.lock/owner') no longer lists it before you remove the lock with: ssh $target 'rm -r ~/$work.lock'" >&2
    else
      echo "mirror.sh run: passing over $host, whose lock on this copy is stale ($why); remove it with: ssh $target 'rm -r ~/$work.lock'" >&2
    fi
  done <<<"$probes"
  if ! chosen=$(choose_host <<<"${probes%$'\n'}" 2>/dev/null); then
    choose_host <<<"${probes%$'\n'}" 2>&1 >/dev/null || true
    return 1
  fi
  read -r _ _ load cores runs copy < <(grep "^$chosen " <<<"$probes")
  if [ "$copy" = copy ]; then copy="it holds the copy"; else copy="first copy there"; fi
  [ "$runs" = 0 ] || copy="$runs runs going, $copy"
  echo "mirror.sh run: using $chosen (load $load of $cores cores, $copy)" >&2
  echo "$chosen"
}

# Prints one line per entry of the copy in the current folder (mode, size, modification time to the
# nanosecond, ./path), sorted, leaving out the repository's own .git and every name in $1 (one per
# line), the same names the patch leaves out. Two listings of one copy differ where something changed it.
# The scripts that run on a host call the system's own tools by path: on a Mac, a GNU stat or find
# that a tool install put first on the host's PATH reads these options differently. A Linux host's
# GNU find prints the type as a letter, the permission bits alone and ten digits of fraction; awk
# turns that into the line macOS's stat prints, the mode in octal with its type bits and nine digits.
list_copy=$(cat <<'SCRIPT'
list_copy() {
  local prune=() name
  while IFS= read -r name; do prune+=(-name "$name" -o); done <<<"$1"
  if [ "$(/usr/bin/uname -s)" = Darwin ]; then
    /usr/bin/find . -mindepth 1 \( "${prune[@]}" -path ./.git \) -prune -o -exec /usr/bin/stat -f '%p %z %Fm %N' {} +
  else
    /usr/bin/find . -mindepth 1 \( "${prune[@]}" -path ./.git \) -prune -o -printf '%y %m %s %T@ %p\n' |
      /usr/bin/awk 'BEGIN { split("f 10 d 4 l 12 p 1 c 2 b 6 s 14", t, " "); for (i = 1; i < 14; i += 2) type[t[i]] = t[i + 1] }
        {
          kind = $1; mode = $2; size = $3; time = $4
          # The path is the rest of the line, spaces and all.
          path = substr($0, length(kind) + length(mode) + length(size) + length(time) + 5)
          printf "%s%04d %s %s %s\n", type[kind], mode, size, substr(time, 1, index(time, ".") + 9), path
        }'
  fi | LC_ALL=C /usr/bin/sort
}
SCRIPT
)

# Takes the lock and makes a first copy when there is none: from the seed, this workhorse's copy of the
# main checkout when the repository is a linked worktree and that copy exists, else an empty folder the
# laptop fills. Prints "warm" when an earlier run left the copy with the
# laptop's file times (the <work>.times marker), so size and time are enough to compare; else "new";
# then, on the same line, the address the laptop's ssh reached this host on and "git" when the copy
# already holds a .git folder, so the laptop sends only what changed in it, else "nogit".
# The second line is the Watchman clock the last run stored, or empty. When there is one, the lines
# after it are where the copy's listing differs from the one taken after the last patch: what the
# last job changed, added or deleted.
# When another run's lock is in the way, it prints "locked <lock_state>" and the lock's owner file instead,
# and fails.
prepare_work_copy="$list_copy"$'\n'"$lock_state"$'\n'$(cat <<'SCRIPT'
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
work=$HOME/$1 lock=$HOME/$1.lock owner=$2 seed=$3 names=$4
shift 4
mkdir -p "$(dirname "$work")"
if ! mkdir "$lock" 2>/dev/null; then
  printf 'locked %s\n%s\n' "$(lock_state "$lock")" "$(cat "$lock/owner" 2>/dev/null || echo "lock without owner")"
  exit 1
fi
echo "$owner" >"$lock/owner"
boot=$(wh_boot_id)
[ -z "$boot" ] || echo "$boot" >"$lock/boot"
# The way out of a prepare that did not finish frees the lock, unless a run stopped from the laptop has
# freed it already and a successor's is in its place. The owner is read with read, not a command
# substitution: after a write to the closed connection, bash 3.2 would put the failed text in front of it.
free_own_lock() {
  trap '' PIPE HUP INT TERM
  local mine=""
  IFS= read -r -d '' mine 2>/dev/null <"$lock/owner" || :
  [ "$mine" != "$owner"$'\n' ] || rm -rf "$lock"
}
trap free_own_lock EXIT
# A dropped connection ends this shell by signal, which skips the EXIT trap; exit through it instead.
trap 'exit 141' PIPE
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
if [ ! -d "$work" ]; then
  rm -f "$work.times" "$work.listing" "$work.clock"
  mkdir "$work"
  if [ -n "$seed" ] && [ -d "$HOME/$seed" ]; then
    echo "mirror.sh run: first copy here; starting from ~/$seed" >&2
    rsync -a "$@" "$HOME/$seed/" "$work/"
  else
    echo "mirror.sh run: first copy here; the laptop sends every file" >&2
  fi
fi
# .git comes from the laptop as a folder; a copy made from a worktree's gitfile has a file there.
[ ! -f "$work/.git" ] || rm -f "$work/.git"
server=$(echo "$SSH_CONNECTION" | awk '{print $3}')
git=nogit
[ ! -d "$work/.git" ] || git=git
if [ ! -e "$work.times" ]; then
  printf 'new %s %s\n\n' "$server" "$git"
elif [ ! -e "$work.listing" ] || [ ! -e "$work.clock" ]; then
  printf 'warm %s %s\n\n' "$server" "$git"
else
  printf 'warm %s %s\n%s\n' "$server" "$git" "$(cat "$work.clock")"
  cd "$work"
  list_copy "$names" >"$work.listing.now"
  LC_ALL=C comm -3 "$work.listing" "$work.listing.now"
  rm -f "$work.listing.now"
fi
trap - EXIT
SCRIPT
)

# Runs the job of the run whose owner line is $2 in subfolder $3 of the work copy $1, and releases the
# lock when it ends, even if the laptop disconnects. Before the job starts, it stores the copy's listing
# and the Watchman clock the patch went by (none when $4 is empty), which the next run compares against.
# The job runs in its own process group. With a limit of $6 seconds (0: none), past the limit the whole
# group gets SIGTERM, then SIGKILL 10 seconds later; the run then exits 124, as gtimeout does. If this
# shell dies by signal first (wh stop sends SIGTERM), the group gets the same before the lock goes.
# The job starts only under this run's lock: with none, or one another run took after this run's was
# removed, it writes this run's owner line and the lock's owner file it found (none without a lock) to
# <work>.refused, touches nothing else and exits 3. take_refusal reads that file, as 3 can be the job's own.
run_job="$list_copy"$'\n'$(cat <<'SCRIPT'
lock=$HOME/$1.lock work=$HOME/$1 limited=$HOME/$1.limit owner=$2
job="" timer="" job_ended="" found=""
IFS= read -r -d '' found 2>/dev/null <"$lock/owner"
case "$found" in
  ("$owner:"*) ;;
  (*)
    { printf '%s\n' "$owner"; [ ! -d "$lock" ] || printf '%s' "${found:-lock without owner}"; } >"$work.refused"
    exit 3 ;;
esac
# Waits up to 10 s for the job's process group to empty, then sends what is left SIGKILL and waits,
# up to 5 s more, until the last of it is gone.
reap_job() {
  local waited=0
  while [ $waited -lt 10 ] && kill -0 -- "-$job" 2>/dev/null; do /bin/sleep 1; waited=$((waited + 1)); done
  kill -s KILL -- "-$job" 2>/dev/null || return 0
  waited=0
  while [ $waited -lt 50 ] && kill -0 -- "-$job" 2>/dev/null; do /bin/sleep 0.1; waited=$((waited + 1)); done
}
# The way out, however this shell ends: a job still running is stopped before the lock goes. A signal
# here would cut it short, and the laptop may be gone, so it takes none and writes nothing.
cleanup() {
  trap '' PIPE HUP INT TERM
  [ -z "$timer" ] || kill -s KILL -- "-$timer" 2>/dev/null || true
  if [ -n "$job" ] && [ -z "$job_ended" ]; then
    kill -s TERM -- "-$job" 2>/dev/null || true
    reap_job
  fi
  # read, not a command substitution: after a write to the closed connection, bash 3.2 would put the
  # failed text in front of the owner.
  local mine=""
  IFS= read -r -d '' mine 2>/dev/null <"$lock/owner"
  /bin/rm -f "$limited"
  case "$mine" in ("$owner:"*) /bin/rm -rf "$lock" ;; esac
}
trap cleanup EXIT
# The probe counts this run as going while this shell lives.
echo $$ >"$lock/pid"
# A dropped connection ends this shell by signal, which skips the EXIT trap; exit through it instead.
# After the laptop goes, the first write to the closed connection (bash reporting how the job ended)
# raises SIGPIPE.
trap 'exit 141' PIPE
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
# The patch has carried the laptop's file times, so later runs can compare by size and time.
/usr/bin/touch "$work.times"
# Without a listing or a clock, the next run compares every file.
/bin/rm -f "$work.listing" "$work.clock"
if [ -n "$4" ] && (cd "$work" && list_copy "$5") >"$work.listing.new"; then
  /bin/mv "$work.listing.new" "$work.listing"
  printf '%s\n' "$4" >"$work.clock"
fi
/bin/rm -f "$work.listing.new"
cd "$work/$3" || exit 1
limit=$6
shift 6
# The timer leaves this file when the limit passes; it lies outside the lock, which a signal can remove first.
/bin/rm -f "$limited"
# Job control gives the job, and the timer, a process group of its own, so a signal to this shell
# (wh stop sends SIGTERM) reaches the whole job whether or not it has a limit. While it is on, bash 5
# reports a job that has already ended (a builtin, say) on this shell's stderr, which is the job's, so
# this shell's stderr goes to /dev/null until it is off and the job gets the real one as descriptor 2.
exec 3>&2 2>/dev/null
set -m
"$@" 2>&3 3>&- &
job=$!
if [ "$limit" != 0 ]; then
  (/bin/sleep "$limit" && : >"$limited" && kill -s TERM -- "-$job" && /bin/sleep 10 && kill -s KILL -- "-$job") \
    </dev/null >/dev/null 2>&1 3>&- &
  timer=$!
fi
set +m
exec 2>&3 3>&-
status=0
wait "$job" || status=$?
# The job's first process can end while others it started ignore the SIGTERM; they get SIGKILL now.
[ ! -e "$limited" ] || reap_job
job_ended=yes
if [ -n "$timer" ]; then
  kill -s TERM -- "-$timer" 2>/dev/null || true
  # bash reports the timer it stopped on wait's stderr, which is the job's.
  wait "$timer" 2>/dev/null || true
  timer=""
fi
if [ -e "$limited" ]; then
  echo "mirror.sh run: the command ran past its $limit s limit and was stopped" >&2
  exit 124
fi
exit "$status"
SCRIPT
)

# Reports how many files an rsync patched, from its -i output on stdin. openrsync itemizes neither a
# changed executable bit nor a retargeted symlink, so the count leaves both out. It takes itemized
# lines only, less those whose only flag is t (time); rsync's warnings go to stderr.
report_patched() {
  local out patched
  out=$(cat)
  [ -z "$out" ] && return 0
  grep -vE '^[<>ch.*][fdLDS]' <<<"$out" >&2 || true
  patched=$(grep -E '^[<>ch.*][fdLDS]' <<<"$out" | grep -vE '^\.[a-zA-Z]\.\.[Tt]\.+ ' || true)
  [ -z "$patched" ] || echo "mirror.sh run: patched $(wc -l <<<"$patched" | tr -d ' ') files from the laptop" >&2
}

# Asks Watchman which paths in the repository at $1 changed since clock $2; with no clock, it asks
# from one Watchman never issued, which it answers as having no record. Prints Watchman's answer: the
# clock now, is_fresh_instance when it has no record back to that clock, and the changed names.
watchman_changes() {
  local watch
  command -v watchman >/dev/null || { echo "mirror.sh run: Watchman is not installed" >&2; return 1; }
  watch=$(watchman watch-project "$1") || return 1
  jq -c --arg since "${2:-c:0:0}" '["query", .watch,
    {since: $since, fields: ["name"], empty_on_fresh_instance: true}
    + (if .relative_path then {relative_root: .relative_path} else {} end)]' <<<"$watch" | watchman -j
}

# Joins the names Watchman says changed on the laptop (its answer on stdin) with the paths in file $1,
# the lines where the copy's listing changed since the last patch. Prints "ok" and then each path to patch,
# leaving out the repository's own .git and every path with one of the names in $2 (a JSON array), as
# the full walk does. Prints "walk: <reason>" instead when a path is not one it can handle safely.
changed_paths() {
  jq -r --rawfile copy "$1" --argjson names "$2" '
    def plain: length > 0 and (startswith("/") | not) and (contains("\n") | not)
      and (split("/") | all(. != "" and . != "." and . != ".."));
    def patched: . != ".git" and (startswith(".git/") | not)
      and (any(split("/")[]; . as $part | any($names[]; . == $part)) | not);
    "^[0-7]+ [0-9]+ [0-9]+\\.[0-9]+ \\./(?<path>.+)$" as $line
    | ($copy | split("\n") | map(select(. != "") | ltrimstr("\t")
        | if test($line) then capture($line).path else null end)) as $copied
    | ((.files // []) + $copied) as $all
    | if any($all[]; . == null) then "walk: the copy holds a name its listing cannot carry (a newline in it?)"
      elif any($all[]; plain | not) then "walk: a changed path is not a plain relative path"
      else "ok", ($all | unique | .[] | select(patched))
      end'
}

# Removes from the copy in $HOME/$1 each path read from stdin as a D record (D, path) and makes each
# symlink read as an L record (L, path, target), every field NUL-terminated so a name stays data.
# openrsync cannot send a symlink that points nowhere from a list of names, so symlinks go this way.
# A job can swap a folder of the copy for a symlink that leads out of it; a path whose nearest existing
# parent resolves outside the copy fails the step, and the walk that follows replaces the symlink.
apply_records=$(cat <<'SCRIPT'
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
cd -P "$HOME/$1"
copy=$PWD
deletes=()
# Builtins only inside the loop: a job can leave tens of thousands of records.
while IFS= read -r -d '' kind && IFS= read -r -d '' path; do
  parent=.
  case "$path" in (*/*) parent=${path%/*} ;; esac
  while [ ! -e "$parent" ]; do
    case "$parent" in (*/*) parent=${parent%/*} ;; (*) parent=. ;; esac
  done
  cd -P -- "$parent"
  case "$PWD/" in
    ("$copy"/*) ;;
    (*) echo "mirror.sh run: $path in the copy lies under a symlink that leads out of it" >&2; exit 1 ;;
  esac
  cd "$copy"
  if [ "$kind" = L ]; then
    IFS= read -r -d '' target
    rm -rf -- "$path"
    case "$path" in (*/*) mkdir -p -- "${path%/*}" ;; esac
    ln -s -- "$target" "$path"
  else
    deletes+=("$path")
  fi
done
[ ${#deletes[@]} -eq 0 ] || printf '%s\0' "${deletes[@]}" | xargs -0 rm -rf --
SCRIPT
)

# Brings the copy's .git level with the laptop's, so git there sees the laptop's commits, branch and
# index. A linked worktree's .git on the laptop is a file naming a folder in the main checkout; in the
# copy it becomes an ordinary repository: the shared folder, then the worktree's own HEAD, index and
# reflog over it. Lock files stay behind, as a git command on the laptop holds one only for a moment.
# The worktree's own files go by checksum: a copy seeded from the main checkout's holds that HEAD,
# which can match the worktree's in size (main and side) and in the whole second that openrsync's
# protocol 29 compares, so a comparison by size and time would keep the main checkout's HEAD.
sync_git() {
  local dir=$1 target=$2 work=$3 common own ssh=(-e "ssh -o BatchMode=yes -o ConnectTimeout=10")
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir)
  own=$(git -C "$dir" rev-parse --absolute-git-dir)
  if [ "$common" = "$own" ]; then
    rsync -a --delete --exclude '*.lock' "${ssh[@]}" "$common/" "$target:$work/.git/"
  else
    rsync -a --delete --exclude '*.lock' --exclude /worktrees/ --exclude /HEAD --exclude /ORIG_HEAD \
      --exclude /index --exclude /logs/HEAD "${ssh[@]}" "$common/" "$target:$work/.git/" &&
      rsync -a -c --exclude '*.lock' --exclude /commondir --exclude /gitdir "${ssh[@]}" "$own/" "$target:$work/.git/"
  fi
}

# Patches only the given paths: deletes from the copy those the laptop no longer has and remakes its
# symlinks, then sends the rest with their times. Fails when either step does, so the caller walks
# every file instead.
patch_listed() {
  local dir=$1 target=$2 work=$3 path out records=() sends=()
  shift 3
  for path in "$@"; do
    if [ -L "$dir/$path" ]; then records+=(L "$path" "$(readlink "$dir/$path")")
    elif [ -e "$dir/$path" ]; then sends+=("$path")
    else records+=(D "$path"); fi
  done
  if [ ${#records[@]} -gt 0 ]; then
    printf '%s\0' "${records[@]}" | remote "$target" /bin/bash -c "$apply_records" _ "$work" || return 1
  fi
  if [ ${#sends[@]} -gt 0 ]; then
    out=$(printf '%s\0' "${sends[@]}" | rsync -lti --executability --from0 --files-from=- \
      -e "ssh -o BatchMode=yes -o ConnectTimeout=10" "$dir/" "$target:$work/") || return 1
    report_patched <<<"$out"
  fi
}

# Runs a command on a workhorse against a private copy of one laptop repository, after patching the
# copy to match the laptop. The laptop is the source of truth, .git included. The patch compares every
# file's contents on a copy's first run, which
# also gives the copy the laptop's file times; later runs patch only the paths Watchman saw change on
# the laptop and the paths the last job changed in the copy, or compare size and modification time
# of every file when either list is in doubt.
run() {
  local limit=0
  if [ "${1:-}" = --timeout ]; then
    limit=${2:-}
    shift 2 || true
  fi
  [ $# -ge 3 ] && [[ $limit =~ ^(0|[1-9][0-9]*)$ ]] ||
    { echo "usage: $0 run [--timeout <seconds>] <host[,host...]|auto> <dir> <command...>" >&2; exit 2; }
  # Seven digits at most, so the size in KB stays far inside shell arithmetic.
  [[ $tailscale_first_copy_mb =~ ^[1-9][0-9]{0,6}$ ]] ||
    { echo "mirror.sh run: WORKHORSES_TAILSCALE_FIRST_COPY_MB takes a whole number of MB from 1 to 9999999, not \"$tailscale_first_copy_mb\"" >&2; exit 2; }
  local host=$1 dir sub main seed="" target work ignore rsync_excludes=() names=() pattern tracked none_free="no workhorse is free:"
  dir=$(cd "$2" && pwd -P)
  shift 2
  load_hosts || exit 2
  all_hosts=("${host_names[@]}")
  # A list of hosts: wh picks among those as it picks among all of them.
  if [[ $host == *,* ]]; then
    narrow_hosts "$host" || exit 2
    host=auto
    none_free=$(printf '%s, ' "${all_hosts[@]}")
    none_free="none of ${none_free%, } is free:"
  fi

  # The copy is of the whole repository; the job runs in the subfolder it was started from.
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    blocked_unstarted "$host" "$dir" "" "$dir is not inside a git work tree, so its files under ignored names cannot be checked" "$@"
  sub=$(git -C "$dir" rev-parse --show-prefix)
  dir=$(git -C "$dir" rev-parse --show-toplevel)
  # A linked worktree's main checkout holds nearly the same files: its copy seeds a first copy.
  main=$(dirname "$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir)")
  [ "$main" = "$dir" ] || seed=$(work_name "$main")
  work=$(work_name "$dir")
  if [ "$host" = auto ] && ! host=$(pick_host "$work"); then
    blocked_unstarted auto "$dir" "${sub%/}" "$none_free
$host" "$@"
  fi
  target=$(ssh_target "$host")
  run_host=$host run_target=$target run_work=$work run_owner="$(hostname -s) pid $$ since $(date '+%F %T')"

  log_start "$host" "$dir" "${sub%/}" "$@"
  trap 'finish $?' EXIT
  trap 'on_signal 143' TERM
  trap 'on_signal 130' INT
  trap 'on_signal 129' HUP

  for ignore in "${ignores[@]}"; do
    rsync_excludes+=(--exclude "$ignore")
    names+=("${ignore%/}")
  done

  # Git-tracked files under an ignored name (a tracked target/ folder, say) never reach the mini.
  # cs sessions track their .cs/ notes by design; no job needs them, so their absence is expected.
  pattern="(^|/)($(printf '%s\n' "${ignores[@]}" | grep -vx '\.cs/' | sed 's/[.]/\\./g; s#^\(.*[^/]\)$#\1$#' | paste -sd '|' -))"
  tracked=$(git -C "$dir" ls-files | grep -E "$pattern" || true)
  [ -z "$tracked" ] || blocked "git tracks files under names wh leaves out; they would be missing on $host:
$tracked"

  local prepared state server route_description has_git first_copy_kb empty tree_bytes stored_clock copy_changes held holder
  phase=prepare
  if ! prepared=$(remote "$target" /bin/bash -c "$prepare_work_copy" _ "$work" \
    "$run_owner: $*" "$seed" "$(printf '%s\n' "${names[@]}")" "${rsync_excludes[@]}"); then
    held=$(sed -n 1p <<<"$prepared")
    holder=$(sed -n '2,$p' <<<"$prepared" | quoted_owner)
    [[ $held =~ ^locked\ (running\ [1-9][0-9]*|preparing|stale\ $stale_why)$ ]] || held=""
    [ -z "$held" ] || phase=refused
    case "$held" in
      "locked running "*) blocked "$host:~/$work is in use by another run, its job running as pid ${held#locked running } there. The lock's owner: $holder" ;;
      "locked preparing") blocked "$host:~/$work is in use by another run still copying to it. The lock's owner: $holder" ;;
      "locked stale $no_pid_why") blocked "$host:~/$work.lock is stale ($no_pid_why); its run may still be copying, so check that wh ps on the machine its owner names no longer lists it before you remove the lock with: ssh $target 'rm -r ~/$work.lock'. The lock's owner: $holder" ;;
      "locked stale "*) blocked "$host:~/$work.lock is stale (${held#locked stale }); remove it with: ssh $target 'rm -r ~/$work.lock'. The lock's owner: $holder" ;;
      *) blocked "could not lock and refresh $host:~/$work" ;;
    esac
  fi
  phase=copy
  read -r state server has_git <<<"$(sed -n 1p <<<"$prepared")"
  if [ "$has_git" = nogit ] && route_description=$(tailscale_route "$server"); then
    # The first copy sends .git and every file the full walk below sends, measured with the same exclusions.
    first_copy_kb=$(du -sk "$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir)" | cut -f1)
    empty=$(mktemp -d)
    tree_bytes=$(rsync -rlt -n --stats "${rsync_excludes[@]}" --exclude /.git "$dir/" "$empty/" |
      awk -F': ' '/^Total file size/ {gsub(/[^0-9]/, "", $2); print $2}') ||
      { rmdir "$empty"; blocked "could not measure the files in $dir"; }
    rmdir "$empty"
    [ -n "$tree_bytes" ] || blocked "could not measure the files in $dir: rsync --stats printed no total file size"
    first_copy_kb=$((first_copy_kb + tree_bytes / 1024))
    [ "$first_copy_kb" -le $((tailscale_first_copy_mb * 1024)) ] ||
      blocked "the first copy of $dir on $host would send $((first_copy_kb / 1024)) MB through Tailscale ($route_description), over the $tailscale_first_copy_mb MB limit; run it from a network that reaches $host without Tailscale, name a host on this network, or raise WORKHORSES_TAILSCALE_FIRST_COPY_MB"
  fi
  sync_git "$dir" "$target" "$work" || blocked "could not copy $dir's .git to $host:~/$work"
  stored_clock=$(sed -n 2p <<<"$prepared")
  copy_changes=$(sed -n '3,$p' <<<"$prepared")

  # Watchman's list of what changed on the laptop and the listing's of what the last job changed in the
  # copy are together everything the patch must touch. Any doubt about either walks every file.
  local answer clock="" reason="" listed path paths=()
  if ! answer=$(watchman_changes "$dir" "$stored_clock"); then
    reason="Watchman could not answer"
  elif [ "$(jq -r 'has("error")' <<<"$answer")" = true ]; then
    reason="Watchman: $(jq -r .error <<<"$answer")"
  else
    clock=$(jq -r .clock <<<"$answer")
    if [ "$state" != warm ]; then
      reason="first run in $host:~/$work; comparing every file's contents once"
    elif [ -z "$stored_clock" ]; then
      reason="the copy has no Watchman clock from an earlier run"
    elif [ "$(jq -r .is_fresh_instance <<<"$answer")" = true ]; then
      reason="Watchman has no record reaching back to the copy's last run"
    else
      # A job can change tens of thousands of files, more than fit in one argument, so they go as a file.
      if ! listed=$(changed_paths <(printf '%s\n' "$copy_changes") \
        "$(printf '%s\n' "${names[@]}" | jq -R . | jq -sc .)" <<<"$answer"); then
        reason="could not join Watchman's list with the copy's"
      elif [ "$(head -n 1 <<<"$listed")" != ok ]; then
        reason=${listed#walk: }
      else
        while IFS= read -r path; do paths+=("$path"); done < <(tail -n +2 <<<"$listed")
        patch_listed "$dir" "$target" "$work" ${paths[@]+"${paths[@]}"} ||
          reason="patching the ${#paths[@]} listed paths failed"
      fi
    fi
  fi

  # The walk sends what the copy lacks, has stale or has extra, and sets the laptop's file times. A new
  # copy's times come from the seed, not the laptop, so its walk compares contents (-c). The
  # repository's own .git, a folder or a linked worktree's file, came over above; a nested one is an
  # ordinary file of the tree. --executability carries a changed executable bit.
  if [ -n "$reason" ]; then
    local out compare=()
    [ "$state" = warm ] || compare=(-c)
    echo "mirror.sh run: full walk: $reason" >&2
    out=$(rsync -rlti ${compare[@]+"${compare[@]}"} --executability --delete "${rsync_excludes[@]}" --exclude /.git \
      -e "ssh -o BatchMode=yes -o ConnectTimeout=10" "$dir/" "$target:$work/") ||
      blocked "could not copy the laptop's changes from $dir to $host:~/$work"
    report_patched <<<"$out"
  fi

  # From here the remote job owns the lock and releases it itself. ssh runs in the background, its
  # stdin kept, so a signal to this shell interrupts the wait at once instead of after the job.
  log_synced
  phase=job
  remote "$target" /bin/bash -c "$run_job" _ "$work" "$run_owner" "${sub:-.}" "$clock" "$(printf '%s\n' "${names[@]}")" "$limit" "$@" <&0 &
  job_ssh=$!
  local status=0
  wait "$job_ssh" || status=$?
  # ssh exits 255 when the connection drops, which leaves a quiet job running on the host; a job of
  # its own exit 255 has freed its lock by then, which stop_job answers as gone.
  if [ "$status" = 255 ]; then
    if ! stop_job; then
      end_reason=lost
    elif [ "$job_stop" != gone ]; then
      end_reason=lost-stopped
    fi
    [ "$job_stop" = gone ] || say "mirror.sh run: the connection to $host dropped while the job ran, so the run ends with ssh's exit 255"
  fi
  # run_job refuses to start the job outside this run's lock with an exit 3, which can be the job's own.
  if [ "$status" = 3 ]; then
    local refusal
    if ! refusal=$(remote "$target" /bin/sh -c "$take_refusal" _ "$work" "$run_owner"); then
      echo "mirror.sh run: could not reach $host to ask whether exit 3 is the job's own or the host's refusal to start it outside this run's lock" >&2
    elif [ "$(head -n 1 <<<"$refusal")" = refused ]; then
      holder=$(sed 1d <<<"$refusal" | quoted_owner)
      [ -z "$holder" ] || blocked "the job did not start: $host:~/$work.lock is another run's. The lock's owner: $holder"
      blocked "the job did not start: $host:~/$work.lock, which this run took, is gone"
    fi
  fi
  return "$status"
}

# Run by the host's /bin/sh with the work copy $1 and a run's owner line $2: prints "refused" and the lock's
# owner file that run_job found when it refused to start that run's job, and removes the refusal; else "ran".
take_refusal='f=$HOME/$1.refused first=""
[ ! -f "$f" ] || IFS= read -r first <"$f" || :
if [ "$first" = "$2" ]; then echo refused; sed 1d "$f"; rm -f "$f"; else echo ran; fi'

# Writes a line to stderr from a way out, where stderr can be a closed pipe (wh ... | tee after Ctrl-C).
# An external printf then fails alone; bash 3.2's own echo would keep the line buffered and write it
# into the next command substitution, the end line's time among them.
say() { /usr/bin/printf '%s\n' "$*" >&2 2>/dev/null || true; }

# Frees the lock this run took on the host, and only that one: another run's lock, or none, stays.
free_lock() {
  remote "$run_target" /bin/sh -c 'case "$(cat "$1/owner" 2>/dev/null)" in "$2:"*) rm -rf "$1" ;; esac' _ "$run_work.lock" "$run_owner"
}

# The way out of a run, however it ends: while the copy is made, the lock this run took goes (once the
# job runs, the host frees it), then the end line. A prepare that failed may still have taken the lock:
# the host can finish it after the connection that would carry its answer is gone. free_lock removes
# only this run's; a prepare refused by another run's lock took none, so nothing is freed. Signals are
# ignored from here, by this shell and the ssh it starts, so a second Ctrl-C or wh stop cannot cut the
# cleanup short, nor a closed pipe end it.
finish() {
  local status=$1
  trap '' TERM INT HUP PIPE
  if { [ "$phase" = prepare ] || [ "$phase" = copy ]; } && ! free_lock; then
    say "mirror.sh run: could not free $run_host:~/$run_work.lock; remove it if no run holds it"
  fi
  log_end "$status"
}

# A signal stops the run and exits $1: wh stop sends SIGTERM, Ctrl-C SIGINT and a closed terminal
# SIGHUP. Once the job runs, stop_job ends it on the host; before, the way out frees the lock. The end
# line says stopped only when the job is known not to run, and stop-unconfirmed when it may.
on_signal() {
  trap '' TERM INT HUP PIPE
  end_reason=stopped
  if [ "$phase" = job ]; then
    stop_job || end_reason=stop-unconfirmed
    [ "$job_stop" != gone ] || say "mirror.sh run: the job had already ended on $run_host"
  else
    say "mirror.sh run: stopped before the job started"
  fi
  exit "$1"
}

# On a host: ends the job of the run whose lock is $1 and whose owner line starts with $2, and says what
# it found. SIGTERM goes to the shell that runs the job, whose pid run_job writes into the lock as it
# starts; that shell stops the job's process group and frees the lock. It signals only a pid that
# lock_state calls running, never a stale lock's. It waits up to $3 seconds for that pid; with none by
# then, $4 = free removes the lock, which no job holds. Prints one word or line: signalled; gone, when the
# lock is gone or another run's, so the job has already ended; freed; no-pid, when it waited in vain and
# $4 is not free; or the lock's "stale <why>".
stop_on_host="$lock_state"$'\n'$(cat <<'SCRIPT'
n=0
while :; do
  case "$(cat "$1/owner" 2>/dev/null)" in ("$2:"*) ;; (*) echo gone; exit 0 ;; esac
  held=$(lock_state "$1")
  case "$held" in
    ("running "*) if kill -s TERM "${held#running }" 2>/dev/null; then echo signalled; exit 0; fi ;;
    ("stale "*) echo "$held"; exit 0 ;;
  esac
  n=$((n + 1))
  [ "$n" -lt "$3" ] || break
  sleep 1
done
if [ "$4" = free ]; then
  rm -rf "$1"
  echo freed
else
  echo no-pid
fi
SCRIPT
)

# Ends this run's job on the host. Without this the job would run on, as nothing reaches a host's
# process once its laptop side is gone. The job's ssh then gets 10 seconds to end, as a child the job
# left holding its output, or a dead connection, can keep it open. When no job shell has written its
# pid after 10 seconds, the ssh that starts the job never reached the host: once that ssh is ended no
# job can start, so the lock goes too. Leaves stop_on_host's answer in job_stop (unreachable when the
# host did not answer, unexpected when it answered what stop_on_host never says) and returns 0 when the
# job is known not to run: signalled, freed, a lock stale from before the host restarted, or gone, which
# means it had already ended and is left for the caller to word. Returns 1 when it may still be
# running: the host did not answer as expected, or the lock is stale otherwise.
job_stop=""
stop_job() {
  local waited=0
  job_stop=$(remote "$run_target" /bin/sh -c "$stop_on_host" _ "$run_work.lock" "$run_owner" 10 wait) || job_stop=unreachable
  case "$job_stop" in
    signalled | gone)
      while [ -n "$job_ssh" ] && kill -0 "$job_ssh" 2>/dev/null; do
        if [ $waited -ge 100 ]; then
          # shellcheck disable=SC2046 # one pid a word
          kill -s TERM $(descendants $$) 2>/dev/null || true
          break
        fi
        sleep 0.1
        waited=$((waited + 1))
      done ;;
    "stale "*)
      # shellcheck disable=SC2046 # one pid a word
      kill -s TERM $(descendants $$) 2>/dev/null || true ;;
    *)
      # shellcheck disable=SC2046 # one pid a word
      kill -s TERM $(descendants $$) 2>/dev/null || true
      job_stop=$(remote "$run_target" /bin/sh -c "$stop_on_host" _ "$run_work.lock" "$run_owner" 1 free) || job_stop=unreachable ;;
  esac
  # What the host answered is data: an answer stop_on_host never gives is not printed.
  [[ $job_stop =~ ^(signalled|gone|freed|no-pid|unreachable|stale\ $stale_why)$ ]] || job_stop=unexpected
  case "$job_stop" in
    signalled) say "mirror.sh run: stopped the job on $run_host" ;;
    gone) ;;
    freed) say "mirror.sh run: the job never started on $run_host; its lock is freed" ;;
    "stale the host has restarted since the lock was taken")
      say "mirror.sh run: the job no longer runs on $run_host, which has restarted since the lock was taken; that lock is stale: remove it with: ssh $run_target 'rm -r ~/$run_work.lock'" ;;
    "stale "*)
      say "mirror.sh run: could not stop the job on $run_host: its lock there is stale (${job_stop#stale }), so the job may still be running in ~/$run_work; remove the lock with: ssh $run_target 'rm -r ~/$run_work.lock'"
      return 1 ;;
    unexpected)
      say "mirror.sh run: could not stop the job on $run_host, whose answer wh does not know; it may still be running in ~/$run_work"
      return 1 ;;
    *)
      say "mirror.sh run: could not reach $run_host to stop the job; it may still be running in ~/$run_work"
      return 1 ;;
  esac
}

# The run log's runs still going: a start line with no end line whose mirror.sh still lives. Prints one
# JSON object a run, its start line, oldest first.
live_runs() {
  local starts pid
  [ -f "$run_log" ] || return 0
  starts=$(jq -c -s 'map(select(.event == "start" or .event == "end")) | group_by(.id)
    | map(select(length == 1 and .[0].event == "start" and (.[0].pid | type) == "number") | .[0]) | sort_by(.at) | .[]' "$run_log")
  while IFS= read -r start; do
    [ -n "$start" ] || continue
    pid=$(jq -r .pid <<<"$start")
    if ps -o command= -p "$pid" 2>/dev/null | grep -q 'mirror\.sh run'; then printf '%s\n' "$start"; fi
  done <<<"$starts"
}

# Lists the runs going from this machine, one a line: the number wh stop takes (the run's pid here),
# the host, how long it has run, the repository and subfolder, and the command.
list_runs() {
  local runs now
  runs=$(live_runs)
  if [ -z "$runs" ]; then
    echo "no wh runs going"
    return 0
  fi
  now=$(date +%s)
  jq -r --argjson now "$now" '
    def age: (($now - .at) | if . < 60 then "\(.)s" elif . < 3600 then "\(. / 60 | floor)m" else "\(. / 3600 | floor)h\(. % 3600 / 60 | floor)m" end);
    "\(.pid)\t\(.host)\t\(age)\t\(.dir | split("/") | last)\(if .sub == "" then "" else "/" + .sub end)\t\(.command)"' <<<"$runs"
}

# Prints one JSON object for host $1 from its answer in folder $2 (as probe_hosts left it) to
# load_and_cores followed by count_runs with wh_list=1: {host, state: "ok", load, cores, runs},
# {host, state: "unreachable"}, or {host, state: "unexpected", answer} with the answer made plain text
# and cut at 200 characters. A run's owner line, as run writes it ("<machine> pid <n> since
# <date> <time>: <command>"), gives its machine, pid, start and command; any other owner text is the
# command, and the rest is null. A run of this machine ($3) that the run log's live runs ($4, a JSON
# array of start lines, each with the name of its folder's work copy added as work) list for this host
# under this lock's name has the folder it started from, the Claude Code session that started it (null
# when its start line names none) and can be stopped with wh stop; only the first such run of a pid
# does, so a host that lists a lock twice gets one Stop. What a host sends is data: control characters,
# and the characters that reorder or hide text (bidi controls, zero-width characters), never reach the report.
host_report() {
  local host=$1 answers=$2 me=$3 mine=$4 state load cores
  read -r _ state load cores _ <<<"$(probe_answer "$host" "$(cat "$answers/$host.status")" \
    "$(sed -n '1,2p' "$answers/$host" | tr '\n' ' ')0 none ")"
  jq -nc --arg host "$host" --arg state "$state" --arg load "$load" --arg cores "$cores" \
    --rawfile answer "$answers/$host" --arg me "$me" --argjson mine "$mine" "$plain_jq"'
    def owned: "^(?<machine>[A-Za-z0-9._-]+) pid (?<pid>[0-9]{1,10}) since (?<since>[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}): (?<command>.*)$";
    def run: (.owner | capture(owned)? // null) as $owner
      | if $owner == null then {work, machine: null, pid: null, since: null, command: .owner, dir: null, session: null, stoppable: false}
        else ($owner.pid | tonumber) as $pid
          | .work as $work
          | (if $owner.machine == $me then first($mine[] | select(.pid == $pid and .host == $host and .work == $work)) // null else null end) as $start
          | {work, machine: $owner.machine, pid: $pid, since: $owner.since, command: $owner.command,
             dir: ($start.dir // null),
             session: ($start.session | if type == "string" and test("^[A-Za-z0-9-]{1,64}$") then . else null end),
             stoppable: ($start != null)}
        end;
    def unexpected: {host: $host, state: "unexpected", answer: ($answer | plain | .[:200])};
    ($answer | split("\n")[2:] | map(select(. != ""))) as $rest
    | ($rest[:-1]) as $locks
    | if $state == "unreachable" then {host: $host, state: "unreachable"}
      elif $state != "ok" or (($rest[-1] // "") | test("^[0-9]+$") | not)
        or ($rest[-1] | tonumber) != ($locks | length)
        or any($locks[]; test("^lock\t[A-Za-z0-9._-]+\t[^\t]*$") | not) then unexpected
      else {host: $host, state: "ok", load: ($load | tonumber), cores: ($cores | tonumber),
        runs: ([$locks[] | split("\t") | {work: .[1], owner: (.[2] | plain)} | run] | sort_by(.work)
          | reduce .[] as $run ([]; . + [if $run.stoppable and any(.[]; .stoppable and .pid == $run.pid)
              then $run + {dir: null, session: null, stoppable: false} else $run end]))}
      end'
}

# Prints the human form of host_report's lines on stdin: a line per host, then a line per run going
# there, indented. A run of this machine leads with the number wh stop takes and its folder under ~.
render_hosts() {
  jq -rs --arg home "$HOME" '
    (map(.host | length) | max + 2) as $width
    | def pad: . + (" " * ($width - length));
    def two: tostring | if test("[.]") then (. + "00" | capture("^(?<n>[0-9]+[.][0-9]{2})").n) else . + ".00" end;
    def tilde: if startswith($home + "/") then "~" + .[($home | length):] else . end;
    def line: if .stoppable then "\(.pid)  \(.dir | tilde)  since \(.since[11:16])  \(.command)"
      elif .machine != null then "from \(.machine) pid \(.pid) since \(.since): \(.command)"
      elif .command == "" then "\(.work): no owner recorded"
      else "\(.work): \(.command)" end;
    .[] | (.host | pad) + if .state == "unreachable" then "unreachable"
      elif .state == "unexpected" then "unexpected answer: \(.answer)"
      else "load \(.load | two) of \(.cores) cores, "
        + (.runs | length | if . == 0 then "idle" elif . == 1 then "1 run" else "\(.) runs" end)
        + ([.runs[] | "\n" + (" " * $width) + line] | join(""))
      end'
}

# Asks every workhorse at once, for at most 5 seconds (eris is reached over Tailscale away from home),
# for its load and the runs going on it, and prints a report: a line per host and its runs, or with
# --json one host_report object a line, in the hosts file's order. A host that cannot be reached is
# part of the report, not a failure.
list_hosts() {
  if [ $# -gt 1 ] || { [ $# = 1 ] && [ "$1" != --json ]; }; then
    echo "usage: wh hosts [--json]" >&2
    exit 2
  fi
  local host mine reports
  load_hosts || exit 2
  all_hosts=("${host_names[@]}")
  # A pid has one run going: when the log holds two live starts with one pid (the pid was used again after
  # a run ended without its end line), the newer is that run, so a pid gets at most one Stop.
  mine=$(live_runs | while IFS= read -r start; do
    jq -c --arg work "$(work_name "$(jq -r .dir <<<"$start")")" '.work = ($work | ltrimstr("work/"))' <<<"$start"
  done | jq -sc 'group_by(.pid) | map(max_by(.at))')
  # Global, not local: the EXIT trap removes the folder however this script ends, a failed report or a
  # SIGTERM included, and runs after this function has returned. The traps come before mktemp: a TERM
  # that lands while mktemp makes the folder waits for its name, then exits through the EXIT trap.
  hosts_answers=
  trap '[ -z "$hosts_answers" ] || rm -rf "$hosts_answers"' EXIT
  trap 'exit 143' TERM
  hosts_answers=$(mktemp -d "${TMPDIR:-/tmp}/wh-hosts.XXXX")
  probe_hosts 5 "$load_and_cores; wh_list=1; $count_runs" "$hosts_answers"
  reports=$(for host in "${all_hosts[@]}"; do host_report "$host" "$hosts_answers" "$(hostname -s)" "$mine" || exit 1; done)
  if [ $# = 1 ]; then printf '%s\n' "$reports"; else render_hosts <<<"$reports"; fi
}

# The pids of every process under process $1, children first.
descendants() {
  local child
  for child in $(pgrep -P "$1"); do
    echo "$child"
    descendants "$child"
  done
}

# Stops the run whose pid here is $1, as Ctrl-C in its terminal would: SIGTERM to its mirror.sh, whose
# traps end the job on the host and free the lock. Waits up to 30 s for the run to end. Exits 0 when the
# job stopped on the host, or the run had already ended; 1 when its job may still be running there.
stop_run() {
  [ $# = 1 ] && [[ $1 =~ ^[1-9][0-9]{0,9}$ ]] || { echo "usage: wh stop <run>  (wh ps lists the runs going)" >&2; exit 2; }
  local pid=$1 start waited=0
  start=$(live_runs | jq -c --argjson pid "$pid" 'select(.pid == $pid)')
  [ -n "$start" ] || { echo "wh stop: no wh run going has the number $pid; wh ps lists the runs going" >&2; exit 1; }
  kill -s TERM "$pid" 2>/dev/null || true
  # While the copy is made, mirror.sh waits on rsync or ssh in the foreground, which holds its trap
  # back until they end, so every process under it gets SIGTERM too: the ssh of a command substitution
  # sits under a subshell. Once the job runs, its traps act at once.
  if ! jq -e --arg id "$(jq -r .id <<<"$start")" 'select(.event == "synced" and .id == $id)' "$run_log" >/dev/null; then
    # shellcheck disable=SC2046 # one pid a word
    kill -s TERM $(descendants "$pid") 2>/dev/null || true
  fi
  while kill -0 "$pid" 2>/dev/null; do
    [ $waited -lt 300 ] || { echo "wh stop: run $pid is still going 30 s after SIGTERM" >&2; exit 1; }
    sleep 0.1
    waited=$((waited + 1))
  done
  # The run's end line says whether its job stopped on the host: wh stop has no other word from the run.
  local host command end
  host=$(jq -r .host <<<"$start") command=$(jq -r .command <<<"$start")
  end=$(jq -c --arg id "$(jq -r .id <<<"$start")" 'select(.event == "end" and .id == $id)' "$run_log" | tail -n 1)
  case "$(jq -r 'if .reason == null then "exit \(.exit)" else .reason end' <<<"$end")" in
    stopped) echo "wh stop: stopped run $pid on $host: $command" ;;
    "")
      echo "wh stop: run $pid ended without logging how; its job may still be running on $host: $command" >&2
      exit 1 ;;
    stop-unconfirmed | lost)
      echo "wh stop: run $pid ended here, but could not confirm that its job stopped on $host; it may still be running there: $command" >&2
      exit 1 ;;
    *) echo "wh stop: run $pid on $host had already ended ($(jq -r 'if .reason == null then "exit \(.exit)" else "exit \(.exit): \(.reason)" end' <<<"$end")): $command" ;;
  esac
}

case "${1:-}" in
  run) shift; run "$@" ;;
  ps) [ $# = 1 ] || { echo "usage: wh ps" >&2; exit 2; }; list_runs ;;
  stop) shift; stop_run "$@" ;;
  hosts) shift; list_hosts "$@" ;;
  *) echo "usage: $0 run [--timeout <seconds>] <host[,host...]|auto> <dir> <command...>" >&2; exit 2 ;;
esac
