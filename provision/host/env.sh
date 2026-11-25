# shellcheck shell=sh
# claude-workhorses: the PATH and variables the recipes on this workhorse set, for every shell.
# apply.sh writes ~/.local/share/claude-workhorses/env.sh from this file and the recipes' snippets;
# ~/.zshenv sources it. sh syntax, so bash sources it too.
workhorse_path_add() {
  case ":$PATH:" in
    *":$1:"*) ;;
    *) PATH="$1:$PATH" ;;
  esac
}
