#!/bin/bash
# ABOUTME: The ssh the captures run, as `ssh` on their PATH: alpha-mini goes to the host in WH_CAPTURE_SSH_TARGET,
# ABOUTME: so the hosts file and every image name only alpha; drops the connection notice some ssh configs print.
set -uo pipefail
args=()
for arg in "$@"; do
  if [ "$arg" = alpha-mini ]; then args+=("$WH_CAPTURE_SSH_TARGET"); else args+=("$arg"); fi
done
# A ProxyCommand or Match exec that runs `nc -v` prints a line naming the host's address for each connection.
# The pipe ends before this script does, so the job's stderr keeps its order.
{ /usr/bin/ssh ${args[@]+"${args[@]}"} 2>&1 1>&3 3>&- | grep -v --line-buffered -E '^Connection to .* succeeded[!]' >&2; } 3>&1
exit "${PIPESTATUS[0]}"
