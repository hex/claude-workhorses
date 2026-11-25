#!/bin/bash
# ABOUTME: Runs on a workhorse, detached: applies the host options in ./options, then the recipes in ./tools, in order.
# ABOUTME: Stops at the first failure; writes run.status ("<exit> [<step>]") and the manifest, then frees the lock.
set -euo pipefail

here=$HOME/workhorse
state=$HOME/.local/share/claude-workhorses
cd "$here"

# The sudo password stays in this shell, unexported; only the steps that need sudo get it.
sudo_pw=${SUDO_PW:-}
unset SUDO_PW SUDO_ASKPASS
step=""

finish() {
  local code=$?
  # A failure before any step (a bad tools line, the env setup) names no step.
  if [ "$code" = 0 ]; then echo 0; else echo "$code ${step:-setup}"; fi >run.status
  {
    echo "#synced $(date -u '+%Y-%m-%d %H:%M UTC')"
    echo "#exit $(cat run.status)"
    /bin/bash ./manifest.sh || echo "#manifest-failed $?"
  } >manifest.new 2>>run.log
  mv manifest.new manifest
  rm -f "$HOME/workhorse.lock/started"
  rmdir "$HOME/workhorse.lock"
}
trap finish EXIT
# A file in the lock tells sync.sh that this run started, so it never removes the lock of a run that is going.
: >"$HOME/workhorse.lock/started"

# Whether file $1 declares, in its first lines, that it runs sudo.
declares_sudo() { head -n 10 "$1" | grep -qx '# needs: sudo'; }

# Runs $2... as step $1, with the sudo password in its environment only when $needs_sudo is yes.
run_step() {
  local needs_sudo=$1
  shift
  if [ "$needs_sudo" = yes ]; then
    SUDO_PW=$sudo_pw SUDO_ASKPASS=$HOME/.local/bin/askpass-env "$@"
  else
    "$@"
  fi
}

# Rebuilds env.sh from the base and every recipe's snippet, then loads it here for the next step.
build_env() {
  local snippet
  {
    cat ./env.sh
    for snippet in "$state"/env.d/*.sh; do
      [ -f "$snippet" ] || continue
      echo "# ${snippet##*/}"
      cat "$snippet"
    done
    echo 'workhorse_path_add "$HOME/.local/bin"'
    echo 'export PATH'
  } >"$state/env.sh.new"
  mv "$state/env.sh.new" "$state/env.sh"
  # Snippets come from installers that were not written for set -eu, so they load without it.
  set +eu
  # shellcheck source=/dev/null
  . "$state/env.sh"
  set -eu
}

# ~/.zshenv gets one line that sources env.sh, added once; the rest of the file stays the user's.
zshenv_line='. "$HOME/.local/share/claude-workhorses/env.sh" # claude-workhorses'
step="env"
mkdir -p "$state/env.d" "$HOME/.local/bin"
install -m 700 ./askpass-env "$HOME/.local/bin/askpass-env"
build_env
if ! grep -qxF "$zshenv_line" "$HOME/.zshenv" 2>/dev/null; then
  # A file that does not end in a newline would join the line onto its last one.
  if [ -s "$HOME/.zshenv" ] && [ -n "$(tail -c 1 "$HOME/.zshenv")" ]; then echo >>"$HOME/.zshenv"; fi
  printf '%s\n' "$zshenv_line" >>"$HOME/.zshenv"
fi

if [ -n "$sudo_pw" ]; then
  step=sudo
  run_step yes sudo -A -v
fi

# ./options: one host option per line, then "sudo" when it needs the password; sync.sh checked them.
# The lists are read on descriptor 3 and each step gets /dev/null as stdin, so a step that reads stdin
# cannot swallow the lines after it.
while read -r option needs <&3; do
  step="option:$option"
  echo "=== option $option"
  run_step "$([ "$needs" = sudo ] && echo yes || echo no)" ./options.sh apply "$option" </dev/null 3<&-
done 3<./options

# ./tools: one recipe and its arguments per line, already filtered for this host and checked by sync.sh.
# The arguments reach the recipe as argv, never as shell text.
while read -r -a words <&3; do
  [ ${#words[@]} -gt 0 ] || continue
  step=${words[0]}
  [[ $step =~ ^[a-z0-9][a-z0-9-]*$ ]] && [ -f "./recipes/$step" ] || { echo "no recipe \"$step\" was sent" >&2; exit 1; }
  echo "=== ${words[*]}"
  run_step "$(declares_sudo "./recipes/$step" && echo yes || echo no)" ./recipes/"$step" install "${words[@]:1}" </dev/null 3<&-
  build_env
done 3<./tools
step=""
