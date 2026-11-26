#!/bin/bash
# ABOUTME: Runs on a workhorse: "apply.sh start" reads the sudo password line on stdin and starts "apply.sh run" detached, which applies
# ABOUTME: ./options, then the recipes in ./tools, in order, stops at the first failure, writes run.status ("<exit> [<step>]") and the manifest, and frees the lock.
set -euo pipefail

here=$HOME/workhorse
state=$HOME/.local/share/workhorses
cd "$here"

# sync.sh's ssh runs "apply.sh start" with the password on stdin, so no variable carries it through
# the login shell that reads ~/.zshenv or ~/.bashrc. start marks the lock as taken by a run, then hands the
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
  # Snippets come from installers that were not written for set -eu, so they load without it. The
  # last record, "-end-", shows that env.sh ran to its end.
  local ended=no
  # shellcheck disable=SC2016 # the script is the inner bash's
  while IFS= read -r -d '' record; do
    if [ "$record" = -end- ]; then
      ended=yes
    elif [[ $record =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      step_env+=("$record")
    fi
  done < <(/bin/bash -c '. "$1" >&2; for name in $(compgen -e); do printf "%s=%s\0" "$name" "${!name}"; done; printf "%s\0" -end-' \
    _ "$state/env.sh" </dev/null 3<&-)
  if [ $ended != yes ]; then
    echo "env.sh stopped before its end: a snippet in $state/env.d exits or fails, and the steps would miss what it sets" >&2
    return 1
  fi
}

# wh's commands run in the host's login shell, so the file that shell reads for an ssh command gets
# one line that sources env.sh, added once; the rest of the file stays the user's. On a Mac that is
# ~/.zshenv. On Linux, zsh reads ~/.zshenv too, and bash started by sshd reads ~/.bashrc, whose stock
# first lines return from a shell that is not interactive: the line goes above them.
source_line='. "$HOME/.local/share/workhorses/env.sh" # workhorses'
step="env"
mkdir -p "$state/env.d" "$HOME/.local/bin"
install -m 700 ./askpass-env "$HOME/.local/bin/askpass-env"
build_env
rc=.zshenv
if [ "$(uname -s)" != Darwin ]; then
  case "${SHELL##*/}" in
    bash) rc=.bashrc ;;
    zsh) ;;
    *) echo "the login shell is $SHELL; wh's commands get the recipes' PATH only from bash (~/.bashrc) or zsh (~/.zshenv)" >&2; exit 1 ;;
  esac
fi
if ! grep -qxF "$source_line" "$HOME/$rc" 2>/dev/null; then
  if [ "$rc" = .bashrc ] && [ -s "$HOME/.bashrc" ]; then
    # Writing into the file, not over it, keeps its owner, mode and any symlink to it.
    { printf '%s\n' "$source_line"; cat "$HOME/.bashrc"; } >bashrc.new
    cat bashrc.new >"$HOME/.bashrc"
    rm -f bashrc.new
  else
    # A file that does not end in a newline would join the line onto its last one.
    if [ -s "$HOME/$rc" ] && [ -n "$(tail -c 1 "$HOME/$rc")" ]; then echo >>"$HOME/$rc"; fi
    printf '%s\n' "$source_line" >>"$HOME/$rc"
  fi
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
  # An install can exit 0 and leave its tool unusable, when an earlier run cut short left a folder the
  # installer takes for a finished install; the step counts only when its probe finds the tool.
  missing=$(run_step no ./recipes/"$step" probe "${words[@]:1}" </dev/null 3<&- | grep -E '(^| )missing$' || true)
  if [ -n "$missing" ]; then
    echo "$step: the install ended, but its probe reports: $(paste -sd ',' - <<<"$missing")" >&2
    exit 1
  fi
done 3<./tools
step=""
