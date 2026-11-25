#!/bin/bash
# ABOUTME: Captures wh running a demo repository's tests on a real workhorse, twice, and builds assets/wh-run.svg.
# ABOUTME: Usage: WH_CAPTURE_SSH_TARGET=<ssh target> bash assets/capture/wh-run.sh
set -euo pipefail
python3 "$(dirname "$0")/capture.py" wh-run
