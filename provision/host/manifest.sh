#!/bin/bash
# ABOUTME: Prints what this workhorse has: its base facts, then each tools line with its recipe's probe, then each option's probe.
# ABOUTME: apply.sh stores the output as ~/workhorse/manifest after a sync; sync.sh diff runs it and compares the tools blocks.
set -uo pipefail
cd "$HOME/workhorse" || exit 1
# Snippets come from installers that were not written for set -u, so env.sh loads without it.
set +u
# shellcheck source=/dev/null
[ ! -f "$HOME/.local/share/claude-workhorses/env.sh" ] || . "$HOME/.local/share/claude-workhorses/env.sh"
set -u

echo "#base"
echo "arch $(uname -m)"
# A Mac records "macos <version>", which sync.sh diff and the policy read; Linux records "linux" and
# the release's PRETTY_NAME from /etc/os-release.
if [ "$(uname -s)" = Darwin ]; then
  echo "macos $(sw_vers -productVersion 2>/dev/null || echo unknown)"
else
  release=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | head -n 1 | tr -d "\"'")
  echo "linux ${release:-unknown}"
fi
# One block per tools line: the line, then what its recipe's probe prints, sorted.
while read -r -a words <&3; do
  [ ${#words[@]} -gt 0 ] || continue
  echo "#line ${words[*]}"
  probe=$(./recipes/"${words[0]}" probe "${words[@]:1}" 2>/dev/null </dev/null 3<&-) || echo "${words[0]} probe-failed $?"
  # A # starts this file's own header lines, so a probe line cannot start with one.
  [ -z "$probe" ] || LC_ALL=C sort <<<"$probe" | sed 's/^#*//'
done 3<./tools
while read -r option _ <&3; do
  echo "#option $option"
  ./options.sh probe "$option" 2>&1 </dev/null 3<&-
done 3<./options
