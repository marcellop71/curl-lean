#!/usr/bin/env bash
# Build and run the WebSocket receive regression test against a local server.
set -euo pipefail
cd "$(dirname "$0")/.."
PORT="${PORT:-18081}"
lake build ws-test
python3 CurlLeanTests/ws_server.py "$PORT" > /dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
sleep 0.5
timeout 60 ./.lake/build/bin/ws-test "ws://127.0.0.1:$PORT/"
