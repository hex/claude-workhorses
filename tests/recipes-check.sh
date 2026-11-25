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

# On a Mac, mise comes from MacPorts and a line only installs its versions: PATH and defaults stay as they are.
expect_install "mise on a Mac" "" 0 "mise install node@26" mise Darwin node@26
[ ! -e "$HOME/.local/share/claude-workhorses/env.d/mise.sh" ] || fail "mise on a Mac wrote an env snippet: $(cat "$HOME/.local/share/claude-workhorses/env.d/mise.sh")"
rm "$bin/mise"
expect_install "mise on a Mac without mise" "mise needs mise: list a recipe that installs it (port mise, say) before it" 1 "" mise Darwin node@26
echo "ok   on a Mac, mise only installs the versions, and a missing mise names the line that brings it"

# On Linux, the recipe installs mise itself into ~/.local/bin, then keeps it current; the line's
# versions become the global ones, the first of a tool its default, reached through mise's shims.
expect_install "mise on Linux without mise" "" 0 "curl -fsSL https://mise.run
mise use -g node@24 node@26 go@1.27" mise Linux node@24 node@26 go@1.27
[ -x "$HOME/.local/bin/mise" ] || fail "mise's installer put no mise in ~/.local/bin"
expect_install "mise on Linux, a second time" "" 0 "mise self-update --yes
mise use -g node@24 node@26 go@1.27" mise Linux node@24 node@26 go@1.27
shims=$(env -i HOME="$HOME" PATH=/usr/bin:/bin /bin/sh -c '. "$1"; . "$2"; printf "%s\n" "$PATH"' _ "$scratch/env.sh" "$HOME/.local/share/claude-workhorses/env.d/mise.sh")
[ "${shims%%:*}" = "$HOME/.local/share/mise/shims" ] || fail "after mise's env snippet, PATH is '$shims'"
echo "ok   on Linux, mise installs itself, then updates itself, sets the line's versions as the defaults and puts its shims first on the PATH"

# The probe prints a line for each tool, once however many of its versions the line names.
printf '%s\n' '#!/bin/bash' 'case "$3" in node) printf "node  24.22.3\nnode  26.13.1\n" ;; go) echo "go  1.27.4" ;; esac' >"$HOME/.local/bin/mise"
out=$(PATH=$path "$BASH" "$scratch/recipes/mise" probe node@24 node@26 go@1.27 ruby@3.4)
[ "$out" = "mise-node 24.22.3 26.13.1
mise-go 1.27.4
mise-ruby missing" ] || fail "mise's probe printed '$out'"
echo "ok   mise's probe prints each tool's installed versions once, or missing"

# uv names its build target, which differs between architectures and systems; the probe drops it so hosts compare.
printf '%s\n' '#!/bin/bash' 'echo "$RECIPES_CHECK_UV"' >"$bin/uv"
for version in "uv 0.13.9 (6b2d39dcc 2026-11-17 aarch64-apple-darwin)=uv uv 0.13.9 (6b2d39dcc 2026-11-17)" \
  "uv 0.13.10 (x86_64-unknown-linux-gnu)=uv uv 0.13.10" "uv 0.13.10 (aarch64-unknown-linux-gnu)=uv uv 0.13.10"; do
  out=$(RECIPES_CHECK_UV=${version%%=*} PATH=$path "$BASH" "$scratch/recipes/uv" probe)
  [ "$out" = "${version#*=}" ] || fail "uv's probe of '${version%%=*}': wanted '${version#*=}', got '$out'"
done
echo "ok   uv's probe drops the build target, a Mac's or a Linux host's"

echo "all recipe checks passed"
