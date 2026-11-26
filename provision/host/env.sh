# shellcheck shell=sh
# workhorses: the PATH and variables the recipes on this workhorse set, for every shell.
# apply.sh writes ~/.local/share/workhorses/env.sh from this file and the recipes' snippets;
# ~/.zshenv sources it, or ~/.bashrc on a Linux host whose login shell is bash. sh syntax, so both
# shells read it.
workhorse_path_add() {
  case ":$PATH:" in
    *":$1:"*) ;;
    *) PATH="$1:$PATH" ;;
  esac
}
