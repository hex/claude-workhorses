#!/bin/bash
# ABOUTME: Checks the apt recipe against stand-ins for sudo, apt-get, apt-cache and dpkg-query that log what they get.
# ABOUTME: Usage: tests/apt-check.sh; nothing is installed and no host is contacted; exits 1 on the first wrong answer.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/apt-check.XXXX")
trap 'rm -rf "$scratch"' EXIT
# The recipe sits as sync.sh stages it on a host: in recipes/, beside recipe-lib.sh.
mkdir "$scratch/recipes" "$scratch/bin"
cp "$here/../provision/recipes/apt" "$scratch/recipes/apt"
cp "$here/../provision/host/recipe-lib.sh" "$scratch/recipe-lib.sh"
recipe=$scratch/recipes/apt
bin=$scratch/bin
log=$scratch/apt-get.log
unset DEBIAN_FRONTEND

fail() { echo "FAIL $*" >&2; exit 1; }

# sudo -A runs the rest of its line. apt-get logs DEBIAN_FRONTEND and its arguments, one call a line.
# apt-cache knows a few packages and, like the real one, lists for pkgnames the names that start with
# its argument, read as plain text.
printf '%s\n' '#!/bin/bash' '[ "$1" != -A ] || shift' 'exec "$@"' >"$bin/sudo"
printf '%s\n' '#!/bin/bash' "echo \"\${DEBIAN_FRONTEND:-unset} \$*\" >>'$log'" >"$bin/apt-get"
cat >"$bin/apt-cache" <<'EOF'
#!/bin/bash
[ "$1" = pkgnames ] || { echo "apt-cache stand-in: no $1" >&2; exit 2; }
for name in curl git nodejs openssh-server; do
  case $name in "$2"*) echo "$name" ;; esac
done
EOF
chmod +x "$bin/sudo" "$bin/apt-get" "$bin/apt-cache"
export PATH=$bin:$PATH

# Runs the recipe's install with the given packages and compares its stderr, its exit code and the
# apt-get calls it made.
expect_install() {
  local label=$1 want_err=$2 want_exit=$3 want_calls=$4 err code
  shift 4
  : >"$log"
  set +e
  err=$("$BASH" "$recipe" install "$@" 2>&1 >/dev/null)
  code=$?
  set -e
  [ "$err" = "$want_err" ] && [ "$code" = "$want_exit" ] && [ "$(cat "$log")" = "$want_calls" ] ||
    fail "$label: wanted '$want_err' exit $want_exit with apt-get '$want_calls', got '$err' exit $code with apt-get '$(cat "$log")'"
  echo "ok   $label"
}

# apt-get reads a name ending in - as a package to remove, and one ending in + as one to install.
expect_install "a name ending in - is refused before apt-get runs" \
  'apt: "openssh-server-" is not a Debian package name' 1 "" git openssh-server-
expect_install "a name ending in + is refused before apt-get runs" \
  'apt: "git+" is not a Debian package name' 1 "" git+
# apt-get reads a name that no package has, with . or * in it, as a pattern.
expect_install "a name no package has exactly is refused after the lists are fresh, before the install" \
  'apt: no package is named "node.js"' 1 "unset update -q" git node.js
expect_install "known names are installed without a question" "" 0 "unset update -q
noninteractive install -y -q git curl" git curl

echo "all apt recipe checks passed"
