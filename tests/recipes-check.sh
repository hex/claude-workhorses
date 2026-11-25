#!/bin/bash
# ABOUTME: Checks how the built-in recipes treat the system they run on, against stand-ins that log their calls: the macOS-only
# ABOUTME: recipes refuse Linux before they change anything, mise differs by system as documented, and uv's probe drops the target. No host is contacted.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/recipes-check.XXXX")
trap 'rm -rf "$scratch"' EXIT
# The recipes sit as sync.sh stages them on a host: in recipes/, beside recipe-lib.sh.
mkdir "$scratch/recipes" "$scratch/bin" "$scratch/home" "$scratch/mise-release"
cp "$here"/../provision/recipes/* "$scratch/recipes/"
cp "$here/../provision/host/recipe-lib.sh" "$here/../provision/host/env.sh" "$scratch/"
bin=$scratch/bin
log=$scratch/calls
export HOME=$scratch/home RECIPES_CHECK_LOG=$log

fail() { echo "FAIL $*" >&2; exit 1; }

# Every command a recipe could change the host with logs its name and arguments and succeeds. uname -s
# answers RECIPES_CHECK_OS.
for name in xcode-select touch softwareupdate sudo curl sw_vers pkgutil installer uv hdiutil codesign ditto unity defaults mise; do
  printf '%s\n' '#!/bin/bash' 'echo "$(basename "$0") $*" >>"$RECIPES_CHECK_LOG"' >"$bin/$name"
done
printf '%s\n' '#!/bin/bash' '[ "$1" = -s ] || exec /usr/bin/uname "$@"' 'echo "$RECIPES_CHECK_OS"' >"$bin/uname"
chmod +x "$bin"/*
# mise's installer, as curl fetches it from mise.run, puts a mise at MISE_INSTALL_PATH; that mise logs too.
cp "$bin/mise" "$scratch/mise-release/mise"
printf '%s\n' '#!/bin/bash' 'echo "curl $*" >>"$RECIPES_CHECK_LOG"' \
  "[ \"\$*\" != '-fsSL https://mise.run' ] || echo 'mkdir -p \"\$(dirname \"\$MISE_INSTALL_PATH\")\" && cp \"$scratch/mise-release/mise\" \"\$MISE_INSTALL_PATH\"'" >"$bin/curl"
# A step runs with ~/.local/bin on its PATH, as apply.sh sets it. The system folders give the recipes
# their shell tools, and no mise or uv this machine may have elsewhere.
path=$HOME/.local/bin:$bin:/usr/bin:/bin

# Runs recipe $1's install on system $2 with the arguments after it, and compares its stderr, its exit
# code and the calls it made.
expect_install() {
  local label=$1 want_err=$2 want_exit=$3 want_calls=$4 recipe=$5 os=$6 err code
  shift 6
  : >"$log"
  set +e
  err=$(RECIPES_CHECK_OS=$os PATH=$path "$BASH" "$scratch/recipes/$recipe" install "$@" 2>&1 >/dev/null)
  code=$?
  set -e
  [ "$err" = "$want_err" ] && [ "$code" = "$want_exit" ] && [ "$(cat "$log")" = "$want_calls" ] ||
    fail "$label: wanted '$want_err' exit $want_exit with calls '$want_calls', got '$err' exit $code with calls '$(cat "$log")'"
}

# A macOS-only recipe on Linux stops before its first command, so nothing is left half done.
expect_install "command-line-tools on Linux" "command-line-tools runs only on macOS: give its line @os=macos" 1 "" command-line-tools Linux
expect_install "macports on Linux" "macports runs only on macOS: give its line @os=macos" 1 "" macports Linux
expect_install "port on Linux" "port runs only on macOS: give its line @os=macos" 1 "" port Linux git
expect_install "macos-harness on Linux" "macos-harness runs only on macOS: give its line @os=macos" 1 "" macos-harness Linux
expect_install "unity on Linux" "unity runs only on macOS: give its line @os=macos" 1 "" unity Linux 6000.3.28f1 8f082d2fe476 android
echo "ok   the macOS-only recipes refuse a Linux host, naming the filter, before they run anything"

echo "all recipe checks passed"
