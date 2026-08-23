#!/usr/bin/env bash
# df-notify.sh — deliver the 2-trigger notification (VR-5: done | blocked-on-all-fronts).
#
# Bash cannot call an MCP tool, so the outbound post is made by a ONE-SHOT `claude -p`
# with a tightly scoped prompt. That is the only reason a model is involved at all.
#
# The local record in notifications.log is written by the supervisor BEFORE this runs and
# does not depend on it. A notification that exists only when an outbound call succeeds is
# one you cannot rely on — and the whole point of walking away is that you find out.
#
# Usage: df-notify.sh <mission-dir> <state> <iterations>
set -uo pipefail

MISSION_DIR="${1:?mission dir}"
STATE="${2:?state}"
ITERS="${3:-0}"
# The engine ships under boot-kit/scripts/ within whatever kit/repo installs it; two
# levels up from this script's own directory is that kit/repo's own root, used as the
# notepad fallback when NOTEPAD is unset.
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
NOTEPAD="${NOTEPAD:-$(cd "$(dirname "$SELF")/../.." && pwd)}"

CHANNEL="$(cat "$MISSION_DIR/notify-channel" 2>/dev/null || true)"
NAME="$(basename "$MISSION_DIR")"

# Silence is correct for a watch tick that found nothing. Only the two triggers speak.
case "$STATE" in
  DONE|BLOCKED) ;;
  *) echo "df-notify: state=$STATE is not a notify trigger — staying quiet"; exit 0 ;;
esac

if [ -z "$CHANNEL" ]; then
  echo "df-notify: no notify-channel configured for $NAME — local record only." >&2
  echo "df-notify: THE OPERATOR WILL NOT BE TOLD. Set it before walking away." >&2
  exit 3
fi

read -r -d '' PROMPT <<EOF
Post exactly one short Slack message to channel ${CHANNEL}, then stop. Do nothing else:
no investigation, no file reads beyond the two named below, no follow-up messages.

Mission: ${NAME}
Final state: ${STATE}
Iterations run: ${ITERS}

Read ${MISSION_DIR}/state and the newest file in ${NOTEPAD}/handoffs/ for one sentence of
substance. Prefix the message with your agent name and a colon, per whatever
author-disambiguation convention this deployment uses.

If ${STATE} is BLOCKED, the message MUST name the ONE specific thing the operator has to
decide or unblock. A blocked notification without a named ask wastes the interrupt it
just spent.
EOF

exec claude -p "$PROMPT" \
  --permission-mode bypassPermissions \
  --setting-sources project \
  --max-budget-usd 0.50 \
  --output-format text
