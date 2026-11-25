#!/bin/bash
# ABOUTME: Checks how scripts/lib/hosts.sh reads the hosts file and calls the sudo-password helper; no host is contacted.
# ABOUTME: Usage: tests/hosts-check.sh; exits 1 on the first wrong answer.
# The helpers this writes are sh scripts held as text: their $1 and $# are theirs, not this script's.
# shellcheck disable=SC2016
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
config=$(mktemp -d "${TMPDIR:-/tmp}/hosts-check.XXXX")
trap 'rm -rf "$config"' EXIT
export CLAUDE_WORKHORSES_CONFIG_DIR=$config
# shellcheck source=../scripts/lib/hosts.sh
. "$here/../scripts/lib/hosts.sh"

# Loads a hosts file holding $3 (with no $3, the file stays as it is) and compares what load_hosts prints on stderr and its exit code.
# On success, stdout is each host's fields joined by "|", one host per line, in file order.
expect_load() {
  local label=$1 want=$2 out code
  [ $# -lt 3 ] || printf '%s\n' "$3" >"$config/hosts"
  set +e
  out=$(load_hosts 2>&1 && for i in "${!host_names[@]}"; do
    echo "${host_names[$i]}|${host_ssh[$i]}|${host_arch[$i]}|${host_cores[$i]}|${host_ram[$i]}|${host_options[$i]}"
  done)
  code=$?
  set -e
  if [ "$out" != "$want" ]; then
    echo "FAIL $label: wanted '$want', got '$out' (exit $code)" >&2
    exit 1
  fi
  echo "ok   $label"
}

expect_load "hosts load in file order; comments and blank lines are skipped; options are kept in order" \
"gamma|gamma@gamma-mini.example.test|x86_64|6|16|no-sleep wallpaper=Turquoise_Green autologin
alpha|ws-alpha|arm64|10|16|" \
"# name ssh arch cores ram options

gamma gamma@gamma-mini.example.test x86_64 6 16 no-sleep wallpaper=Turquoise_Green  autologin  # the office one
alpha   ws-alpha  arm64 10 16"

expect_load "an empty file is refused" \
"claude-workhorses: $config/hosts lists no hosts" \
"# nothing yet"

expect_load "a name with capitals or other characters is refused" \
"claude-workhorses: $config/hosts line 1: host name \"Gamma\" is not lower-case letters, digits and dashes" \
"Gamma g x86_64 6 16"

expect_load "a name used twice is refused" \
"claude-workhorses: $config/hosts line 2: host name \"gamma\" is already on line 1" \
"gamma g x86_64 6 16
gamma h x86_64 6 16"

expect_load "an ssh target that ssh would read as an option is refused" \
"claude-workhorses: $config/hosts line 1: ssh target \"-oProxyCommand=x\" for gamma is not an ssh alias or user@host" \
"gamma -oProxyCommand=x x86_64 6 16"

expect_load "an ssh target with shell characters is refused" \
"claude-workhorses: $config/hosts line 1: ssh target \"g;ls\" for gamma is not an ssh alias or user@host" \
"gamma g;ls x86_64 6 16"

expect_load "an unknown architecture is refused" \
"claude-workhorses: $config/hosts line 1: arch \"amd64\" for gamma is not x86_64 or arm64" \
"gamma g amd64 6 16"

expect_load "cores that are not a whole number are refused" \
"claude-workhorses: $config/hosts line 1: cores \"6.5\" for gamma is not a whole number" \
"gamma g x86_64 6.5 16"

expect_load "RAM that is not a whole number of GB is refused" \
"claude-workhorses: $config/hosts line 1: RAM \"16GB\" for gamma is not a whole number of GB" \
"gamma g x86_64 6 16GB"

expect_load "a host with no RAM column is refused" \
"claude-workhorses: $config/hosts line 1: RAM \"\" for gamma is not a whole number of GB" \
"gamma g x86_64 6"

expect_load "an option outside the known set is refused, naming the set" \
"claude-workhorses: $config/hosts line 1: option \"dedicated\" for gamma is not one of: autologin, dock, firewall, git-identity, headless, key-only-ssh, maxfiles, no-sleep, no-spotlight, screensharing, tailscale, wallpaper=<name>, wifi-off" \
"gamma g x86_64 6 16 dedicated"

expect_load "an option given twice is refused" \
"claude-workhorses: $config/hosts line 1: option \"dock\" for gamma is given twice" \
"gamma g x86_64 6 16 dock no-sleep dock"

expect_load "wallpaper takes a name, written with _ for each space; digits are allowed" \
"gamma|g|x86_64|6|16|wallpaper=Gold_2" \
"gamma g x86_64 6 16 wallpaper=Gold_2"

expect_load "wallpaper with no name is refused" \
"claude-workhorses: $config/hosts line 1: wallpaper \"\" for gamma is not a Solid Colors name (letters and digits, _ for a space)" \
"gamma g x86_64 6 16 wallpaper="

expect_load "a wallpaper twice is refused like any other option" \
"claude-workhorses: $config/hosts line 1: option \"wallpaper\" for gamma is given twice" \
"gamma g x86_64 6 16 wallpaper=Teal wallpaper=Cyan"

expect_load "a wallpaper name that could break out of the wallpaper script is refused" \
"claude-workhorses: $config/hosts line 1: wallpaper \"Blue\"\" for gamma is not a Solid Colors name (letters and digits, _ for a space)" \
'gamma g x86_64 6 16 wallpaper=Blue"'

expect_load "an option is a word, never a file pattern" \
"claude-workhorses: $config/hosts line 1: option \"*\" for gamma is not one of: autologin, dock, firewall, git-identity, headless, key-only-ssh, maxfiles, no-sleep, no-spotlight, screensharing, tailscale, wallpaper=<name>, wifi-off" \
"gamma g x86_64 6 16 *"

expect_load "a value on an option that takes none is refused" \
"claude-workhorses: $config/hosts line 1: option \"dock=yes\" for gamma is not one of: autologin, dock, firewall, git-identity, headless, key-only-ssh, maxfiles, no-sleep, no-spotlight, screensharing, tailscale, wallpaper=<name>, wifi-off" \
"gamma g x86_64 6 16 dock=yes"

rm -f "$config/hosts"
expect_load "a missing hosts file names the path to create" \
"claude-workhorses: no hosts file at $config/hosts; the README's First run section shows one"
printf '%s\n' "gamma g x86_64 6 16" >"$config/hosts"

# Asks sudo_password for host gamma and compares stdout+stderr and the exit code.
expect_password() {
  local label=$1 want=$2 want_exit=$3 out code
  set +e
  out=$(sudo_password gamma 2>&1)
  code=$?
  set -e
  if [ "$out" != "$want" ] || [ "$code" != "$want_exit" ]; then
    echo "FAIL $label: wanted '$want' exit $want_exit, got '$out' exit $code" >&2
    exit 1
  fi
  echo "ok   $label"
}

helper=$config/sudo-password
expect_password "a missing helper is named" \
"claude-workhorses: no executable sudo-password helper at $helper" 1

printf '#!/bin/sh\necho "pw-for-$1"\n' >"$helper"
chmod 600 "$helper"
expect_password "a helper that is not executable is refused" \
"claude-workhorses: no executable sudo-password helper at $helper" 1

chmod 720 "$helper"
expect_password "a helper others can write is refused" \
"claude-workhorses: $helper is writable by others than you; chmod go-w it" 1

chmod 700 "$helper"
expect_password "the helper gets the host name as its one argument" "pw-for-gamma" 0

printf '#!/bin/sh\necho "$#:$*"\n' >"$helper"
expect_password "the helper gets exactly one argument" "1:gamma" 0

printf '#!/bin/sh\necho "no password for $1" >&2\nexit 4\n' >"$helper"
expect_password "a failing helper stops with its own message" \
"no password for gamma
claude-workhorses: the sudo-password helper failed for gamma (exit 4)" 1

printf '#!/bin/sh\nexit 0\n' >"$helper"
expect_password "a helper that prints nothing is refused" \
"claude-workhorses: the sudo-password helper printed nothing for gamma" 1

echo "all hosts-file and helper checks passed"
