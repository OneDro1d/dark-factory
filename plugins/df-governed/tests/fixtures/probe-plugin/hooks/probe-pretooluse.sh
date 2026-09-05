#!/bin/sh
# PreToolUse probe, matcher Bash.
#
# Contract (code.claude.com/docs/en/hooks): exit 0 with empty stdout is the
# non-blocking path -- "PreToolUse -- Blocks the tool call" applies to EXIT
# CODE 2 only, and the JSON path is "permissionDecision": "allow" | "deny" |
# "request". This probe therefore does neither: it records that it ran and
# gets out of the way, so the Bash tool call still happens.
out="${PROBE_OUT:-/dev/null}"
echo "PROBE-HOOK-FIRED" >> "$out" 2>/dev/null
exit 0
