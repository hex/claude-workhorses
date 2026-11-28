#!/bin/bash
# ABOUTME: Checks how scripts/lib/tools.sh reads the tools file and user recipes, and which lines each host gets; no host is contacted.
# ABOUTME: Usage: tests/tools-check.sh; exits 1 on the first wrong answer.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
config=$(mktemp -d "${TMPDIR:-/tmp}/tools-check.XXXX")
trap 'rm -rf "$config"' EXIT
export WORKHORSES_CONFIG_DIR=$config
chmod 700 "$config"
builtin=$(cd "$here/../provision/recipes" && pwd -P)
# shellcheck source=../scripts/lib/hosts.sh
. "$here/../scripts/lib/hosts.sh"
# shellcheck source=../scripts/lib/tools.sh
. "$here/../scripts/lib/tools.sh"

printf '%s\n' "alpha a x86_64 6 16" "beta b x86_64 6 16 no-sleep" "gamma g arm64 10 16" >"$config/hosts"
load_hosts

fail() { echo "FAIL $*" >&2; exit 1; }

# Loads a tools file holding $3 (with no $3, the file stays as it is) and compares what load_tools
# prints on stderr and each host's lines on stdout ("<host>: <line>"), and the exit code.
expect_tools() {
  local label=$1 want=$2 out code
  [ $# -lt 3 ] || printf '%s\n' "$3" >"$config/tools"
  set +e
  out=$(load_tools 2>&1 && for host in alpha beta gamma; do host_tool_lines "$host" | sed "s/^/$host: /"; done)
  code=$?
  set -e
  [ "$out" = "$want" ] || fail "$label: wanted '$want', got '$out' (exit $code)"
  echo "ok   $label"
}

expect_tools "with no tools file, no host gets a line" ""

expect_tools "lines load in order; filters pick the hosts; comments and blanks are skipped" \
"alpha: port cmake ninja
alpha: npm @openai/codex pnpm@9
alpha: unity 6000.3.28f1 8f082d2fe476 android
alpha: dotnet 10.0
beta: port cmake ninja
beta: npm @openai/codex pnpm@9
beta: unity 6000.3.28f1 8f082d2fe476 android
gamma: port cmake ninja
gamma: npm @openai/codex pnpm@9
gamma: dotnet 10.0" \
"# recipe and arguments, then any filters
port   cmake ninja

npm @openai/codex pnpm@9   # agents
unity 6000.3.28f1 8f082d2fe476 android @arch=x86_64
dotnet @hosts=alpha,gamma 10.0"

expect_tools "both filters must hold" \
"alpha: bun" \
"bun @arch=x86_64 @hosts=alpha,gamma"

# The hosts file does not say which OS a host runs: sync.sh asks each host, diff and the policy read
# its manifest. Here gamma runs Linux.
host_os=(macos macos linux)
expect_tools "@os picks the hosts that run that OS, together with the other filters" \
"alpha: port cmake
alpha: bun
beta: port cmake
beta: bun
gamma: apt git
gamma: bun" \
"apt git @os=linux
port cmake @os=macos
uv @os=macos @hosts=gamma
bun"

expect_tools "@os given twice is refused" \
"workhorses: $config/tools line 1: filter @os for apt is given twice" \
"apt git @os=linux @os=macos"

host_os=(macos "" linux)
printf '%s\n' "apt git @os=linux" "bun" >"$config/tools"
load_tools
out=$(host_tool_lines beta 2>&1)
[ "$out" = "workhorses: the OS beta runs is not known, so the @os=linux filter of apt cannot be checked
bun" ] || fail "a host whose OS is not known: got '$out'"
echo "ok   a line filtered by @os names a host whose OS is not known and leaves the line out"
host_os=(macos macos macos)

file=$config/tools
for bad in Port ../port -x port.sh; do
  expect_tools "recipe name \"$bad\" is refused" \
  "workhorses: $file line 1: recipe \"$bad\" is not lower-case letters, digits and dashes" \
  "$bad cmake"
done

expect_tools "a recipe neither built in nor in the user folder is refused" \
"workhorses: $file line 2: no recipe \"nosuch\" in $builtin or $config/recipes" \
"port cmake
nosuch"

# shellcheck disable=SC2088 # a literal ~ is one of the words checked
for bad in -g 'a;b' '$(id)' 'x=y' "it's" '~/x' 'a*'; do
  expect_tools "argument \"$bad\" is refused" \
  "workhorses: $file line 1: argument \"$bad\" for port is not letters, digits and @._/+- (and does not start with -)" \
  "port cmake $bad"
done

expect_tools "a word that starts with @ but is no scoped package or filter is refused" \
"workhorses: $file line 1: argument \"@arch\" for npm starts with @ but is not a scoped package (@scope/name); a host filter is @arch=<arch>, @os=<os> or @hosts=<names>" \
"npm @arch"

expect_tools "an unknown filter is refused" \
"workhorses: $file line 1: filter \"@cpu=6\" for bun is not @arch=x86_64|arm64, @os=macos|linux or @hosts=<name>,..." \
"bun @cpu=6"

expect_tools "an unknown OS is refused" \
"workhorses: $file line 1: filter \"@os=windows\" for bun is not @arch=x86_64|arm64, @os=macos|linux or @hosts=<name>,..." \
"bun @os=windows"

expect_tools "an unknown architecture is refused" \
"workhorses: $file line 1: filter \"@arch=amd64\" for bun is not @arch=x86_64|arm64, @os=macos|linux or @hosts=<name>,..." \
"bun @arch=amd64"

expect_tools "a host the hosts file does not list is refused" \
"workhorses: $file line 1: filter @hosts names \"delta\", which is not in the hosts file" \
"bun @hosts=alpha,delta"

expect_tools "an empty host list is refused" \
"workhorses: $file line 1: filter \"@hosts=\" for bun is not @arch=x86_64|arm64, @os=macos|linux or @hosts=<name>,..." \
"bun @hosts="

expect_tools "a filter given twice is refused" \
"workhorses: $file line 1: filter @arch for bun is given twice" \
"bun @arch=x86_64 @arch=arm64"

mkdir "$config/recipes"
chmod 700 "$config/recipes"
printf '#!/bin/sh\nexit 0\n' >"$config/recipes/my-tool"
chmod 700 "$config/recipes/my-tool"
expect_tools "a user recipe the user owns and alone can write is taken" \
"alpha: my-tool 1.2
beta: my-tool 1.2
gamma: my-tool 1.2" \
"my-tool 1.2"

chmod 720 "$config/recipes/my-tool"
expect_tools "a user recipe others can write is refused" \
"workhorses: $file line 1: $config/recipes/my-tool is writable by others than you; chmod go-w it"
chmod 700 "$config/recipes/my-tool"

chmod 600 "$config/recipes/my-tool"
expect_tools "a user recipe that is not executable is refused" \
"workhorses: $file line 1: recipe $config/recipes/my-tool is not an executable file"
chmod 700 "$config/recipes/my-tool"

chmod 770 "$config/recipes"
expect_tools "a user recipe folder others can write is refused" \
"workhorses: $file line 1: $config/recipes is writable by others than you; chmod go-w it"
chmod 700 "$config/recipes"

chmod 770 "$config"
expect_tools "a config folder others can write is refused, so nobody can swap the recipe folder" \
"workhorses: $file line 1: $config is writable by others than you; chmod go-w it"
chmod 700 "$config"

# A symlink would send whatever it points at, the sudo-password helper say, to every host.
printf '#!/bin/sh\necho pw\n' >"$config/sudo-password"
chmod 700 "$config/sudo-password"
ln -s ../sudo-password "$config/recipes/leak"
expect_tools "a user recipe that is a symlink is refused" \
"workhorses: $file line 1: recipe $config/recipes/leak is a symlink; put the file itself there" \
"leak"
rm "$config/recipes/leak"
mkdir -m 700 "$config/recipes/folder"
expect_tools "a user recipe that is a folder is refused" \
"workhorses: $file line 1: recipe $config/recipes/folder is not an executable file" \
"folder"
rmdir "$config/recipes/folder"

cp "$config/recipes/my-tool" "$config/recipes/port"
expect_tools "a user recipe may not take a built-in recipe's name" \
"workhorses: $file line 1: user recipe $config/recipes/port has the name of a built-in recipe; rename it" \
"port cmake"
rm "$config/recipes/port"

# Compares host_needs_sudo's answer for each host: "<host> yes|no".
expect_sudo() {
  local label=$1 want=$2 out host
  printf '%s\n' "$3" >"$config/tools"
  load_tools
  out=$(for host in alpha beta gamma; do
    if host_needs_sudo "$host"; then echo "$host yes"; else echo "$host no"; fi
  done)
  [ "$out" = "$want" ] || fail "$label: wanted '$want', got '$out'"
  echo "ok   $label"
}

expect_sudo "with no lines, only a host with a sudo option needs the password" \
"alpha no
beta yes
gamma no" ""

expect_sudo "a recipe that declares sudo needs it on the hosts it targets, and only there" \
"alpha yes
beta yes
gamma no" \
"npm pnpm
my-tool
port cmake @arch=x86_64"

echo "all tools-file checks passed"
