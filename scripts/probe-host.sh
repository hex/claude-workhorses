#!/bin/bash
# ABOUTME: Asks a Mac or a Linux host over ssh for its architecture, physical cores and memory and prints its hosts-file line.
# ABOUTME: Usage: probe-host.sh <ssh target> [name]; the name defaults to the target's host part up to its first dot.
set -euo pipefail

lib=$(cd "$(dirname "$0")/lib" && pwd -P)
# shellcheck source=lib/hosts.sh
. "$lib/hosts.sh"
# shellcheck source=lib/bounded.sh
. "$lib/bounded.sh"

target=${1:?usage: probe-host.sh <ssh target> [name]}
if ! valid_ssh_target "$target"; then
  echo "workhorses: ssh target \"$target\" is not an ssh alias or user@host" >&2
  exit 1
fi
name=${2:-$(printf '%s' "${target#*@}" | cut -d. -f1 | tr 'A-Z_' 'a-z-')}
if ! valid_host_name "$name"; then
  echo "workhorses: host name \"$name\" is not lower-case letters, digits and dashes" >&2
  exit 1
fi

# Linux counts physical cores as the distinct core and socket pairs lscpu lists (nproc counts
# hyperthreads too), and memory as MemTotal, which /proc/meminfo gives in kB.
answer=$(run_bounded 20 ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" \
  'uname -m; if [ "$(uname -s)" = Darwin ]; then /usr/sbin/sysctl -n hw.physicalcpu hw.memsize; else lscpu -p=core,socket | grep -v "^#" | sort -u | wc -l; echo $(($(sed -n "s/^MemTotal: *\([0-9]*\) kB$/\1/p" /proc/meminfo) * 1024)); fi') ||
  { echo "workhorses: $target did not answer over ssh (BatchMode, so it needs your key)" >&2; exit 1; }
read -r arch cores memory <<<"$(tr '\n' ' ' <<<"$answer")" || true
# Linux names 64-bit ARM aarch64; the hosts file, like macOS, says arm64.
[ "$arch" != aarch64 ] || arch=arm64
if ! [[ $arch =~ ^(x86_64|arm64)$ && $cores =~ ^[1-9][0-9]*$ && $memory =~ ^[1-9][0-9]*$ ]]; then
  echo "workhorses: $target answered \"$(tr '\n' ' ' <<<"$answer" | sed 's/ $//')\", not an architecture (x86_64 or arm64), a core count and a memory size" >&2
  exit 1
fi
gigabyte=$((1024 * 1024 * 1024))
echo "$name $target $arch $cores $(((memory + gigabyte / 2) / gigabyte))"
