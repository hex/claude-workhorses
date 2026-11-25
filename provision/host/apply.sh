#!/bin/bash
# ABOUTME: Runs on a workhorse: "apply.sh start" reads the sudo password line on stdin and starts "apply.sh run" detached, which applies
# ABOUTME: ./options, then the recipes in ./tools, in order, stops at the first failure, writes run.status ("<exit> [<step>]") and the manifest, and frees the lock.
set -euo pipefail

here=$HOME/workhorse
state=$HOME/.local/share/claude-workhorses
cd "$here"

# sync.sh's ssh runs "apply.sh start" with the password on stdin, so no variable carries it through
# the login shell that reads ~/.zshenv. start marks the lock as taken by a run, then hands the
# password to the detached run on descriptor 3, a pipe from the printf builtin: it never sits in an
# environment variable, an argument or a file.
case "${1:-}" in
  start)
    sudo_pw=""
    IFS= read -r sudo_pw || true
    # A file in the lock tells sync.sh that this run started, so it never removes the lock of a run that is going.
    : >"$HOME/workhorse.lock/started"
    rm -f run.status
    nohup /bin/bash ./apply.sh run >run.log 2>&1 </dev/null 3< <(printf '%s\n' "$sudo_pw") &
    exit 0 ;;
  run) ;;
  *) echo "usage: apply.sh start|run" >&2; exit 2 ;;
esac

# The password stays in this shell, unexported, and no file is ever sourced here; only the steps that
# declare sudo get it.
sudo_pw=""
IFS= read -r sudo_pw <&3 || true
exec 3<&-
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

# Whether file $1 declares, in its first lines, that it runs sudo.
declares_sudo() { head -n 10 "$1" | grep -qx '# needs: sudo'; }

# Runs $2... as a step, in step_env, with the sudo password in its environment only when $1 is yes.
# The subshell runs no code but this, and the step replaces it.
run_step() {
  local needs_sudo=$1
  shift
  (
    # shellcheck disable=SC2163 # each record is NAME=value, exported as it stands
    for record in ${step_env[@]+"${step_env[@]}"}; do export "$record" 2>/dev/null || true; done
    if [ "$needs_sudo" = yes ]; then
      export SUDO_PW="$sudo_pw" SUDO_ASKPASS="$HOME/.local/bin/askpass-env"
    fi
    exec "$@"
  )
}

# Rebuilds env.sh from the base and every recipe's snippet, then reads the environment the next step
# runs in into step_env, as NAME=value records. A separate bash, started fresh so it holds no variable
# of this shell, with stdin from /dev/null and no descriptor but its output, sources env.sh and prints
# every exported variable; this shell only reads its output as data.
build_env() {
  local snippet record
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
  step_env=()
  # Snippets come from installers that were not written for set -eu, so they load without it.
  # shellcheck disable=SC2016 # the script is the inner bash's
  while IFS= read -r -d '' record; do
    if [[ $record =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then step_env+=("$record"); fi
  done < <(/bin/bash -c '. "$1" >&2; for name in $(compgen -e); do printf "%s=%s\0" "$name" "${!name}"; done' \
    _ "$state/env.sh" </dev/null 3<&-)
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
