#!/bin/sh
# Stop probe -- the GATE's instrument.
#
# Contract (code.claude.com/docs/en/hooks):
#   exit-code-2 table: "Stop -- Prevents Claude from stopping, continues the
#   conversation"
#   JSON fields: {"decision": "block", "reason": "string",
#                 "stop_hook_active": boolean}
#
# This probe uses the JSON path, printing exactly
#   {"decision":"block","reason":"probe: first stop blocked"}
# ONCE. The one-shot latch is the file ${PROBE_OUT}.stopped: if it already
# exists the probe prints nothing and exits 0, so a run that is blocked once
# can still terminate rather than looping forever.
#
# Armed only when PROBE_STOP_BLOCK=1, so the same fixture can be used for the
# non-blocking cells.
if [ "${PROBE_STOP_BLOCK}" != "1" ]; then
  exit 0
fi

out="${PROBE_OUT:-/dev/null}"
marker="${out}.stopped"

if [ -e "$marker" ]; then
  exit 0
fi

: > "$marker" 2>/dev/null
printf '%s\n' '{"decision":"block","reason":"probe: first stop blocked"}'
exit 0
