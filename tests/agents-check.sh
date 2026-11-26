#!/bin/bash
# ABOUTME: Checks that Claude Code, Codex, pi and OpenCode each put the workhorse policy into the request they send a
# ABOUTME: model, against a local server that records it. Usage: tests/agents-check.sh; skips an agent not installed.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
work=$(mktemp -d)
server=""
cleanup() {
  local status=$? recorder_status=0
  if [ -n "$server" ]; then
    kill "$server" 2>/dev/null || true
    wait "$server" || recorder_status=$?
    if [ "$recorder_status" -ne 0 ] && [ "$recorder_status" -ne 143 ]; then
      echo "recorder exited $recorder_status" >&2
      [ "$status" -ne 0 ] || status=$recorder_status
    fi
  fi
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT

# A scratch config whose notes end in a token unique to this run, so only the policy can carry it into a request.
token=wh-check-$RANDOM$RANDOM
export WORKHORSES_CONFIG_DIR=$work/config
mkdir -p "$WORKHORSES_CONFIG_DIR" "$work/requests"
cp "$root/examples/hosts" "$WORKHORSES_CONFIG_DIR/hosts"
printf -- '- The check token is %s.\n' "$token" >"$WORKHORSES_CONFIG_DIR/notes"

# Records every request body and answers 400, so each agent stops after its first request and no model is called.
python3 -I -c '
import http.server, os, sys
out = sys.argv[1]
class Recorder(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length") or 0))
        with open(os.path.join(out, str(len(os.listdir(out)))), "wb") as f:
            f.write(body)
        self.send_response(400)
        self.send_header("content-type", "application/json")
        self.end_headers()
        self.wfile.write(b"{\"error\":{\"message\":\"recorded\"}}")
    def log_message(self, format, *args):
        pass
recorder = http.server.HTTPServer(("127.0.0.1", 0), Recorder)
open(sys.argv[2], "w").write(str(recorder.server_port))
recorder.serve_forever()
' "$work/requests" "$work/port" &
server=$!
for _ in $(seq 50); do [ -s "$work/port" ] && break; sleep 0.1; done
url=http://127.0.0.1:$(cat "$work/port")

# The start of the skill's description, which each agent lists among its skills.
skill="spare Macs and Linux machines in the workhorses hosts file"
ran=0

# Runs one agent until a request it sent holds the token, or it exits, or 3 minutes pass; passes on the token.
expect_policy() {
  local agent=$1 pid waited
  shift
  if ! command -v "$agent" >/dev/null; then
    echo "skip: $agent is not installed"
    return 0
  fi
  rm -f "$work"/requests/*
  (cd "$work" && exec "$@") >"$work/$agent.log" 2>&1 &
  pid=$!
  waited=0
  while kill -0 "$pid" 2>/dev/null && ! grep -qs -- "$token" "$work"/requests/* && [ "$waited" -lt 1800 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  if ! grep -qs -- "$token" "$work"/requests/*; then
    echo "FAIL $agent sent no request with the policy; its output:" >&2
    tail -20 "$work/$agent.log" >&2
    exit 1
  fi
  if ! grep -qs -- "$skill" "$work"/requests/*; then
    echo "FAIL $agent sent the policy but not the workhorse skill" >&2
    exit 1
  fi
  ran=$((ran + 1))
  echo "ok   $agent sends the policy and the skill"
}

expect_policy claude env CLAUDE_CONFIG_DIR="$work/claude" ANTHROPIC_BASE_URL="$url" ANTHROPIC_API_KEY=recorded \
  claude -p --permission-mode default --plugin-dir "$root" hello

# Codex installs the plugin from a marketplace, here one in the scratch folder. Its hook runs only once trusted,
# which this throwaway CODEX_HOME grants for the one run.
mkdir -p "$work/market/.claude-plugin" "$work/market/plugins" "$work/codex"
ln -s "$root" "$work/market/plugins/workhorses"
printf '%s\n' '{"name": "wh-check", "owner": {"name": "wh-check"}, "plugins": [{"name": "workhorses", "source": "./plugins/workhorses"}]}' \
  >"$work/market/.claude-plugin/marketplace.json"
if command -v codex >/dev/null; then
  CODEX_HOME=$work/codex codex plugin marketplace add "$work/market" >/dev/null
  CODEX_HOME=$work/codex codex plugin add workhorses@wh-check >/dev/null
fi
expect_policy codex env CODEX_HOME="$work/codex" RECORDED_KEY=recorded codex exec --skip-git-repo-check \
  --dangerously-bypass-hook-trust -c model_provider=recorder -c 'model_providers.recorder.name="recorder"' \
  -c "model_providers.recorder.base_url=\"$url/v1\"" -c 'model_providers.recorder.env_key="RECORDED_KEY"' \
  -c 'model_providers.recorder.wire_api="responses"' -m m hello

mkdir -p "$work/pi"
printf '{"providers": {"recorder": {"baseUrl": "%s/v1", "api": "openai-completions", "apiKey": "recorded", "models": [{"id": "m", "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}}]}}}\n' \
  "$url" >"$work/pi/models.json"
expect_policy pi env PI_CODING_AGENT_DIR="$work/pi" pi -p --offline --no-session -ne -e "$root" \
  --provider recorder --model m hello

mkdir -p "$work/opencode/config/opencode"
printf '{"plugins": ["%s"], "model": "recorder/m", "provider": {"recorder": {"npm": "@ai-sdk/openai-compatible", "options": {"baseURL": "%s/v1", "apiKey": "recorded"}, "models": {"m": {}}}}}\n' \
  "$root" "$url" >"$work/opencode/config/opencode/opencode.json"
expect_policy opencode env XDG_CONFIG_HOME="$work/opencode/config" XDG_DATA_HOME="$work/opencode/data" \
  XDG_STATE_HOME="$work/opencode/state" XDG_CACHE_HOME="$work/opencode/cache" opencode run --standalone hello

[ "$ran" -gt 0 ] || { echo "FAIL none of Claude Code, Codex, pi and OpenCode is installed, so nothing was checked" >&2; exit 1; }
echo "all $ran installed agents send the policy and the skill"
