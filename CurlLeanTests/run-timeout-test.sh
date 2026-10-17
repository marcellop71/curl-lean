#!/usr/bin/env bash
# Build and run the timeout regression test against a local stalling server.
set -euo pipefail
cd "$(dirname "$0")/.."
PORT="${PORT:-18080}"
lake build timeout-test
python3 CurlLeanTests/stall_server.py "$PORT" > /dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
sleep 0.5
# Without the fix the stall cases hang: cap the whole run.
timeout 60 ./.lake/build/bin/timeout-test "http://127.0.0.1:$PORT"
