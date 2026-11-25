#!/bin/bash
# ABOUTME: Captures the wh badge and band in Claude Code during a real run, in both themes, and builds assets/claude-band.svg.
# ABOUTME: Usage: WH_CAPTURE_SSH_TARGET=<ssh target> bash assets/capture/claude-band.sh
set -euo pipefail
python3 -B "$(dirname "$0")/capture.py" claude-band
