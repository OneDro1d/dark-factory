#!/bin/bash
# Start Playwright MCP as a standalone SSE server.
# This decouples the browser lifecycle from the Claude Code session,
# preventing tool connection drops. The browser stays running even if
# Claude Code restarts.
#
# Usage:
#   boot-kit/scripts/start-playwright-sse.sh           # headless (default)
#   boot-kit/scripts/start-playwright-sse.sh --headed   # visible browser
#
# Then in Claude Code, the "playwright-sse" MCP server connects to this.
# To stop: Ctrl+C or kill the process.

PORT="${PLAYWRIGHT_SSE_PORT:-3001}"
MODE="${1:---headless}"

echo "Starting Playwright MCP SSE server on port $PORT ($MODE)..."
echo "Connect Claude Code via: {\"type\":\"sse\",\"url\":\"http://localhost:$PORT/sse\"}"
echo ""

exec npx @playwright/mcp@0.0.41 --port "$PORT" "$MODE"
