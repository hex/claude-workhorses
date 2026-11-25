#!/bin/bash
# ABOUTME: Prints what this workhorse has: its base facts, then each tools line with its recipe's probe, then each option's probe.
# ABOUTME: apply.sh stores the output as ~/workhorse/manifest after a sync; sync.sh diff runs it and compares the tools blocks.
set -uo pipefail
cd "$HOME/workhorse" || exit 1
# shellcheck source=/dev/null
[ ! -f "$HOME/.local/share/claude-workhorses/env.sh" ] || . "$HOME/.local/share/claude-workhorses/env.sh"

echo "#base"
echo "arch $(uname -m)"
echo "macos $(sw_vers -productVersion 2>/dev/null || echo unknown)"
# One block per tools line: the line, then what its recipe's probe prints, sorted.
while read -r -a words; do
  [ ${#words[@]} -gt 0 ] || continue
  echo "#line ${words[*]}"
  probe=$(./recipes/"${words[0]}" probe "${words[@]:1}" 2>/dev/null) || echo "${words[0]} probe-failed $?"
  # A # starts this file's own header lines, so a probe line cannot start with one.
  [ -z "$probe" ] || LC_ALL=C sort <<<"$probe" | sed 's/^#*//'
done <./tools
while read -r option _; do
  echo "#option $option"
  ./options.sh probe "$option" 2>&1
done <./options
