#!/bin/bash
# ABOUTME: Checks the first-copy guard against the routes on this machine without contacting a host.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
mirror=$here/../scripts/mirror.sh
eval "$(sed -n '/^tailscale_route() {$/,/^}$/p; /^in_tailscale_range() {$/,/^}$/p' "$mirror")"
fail() { echo "FAIL $*" >&2; exit 1; }

[ "$(tailscale_route 100.64.0.1)" = 100.64.0.1 ] || fail "100.64.0.1 should count as Tailscale"
echo "ok   an address in Tailscale's range counts"
status=0
out=$(tailscale_route 127.0.0.1 2>&1) || status=$?
[ "$status" = 1 ] && [ -z "$out" ] || fail "loopback should return 1 silently, got $status '$out'"
echo "ok   loopback does not count"

if [ "$(uname -s)" = Darwin ]; then
  # netstat abbreviates network destinations, so fill in missing octets before asking for the route.
  routes=$(netstat -rn -f inet)
  for interface in $(ifconfig -l); do
    [[ $interface = utun* ]] || continue
    addresses=$(ifconfig "$interface")
    awk '$1 == "inet" {
      split($2, a, ".")
      if (a[1] == 100 && a[2] >= 64 && a[2] <= 127) found=1
    } END {exit !found}' <<<"$addresses" || continue
    while read -r address; do
      actual=$(route -n get "$address" | awk '$1 == "interface:" {print $2}')
      [ "$actual" = "$interface" ] || continue
      out=$(tailscale_route "$address") || fail "$address via $interface should count as Tailscale"
      [ "$out" = "$address via $interface" ] || fail "wanted '$address via $interface', got '$out'"
      echo "ok   $address via $interface counts as Tailscale"
      exit 0
    done < <(awk -v iface="$interface" '$4 == iface && $1 ~ /^[0-9]/ {
      split($1, p, "/"); n=split(p[1], a, ".")
      if (a[1]>=224 || (a[1]==100 && a[2]>=64 && a[2]<=127)) next
      printf "%d.%d.%d.%d\n", a[1], a[2], a[3], (n==4 ? a[4] : 1)
    }' <<<"$routes")
  done
fi
echo "skip: no macOS subnet route through a Tailscale interface"
