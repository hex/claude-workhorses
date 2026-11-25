# ABOUTME: Helpers the recipes in ~/workhorse/recipes share on a workhorse; each recipe sources this file.
# ABOUTME: env_snippet saves a recipe's PATH and variables for every later shell; need names a missing prerequisite.
# shellcheck shell=bash

# The folder that holds env.sh, which ~/.zshenv sources, and the snippets apply.sh builds it from.
workhorse_state=$HOME/.local/share/claude-workhorses

# Saves stdin as recipe $1's environment snippet, sh syntax; apply.sh folds every snippet into env.sh.
# Add a folder to PATH with workhorse_path_add <folder>, which env.sh defines.
env_snippet() {
  mkdir -p "$workhorse_state/env.d"
  cat >"$workhorse_state/env.d/$1.sh"
}

# Fails, naming what recipe $1 needs and the tools line that would provide it.
need() {
  echo "$1 needs $2" >&2
  exit 1
}
