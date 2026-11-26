#!/bin/bash
# ABOUTME: Runs a command on a workhorse in its own copy of a laptop repository, brought level with the laptop first,
# ABOUTME: .git included. Usage: mirror.sh run [--timeout <seconds>] <host|auto> <dir> <command...>; wh is the short form.
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
# line (SIGKILL, power loss) can be told apart from one still going.
run_log=$HOME/.local/state/workhorse/runs.jsonl
run_id="" run_ended=0 end_reason=""
# What a signal or the way out acts on: the phase (prepare while the host takes the lock, copy while the
# copy is made, then job), the host, the
# copy and this run's line in its lock's owner file, and the ssh that runs the job.
phase="" run_host="" run_target="" run_work="" run_owner="" job_ssh=""

log_start() {
  local host=$1 dir=$2 sub=$3
  shift 3
  run_id="$(hostname -s)-$$-$(date +%s)"
  mkdir -p "$(dirname "$run_log")"
  jq -nc --arg id "$run_id" --argjson at "$(date +%s)" --arg host "$host" --arg dir "$dir" --arg sub "$sub" \
    --arg command "$*" --argjson pid "$$" \
    '{event: "start", id: $id, at: $at, host: $host, dir: $dir, sub: $sub, command: $command, pid: $pid}' >>"$run_log"
}

log_synced() {
  jq -nc --arg id "$run_id" --argjson at "$(date +%s)" '{event: "synced", id: $id, at: $at}' >>"$run_log"
}

log_end() {
  [ -n "$run_id" ] && [ "$run_ended" = 0 ] || return 0
  run_ended=1
  jq -nc --arg id "$run_id" --argjson at "$(date +%s)" --argjson exit "$1" --arg reason "$end_reason" \
    '{event: "end", id: $id, at: $at, exit: $exit} + (if $reason == "" then {} else {reason: $reason} end)' >>"$run_log"
}

# Turns host $1's answer to pick_host's probe, from an ssh that exited $2, into one probe line for
# choose_host. The answer's lines come joined by spaces: the load line, the physical core count, the
# number of runs going there (locks in ~/work), and whether it holds the copy: copy, busy when another
# run holds the copy's lock, or none. A Mac's load line is vm.loadavg's "{ 1.39 1.37 1.32 }"; a Linux host's is /proc/loadavg's
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
  if [[ $load =~ ^[0-9]+([.][0-9]+)?$ && $cores =~ ^[1-9][0-9]*$ && $runs =~ ^[0-9]+$ && $copy =~ ^(copy|busy|none)$ ]]; then
    echo "$host ok $load $cores $runs $copy"
  else
    echo "$host unexpected $answer"
  fi
}

# Picks the workhorse for a job from one probe line per host, in all_hosts order: "<host> ok <load>
# <cores> <runs> copy|busy|none", "<host> unreachable" or "<host> unexpected <answer>". It passes over a
# host whose copy another run holds, since this run would find it locked. Among the hosts whose
# 1-minute load is below their physical core count, it ranks each by its load plus its runs going, per
# core: the 1-minute average lags, so a run that started seconds ago counts as one busy core. A host
# that holds the repository's copy (and so its installed dependencies) comes first while that figure
# is under half; past it, the least busy host wins, so work spreads over the hosts instead of piling on
# the one with the copy. Ties go to table order. Prints the host; when none is free, prints each host's
# reason on stderr and fails.
choose_host() {
  awk '
    $2 != "ok" { reasons[NR] = $1 ": " substr($0, length($1) + 2); next }
    !($3 < $4) { reasons[NR] = $1 ": load " $3 " of " $4 " cores"; next }
    $6 == "busy" { reasons[NR] = $1 ": another run holds its copy"; next }
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

# The probe's count of runs going on a host, run by the host's login shell: the locks in ~/work whose
# pid file names a live process, and those without one, a run still copying, under an hour old. A lock
# left by a run that died without its cleanup does not count. With list=1 set before it, it first
# prints each counted lock as a line of three tab-separated fields: "lock", the lock's name without
# .lock, and its owner file with newlines and tabs made spaces (empty without an owner file).
count_runs='n=0; for l in $(find ~/work -maxdepth 1 -name "*.lock" -type d 2>/dev/null); do if [ -f "$l/pid" ]; then kill -0 "$(cat "$l/pid")" 2>/dev/null || continue; elif [ -z "$(find "$l" -maxdepth 0 -mmin -60)" ]; then continue; fi; n=$((n + 1)); if [ "${list:-}" = 1 ]; then w=${l##*/}; printf "lock\t%s\t%s\n" "${w%.lock}" "$(if [ -f "$l/owner" ]; then tr "\n\t" "  " <"$l/owner"; fi)"; fi; done; echo $n'

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
# on stderr.
pick_host() {
  local work=$1 answers host answer load cores runs copy probes="" chosen reasons
  answers=$(mktemp -d "${TMPDIR:-/tmp}/wh-pick.XXXX")
  probe_hosts 2 "$load_and_cores; $count_runs; if test -d ~/$(printf '%q' "$work.lock"); then echo busy; elif test -d ~/$(printf '%q' "$work"); then echo copy; else echo none; fi" "$answers"
  for host in "${all_hosts[@]}"; do
    answer=$(tr '\n' ' ' <"$answers/$host")
    probes+="$(probe_answer "$host" "$(cat "$answers/$host.status")" "$answer")"$'\n'
  done
  rm -rf "$answers"
  if ! chosen=$(choose_host <<<"${probes%$'\n'}" 2>/dev/null); then
    reasons=$(choose_host <<<"${probes%$'\n'}" 2>&1 >/dev/null || true)
    blocked "no workhorse is free:
$reasons"
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
prepare_work_copy="$list_copy"$'\n'$(cat <<'SCRIPT'
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
work=$HOME/$1 lock=$HOME/$1.lock owner=$2 seed=$3 names=$4
shift 4
mkdir -p "$(dirname "$work")"
if ! mkdir "$lock" 2>/dev/null; then
  echo "$work is in use: $(cat "$lock/owner" 2>/dev/null || echo "lock without owner") (remove $lock if that run is gone)" >&2
  exit 1
fi
echo "$owner" >"$lock/owner"
# A run stopped from the laptop frees this lock itself and may already have a successor's in its place.
trap 'case "$(cat "$lock/owner" 2>/dev/null)" in "$owner") rm -rf "$lock" ;; esac' EXIT
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

# Runs the job in the given subfolder of the work copy and releases the lock when it ends, even if the
# laptop disconnects. Before the job starts, it stores the copy's listing and the Watchman clock the
# patch went by (none when $3 is empty), which the next run compares against. The job runs in its own
# process group. With a limit of $5 seconds (0: none), past the limit the whole group gets SIGTERM,
# then SIGKILL 10 seconds later; the run then exits 124, as gtimeout does. If this shell dies by
# signal first (wh stop sends SIGTERM), the group gets the same before the lock goes.
run_job="$list_copy"$'\n'$(cat <<'SCRIPT'
lock=$HOME/$1.lock work=$HOME/$1 limited=$HOME/$1.limit
job="" timer="" job_ended=""
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
  /bin/rm -rf "$lock" "$limited"
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
if [ -n "$3" ] && (cd "$work" && list_copy "$4") >"$work.listing.new"; then
  /bin/mv "$work.listing.new" "$work.listing"
  printf '%s\n' "$3" >"$work.clock"
fi
/bin/rm -f "$work.listing.new"
cd "$work/$2" || exit 1
limit=$5
shift 5
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
    { echo "usage: $0 run [--timeout <seconds>] <host|auto> <dir> <command...>" >&2; exit 2; }
  # Seven digits at most, so the size in KB stays far inside shell arithmetic.
  [[ $tailscale_first_copy_mb =~ ^[1-9][0-9]{0,6}$ ]] ||
    { echo "mirror.sh run: WORKHORSES_TAILSCALE_FIRST_COPY_MB takes a whole number of MB from 1 to 9999999, not \"$tailscale_first_copy_mb\"" >&2; exit 2; }
  local host=$1 dir sub main seed="" target work ignore rsync_excludes=() names=() pattern tracked
  dir=$(cd "$2" && pwd -P)
  shift 2
  load_hosts || exit 2
  all_hosts=("${host_names[@]}")

  # The copy is of the whole repository; the job runs in the subfolder it was started from.
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    blocked "$dir is not inside a git work tree, so its files under ignored names cannot be checked"
  sub=$(git -C "$dir" rev-parse --show-prefix)
  dir=$(git -C "$dir" rev-parse --show-toplevel)
  # A linked worktree's main checkout holds nearly the same files: its copy seeds a first copy.
  main=$(dirname "$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir)")
  [ "$main" = "$dir" ] || seed=$(work_name "$main")
  work=$(work_name "$dir")
  [ "$host" != auto ] || host=$(pick_host "$work")
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

  local prepared state server route_description has_git first_copy_kb empty tree_bytes stored_clock copy_changes
  phase=prepare
  prepared=$(remote "$target" /bin/bash -c "$prepare_work_copy" _ "$work" \
    "$run_owner: $*" "$seed" "$(printf '%s\n' "${names[@]}")" "${rsync_excludes[@]}") ||
    blocked "could not lock and refresh $host:~/$work"
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
  remote "$target" /bin/bash -c "$run_job" _ "$work" "${sub:-.}" "$clock" "$(printf '%s\n' "${names[@]}")" "$limit" "$@" <&0 &
  job_ssh=$!
  local status=0
  wait "$job_ssh" || status=$?
  return "$status"
}

# Writes a line to stderr from a way out, where stderr can be a closed pipe (wh ... | tee after Ctrl-C).
# An external printf then fails alone; bash 3.2's own echo would keep the line buffered and write it
# into the next command substitution, the end line's time among them.
say() { /usr/bin/printf '%s\n' "$*" >&2 2>/dev/null || true; }

# Frees the lock this run took on the host, and only that one: another run's lock, or none, stays.
free_lock() {
  remote "$run_target" /bin/sh -c 'case "$(cat "$1/owner" 2>/dev/null)" in "$2:"*) rm -rf "$1" ;; esac' _ "$run_work.lock" "$run_owner"
}

# The way out of a run, however it ends: while the copy is made, the lock this run took goes (once the
# job runs, the host frees it), then the end line. A prepare that failed took no lock, or freed its own;
# one a signal cut short may have taken it. Signals are ignored from here, by this shell and the ssh it
# starts, so a second Ctrl-C or wh stop cannot cut the cleanup short, nor a closed pipe end it.
finish() {
  local status=$1
  trap '' TERM INT HUP PIPE
  if { [ "$phase" = copy ] || { [ "$phase" = prepare ] && [ "$end_reason" = stopped ]; }; } && ! free_lock; then
    say "mirror.sh run: could not free $run_host:~/$run_work.lock; remove it if no run holds it"
  fi
  log_end "$status"
}

# A signal stops the run and exits $1: wh stop sends SIGTERM, Ctrl-C SIGINT and a closed terminal
# SIGHUP. Once the job runs, stop_job ends it on the host; before, the way out frees the lock.
on_signal() {
  trap '' TERM INT HUP PIPE
  end_reason=stopped
  if [ "$phase" = job ]; then
    stop_job
  else
    say "mirror.sh run: stopped before the job started"
  fi
  exit "$1"
}

# On a host: ends the job of the run whose lock is $1 and whose owner line starts with $2. SIGTERM goes
# to the shell that runs the job, whose pid run_job writes into the lock as it starts; that shell stops
# the job's process group and frees the lock. It waits up to $3 seconds for that pid; with none by then,
# $4 = free removes the lock, which no job holds, and anything else fails. A lock that is gone, or
# another run's, means the job has already ended.
stop_on_host='n=0
while :; do
  case "$(cat "$1/owner" 2>/dev/null)" in "$2:"*) ;; *) exit 0 ;; esac
  [ -s "$1/pid" ] && exec kill -s TERM "$(cat "$1/pid")"
  n=$((n + 1))
  [ "$n" -lt "$3" ] || break
  sleep 1
done
[ "$4" = free ] && rm -rf "$1"'

# Ends this run's job on the host. Without this the job would run on, as nothing reaches a host's
# process once its laptop side is gone. The job's ssh then gets 10 seconds to end, as a child the job
# left holding its output, or a dead connection, can keep it open. When no job shell has written its
# pid after 10 seconds, the ssh that starts the job never reached the host: once that ssh is ended no
# job can start, so the lock goes too.
stop_job() {
  local waited=0
  if remote "$run_target" /bin/sh -c "$stop_on_host" _ "$run_work.lock" "$run_owner" 10 wait; then
    while [ -n "$job_ssh" ] && kill -0 "$job_ssh" 2>/dev/null; do
      if [ $waited -ge 100 ]; then
        # shellcheck disable=SC2046 # one pid a word
        kill -s TERM $(descendants $$) 2>/dev/null || true
        break
      fi
      sleep 0.1
      waited=$((waited + 1))
    done
    say "mirror.sh run: stopped the job on $run_host"
    return
  fi
  # shellcheck disable=SC2046 # one pid a word
  kill -s TERM $(descendants $$) 2>/dev/null || true
  if remote "$run_target" /bin/sh -c "$stop_on_host" _ "$run_work.lock" "$run_owner" 1 free; then
    say "mirror.sh run: the job never started on $run_host; its lock is freed"
  else
    say "mirror.sh run: could not reach $run_host to stop the job; it may still be running in ~/$run_work"
  fi
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

# The pids of every process under process $1, children first.
descendants() {
  local child
  for child in $(pgrep -P "$1"); do
    echo "$child"
    descendants "$child"
  done
}

# Stops the run whose pid here is $1, as Ctrl-C in its terminal would: SIGTERM to its mirror.sh, whose
# traps end the job on the host and free the lock. Waits up to 30 s for the run to end.
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
  echo "wh stop: stopped run $pid on $(jq -r .host <<<"$start"): $(jq -r .command <<<"$start")"
}

case "${1:-}" in
  run) shift; run "$@" ;;
  ps) [ $# = 1 ] || { echo "usage: wh ps" >&2; exit 2; }; list_runs ;;
  stop) shift; stop_run "$@" ;;
  *) echo "usage: $0 run [--timeout <seconds>] <host|auto> <dir> <command...>" >&2; exit 2 ;;
esac
