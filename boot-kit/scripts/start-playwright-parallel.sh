#!/bin/bash
# Start multiple isolated Playwright MCP SSE servers for parallel testing.
# Each server gets its own browser instance with separate user data.
#
# Usage:
#   boot-kit/scripts/start-playwright-parallel.sh 3       # start 3 sessions
#   boot-kit/scripts/start-playwright-parallel.sh 3 --headed  # visible browsers
#
# Sessions use ports 3001, 3002, 3003, etc.
# Each gets its own user-data-dir for complete cookie/storage isolation.
#
# To connect from Claude Code:
#   Session 1: {"type":"sse","url":"http://localhost:3001/sse"}
#   Session 2: {"type":"sse","url":"http://localhost:3002/sse"}
#   etc.
#
# To stop all: Ctrl+C (sends SIGINT to all child processes)

COUNT="${1:-2}"
MODE="${2:---headless}"
BASE_PORT=3001
DATA_DIR="$HOME/.cache/playwright-parallel"

mkdir -p "$DATA_DIR"

PIDS=()

cleanup() {
    echo ""
    echo "Stopping all Playwright sessions..."
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null
    done
    wait
    echo "All sessions stopped."
}
trap cleanup INT TERM

echo "Starting $COUNT parallel Playwright MCP sessions ($MODE)..."
echo ""

for i in $(seq 1 "$COUNT"); do
    PORT=$((BASE_PORT + i - 1))
    USER_DIR="$DATA_DIR/session-$i"
    mkdir -p "$USER_DIR"

    echo "  Session $i: port $PORT, data: $USER_DIR"
    npx @playwright/mcp@0.0.41 --port "$PORT" "$MODE" --user-data-dir "$USER_DIR" &
    PIDS+=($!)
done

echo ""
echo "All sessions running. Press Ctrl+C to stop all."
echo ""
echo "Claude Code MCP config for parallel sessions:"
for i in $(seq 1 "$COUNT"); do
    PORT=$((BASE_PORT + i - 1))
    echo "  playwright-session-$i: {\"type\":\"sse\",\"url\":\"http://localhost:$PORT/sse\"}"
done

wait
