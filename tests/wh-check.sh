#!/bin/bash
# ABOUTME: End-to-end check that wh brings a workhorse's copy level with the laptop for every kind of change.
# ABOUTME: Usage: tests/wh-check.sh <host>, a host from the hosts file; works in throwaway folders; exits 1 on the first mismatch.
set -euo pipefail

host=${1:?usage: tests/wh-check.sh <host>}
here=$(cd "$(dirname "$0")" && pwd -P)
wh=$here/../bin/wh
cd "$here/.."
probe=wh-check-$$
mkdir "$probe"
trap 'rm -rf "$probe"' EXIT

# Prints every entry under the current folder with its type and, for a file, its mode and checksum;
# node_modules is left out, as wh leaves it to each side. The same text on both sides means the copy matches.
# It runs on this Mac and on the host, which may run Linux: GNU stat and md5sum print the same mode
# string and checksum as BSD stat and md5.
digest='if [ "$(uname -s)" = Darwin ]; then
  mode() { stat -f %Sp "$1"; }; sum() { md5 -q "$1"; }
else
  mode() { stat -c %A "$1"; }; sum() { md5sum <"$1" | cut -d " " -f 1; }
fi
find . -name node_modules -prune -o -print | LC_ALL=C sort | while IFS= read -r p; do
  if [ -L "$p" ]; then echo "$p -> $(readlink "$p")"
  elif [ -f "$p" ]; then echo "$p $(mode "$p") $(sum "$p")"
  else echo "$p dir"; fi
done'

# Which way the patch must go: "any" for the first run, "list" for Watchman's change list, "walk" for
# a comparison of every file.
want_path=any

# Runs a command in the probe folder of the copy and compares its stdout and exit code with the
# expected ones. Before the command, the copy's probe folder must match the laptop's.
expect() {
  local want_out=$1 want_exit=$2 label=$3 out err code here_digest there_digest
  shift 3
  here_digest=$(cd "$probe" && sh -c "$digest")
  err=$(mktemp)
  set +e
  out=$("$wh" "$host" -- sh -c "cd $probe && { $digest; } && echo === && { $* ; }" 2>"$err")
  code=$?
  set -e
  there_digest=${out%%===*}
  there_digest=${there_digest%$'\n'}
  out=${out#*===}
  out=${out#$'\n'}
  local walked=no
  if grep -q '^mirror.sh run: full walk:' "$err"; then walked=yes; fi
  if [ "$there_digest" != "$here_digest" ]; then
    echo "FAIL $label: the copy differs from the laptop before the command:" >&2
    diff <(echo "$here_digest") <(echo "$there_digest") >&2 || true
    cat "$err" >&2
    exit 1
  fi
  if { [ "$want_path" = list ] && [ $walked = yes ]; } || { [ "$want_path" = walk ] && [ $walked = no ]; }; then
    echo "FAIL $label: wanted the $want_path path, got walked=$walked:" >&2
    cat "$err" >&2
    exit 1
  fi
  rm -f "$err"
  if [ "$out" != "$want_out" ] || [ "$code" != "$want_exit" ]; then
    echo "FAIL $label: wanted '$want_out' exit $want_exit, got '$out' exit $code" >&2
    exit 1
  fi
  echo "ok   $label"
}

printf 'aaaa\n' >"$probe/file"
touch -t 202001010000 "$probe/file"
expect aaaa 0 "a new file arrives" cat file
want_path=list

printf 'bbbb\n' >"$probe/file"
expect bbbb 0 "a same-size edit arrives" cat file

printf 'aaaa\n' >"$probe/file"
touch -t 202001010000 "$probe/file"
expect aaaa 0 "a restore to an older time arrives" cat file

chmod +x "$probe/file"
expect yes 0 "a set executable bit arrives" 'test -x file && echo yes || echo no'
chmod -x "$probe/file"
expect no 0 "a cleared executable bit arrives" 'test -x file && echo yes || echo no'

expect "" 0 "the mini edits a file" 'echo junk >> file'
expect aaaa 0 "the next run puts the laptop's file back" cat file

expect "" 0 "the mini adds a file" 'touch stray'
expect absent 0 "the next run removes it" 'test -e stray && echo present || echo absent'

expect "" 0 "the mini deletes a file" 'rm file'
expect aaaa 0 "the next run brings it back" cat file

expect "" 0 "the mini sets an executable bit" 'chmod +x file'
expect no 0 "the next run clears it" 'test -x file && echo yes || echo no'

mkdir -p "$probe/dir/sub"
printf 'nested\n' >"$probe/dir/sub/n"
expect nested 0 "a new folder with a nested file arrives" 'cat dir/sub/n'
expect "" 0 "the mini deletes a folder" 'rm -rf dir'
expect nested 0 "the next run brings it back" 'cat dir/sub/n'
mv "$probe/dir/sub/n" "$probe/dir/m"
expect "nested absent" 0 "a renamed file arrives under its new name" 'echo "$(cat dir/m) $(test -e dir/sub/n && echo present || echo absent)"'
rm -rf "$probe/dir"
expect absent 0 "a folder deleted on the laptop goes" 'test -e dir && echo present || echo absent'

# A job that swaps a folder for a symlink out of the copy must not lead the next patch through it.
outside=/tmp/wh-check-outside-$$
mkdir -p "$probe/dir"
printf 'keep\n' >"$probe/dir/keep"
printf 'gone\n' >"$probe/dir/gone"
expect "" 0 "a folder arrives" 'true'
expect "" 0 "the mini swaps the folder for a symlink out of the copy" \
  "mkdir -p $outside && echo theirs > $outside/keep && echo theirs > $outside/gone && rm -rf dir && ln -s $outside dir"
rm "$probe/dir/gone"
want_path=walk
expect "theirs theirs" 0 "a laptop delete under it leaves the outside files alone" "cat $outside/keep $outside/gone | tr '\n' ' ' | sed 's/ \$//'"
want_path=list
expect "" 0 "the mini swaps it again" "rm -rf dir && ln -s $outside dir"
printf 'kept\n' >"$probe/dir/keep"
want_path=any
expect theirs 0 "a laptop edit under it leaves the outside files alone" "cat $outside/keep && rm -rf $outside"
want_path=list
rm -rf "$probe/dir"

ln -s file "$probe/link"
expect file 0 "a new symlink arrives" 'readlink link'
ln -sfh other "$probe/link"
expect other 0 "a retargeted symlink arrives" 'readlink link'
expect "" 0 "the mini retargets a symlink" 'ln -sfn junk link'
expect other 0 "the next run puts the laptop's symlink back" 'readlink link'
rm "$probe/link"
expect absent 0 "a symlink deleted on the laptop goes" 'test -L link && echo present || echo absent'

expect "" 0 "the mini installs its own node_modules" 'mkdir node_modules && touch node_modules/own'
mkdir "$probe/node_modules"
touch "$probe/node_modules/laptop"
rm -rf "$probe/node_modules"
expect kept 0 "deleting node_modules on the laptop leaves the mini's" 'test -e node_modules/own && echo kept || echo gone'
# rsync never deletes an excluded folder, so the probe's own would outlive this check on the mini.
expect "" 0 "the mini removes its node_modules" 'rm -rf node_modules'

# From a worktree nested in another repository, Watchman watches that outer one: forget the watch it uses.
watchman watch-del "$(watchman watch-project "$PWD" | jq -r .watch)" >/dev/null
want_path=walk
printf 'cccc\n' >"$probe/file"
expect cccc 0 "after Watchman forgets the repo, a full walk still brings the change" cat file
want_path=list

rm "$probe/file"
expect absent 0 "a file deleted on the laptop goes" 'test -e file && echo present || echo absent'

expect "" 7 "the command's exit code comes back" 'exit 7'

# The run log says when the copy was ready: a synced line between the run's start and its end.
run_log=$HOME/.local/state/workhorse/runs.jsonl
last_id=$(grep '"event":"start"' "$run_log" | tail -n 1 | jq -r .id)
events=$(jq -r --arg id "$last_id" 'select(.id == $id) | .event' "$run_log" | paste -sd ' ' -)
[ "$events" = "start synced end" ] || { echo "FAIL the last run logged '$events', wanted 'start synced end'" >&2; exit 1; }
echo "ok   the run log marks when the copy was ready"

# Git in the copy sees what git on the laptop sees: a plain repository, and a linked worktree of it,
# whose .git on the laptop is a file naming a folder the workhorse does not have.
gitroot=${TMPDIR:-/tmp}/wh-check-git
rm -rf "$gitroot"
mkdir -p "$gitroot"
trap 'rm -rf "$probe" "$gitroot"' EXIT
commit() { git -c user.name=wh-check -c user.email=wh-check@example.com commit -q "$@"; }
git -C "$gitroot" init -q -b main repo
(cd "$gitroot/repo" && echo one >f && git add f && commit -m one)
git -C "$gitroot/repo" worktree add -q -b side "$gitroot/wt"
(cd "$gitroot/wt" && echo two >f && commit -am two && echo three >g && git add g)

# Runs a command through wh from folder $1 and compares its stdout with $2.
git_expect() {
  local from=$1 want=$2 label=$3 out
  shift 3
  out=$(cd "$from" && "$wh" "$host" -- sh -c "$*" 2>/dev/null) || { echo "FAIL $label: wh failed" >&2; exit 1; }
  [ "$out" = "$want" ] || { echo "FAIL $label: wanted '$want', got '$out'" >&2; exit 1; }
  echo "ok   $label"
}
git_expect "$gitroot/repo" "$(git -C "$gitroot/repo" rev-parse HEAD)" "git in a repository's copy sees the laptop's HEAD" 'git rev-parse HEAD'
(cd "$gitroot/repo" && echo four >f && commit -am four)
git_expect "$gitroot/repo" "$(git -C "$gitroot/repo" rev-parse HEAD)" "a commit made on the laptop since reaches the copy" 'git rev-parse HEAD'
git_expect "$gitroot/wt" "$(git -C "$gitroot/wt" rev-parse HEAD)" "git in a worktree's copy sees the worktree's HEAD" 'git rev-parse HEAD'
git_expect "$gitroot/wt" "A  g" "the worktree's staged file comes staged" 'git status --porcelain'
git_expect "$gitroot/repo" "$(git -C "$gitroot/repo" rev-parse HEAD)" "the repository's copy keeps its own HEAD after the worktree's run" 'git rev-parse HEAD'
echo "all checks passed on $host"
