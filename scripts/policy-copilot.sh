#!/bin/bash
# ABOUTME: Prints the workhorse policy as additionalContext for Copilot's interactive sessionStart hook.
# ABOUTME: A policy failure reaches the session in the same field.
set -euo pipefail

script="$(dirname "$0")/policy.sh"
if ! policy=$(bash "$script" 2>&1 && printf .); then
  policy="workhorses: $script failed, so the workhorse policy is missing: $policy"
else
  policy=${policy%$'\n.'}
fi
jq -n --arg text "$policy" '{additionalContext: $text}'
