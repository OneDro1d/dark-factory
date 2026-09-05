#!/usr/bin/env python3
"""claim-gate — make the ticket claim MECHANICAL, and confine a worker to its own ticket.

WHY. The claim used to be an instruction in the worker's prompt ("FIRST ACTION: set
Claimed By ... claim BEFORE any work"). It was skipped, and nothing noticed — which is the
whole failure class this gate exists to end: a race is closed by the process that owns the
race, not by a sentence asking a model to remember. Here the claim is the ONLY tool call a
fresh worker is permitted to make. Every other call is denied until the claim write lands.

TWO EVENTS, ONE FILE, so the write-side and the marker-side cannot drift apart:

  PreToolUse  (matcher ".*", every tool)
      no marker yet -> DENY everything except the tracker write that claims DF_TICKET
      marker present -> DENY any tracker WRITE whose item id is not DF_TICKET
                        (a worker cannot edit another worker's ticket), else abstain
  PostToolUse (matcher "mcp__.*monday.*change_item_column_values")
      the claim write succeeded -> create <cwd>/.claim-done

ACTIVE ONLY WHEN `DF_TICKET` IS SET. Hooks inherit the launching process's environment
("A hook process inherits the parent environment"), and df-worker exports DF_TICKET,
DF_ROLE and DF_MISSION. So this gate is armed in exactly the sessions df-worker launched,
and is inert — `{}` — in the orchestrator's own session and in any session that is not a
worker. That is not a convenience: an orchestrator denied every tool call until it claimed
a ticket it does not have would be bricked.

FAILS CLOSED while armed. Any internal error with DF_TICKET set is a DENY, never an allow:
a gate that cannot evaluate has not decided anything, and treating that as permission is
how the claim gets skipped again. With DF_TICKET unset the same error is `{}` — refusing to
brick an ordinary session over this file's own bug.

ALWAYS exits 0 and prints exactly one JSON object. A non-zero exit is a hook ERROR, not a
policy decision, and the two must not be confused.

No estate names, hosts, people or machine paths appear here — this is generic Tier-1
method shipped in a public repo. The tracker is matched by TOOL-NAME SHAPE, not by a
hardcoded server name, so a renamed hub does not silently disarm the gate.
"""
import json
import os
import re
import sys

# The tracker write, matched by shape. `mcp__<server>__<...>change_item_column_values` —
# the server segment moves between estates and installs, so it is a wildcard on purpose.
TRACKER_WRITE = re.compile(r"^mcp__.*monday.*change_item_column_values$")

MARKER = ".claim-done"


def emit(obj):
    print(json.dumps(obj))
    sys.exit(0)


def abstain():
    emit({})


def deny(reason):
    emit(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            }
        }
    )


def marker_path(event):
    cwd = event.get("cwd") if isinstance(event, dict) else None
    if not isinstance(cwd, str) or not cwd:
        cwd = os.getcwd()
    return os.path.join(cwd, MARKER)


def item_id_of(tool_input):
    """The item id a tracker write targets, as a string, or None."""
    if not isinstance(tool_input, dict):
        return None
    for key in ("itemId", "item_id", "itemID"):
        if key in tool_input:
            v = tool_input[key]
            if isinstance(v, bool) or v is None:
                return None
            return str(v).strip()
    return None


def response_failed(tool_response):
    """True when the tool result is visibly an error. Anything else counts as success:
    the PostToolUse event only fires after the tool ran, and a claim we cannot prove
    failed must not leave the worker permanently denied."""
    if isinstance(tool_response, dict):
        for key in ("is_error", "isError", "error"):
            if tool_response.get(key):
                return True
        if str(tool_response.get("status", "")).lower() in ("error", "failed"):
            return True
    if isinstance(tool_response, str) and tool_response.strip().lower().startswith("error"):
        return True
    return False


def pre_tool_use(event, ticket):
    tool_name = event.get("tool_name")
    tool_name = tool_name if isinstance(tool_name, str) else ""
    tool_input = event.get("tool_input")
    is_tracker_write = bool(TRACKER_WRITE.match(tool_name))
    item = item_id_of(tool_input) if is_tracker_write else None

    claimed = os.path.isfile(marker_path(event))

    if not claimed:
        if is_tracker_write and item == ticket:
            abstain()
        deny(
            "claim-gate: item %s is not claimed yet. Your FIRST tool call must be the "
            "tracker write that claims it: call the tool matching "
            "`mcp__<hub>__change_item_column_values` with itemId=%s (set Claimed By and "
            "DF Status=Doing). Every other tool call is denied until that write lands."
            % (ticket, ticket)
        )

    if is_tracker_write and item is not None and item != ticket:
        deny(
            "claim-gate: this worker owns item %s and may not write to item %s. One "
            "worker, one ticket — editing another worker's row is how two workers both "
            "believe they hold it." % (ticket, item)
        )

    abstain()


def post_tool_use(event, ticket):
    tool_name = event.get("tool_name")
    tool_name = tool_name if isinstance(tool_name, str) else ""
    if not TRACKER_WRITE.match(tool_name):
        abstain()
    if item_id_of(event.get("tool_input")) != ticket:
        abstain()
    if response_failed(event.get("tool_response")):
        abstain()

    path = marker_path(event)
    try:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("%s\n" % ticket)
    except Exception:
        # Cannot record the claim -> the PreToolUse half keeps denying, which is the safe
        # direction: the worker is stuck asking to claim, not running unclaimed.
        abstain()
    abstain()


def main():
    ticket = os.environ.get("DF_TICKET", "").strip()
    try:
        event = json.loads(sys.stdin.read())
        if not isinstance(event, dict):
            raise ValueError("event is not a JSON object")
    except Exception as e:
        if not ticket:
            abstain()
        deny("claim-gate: internal error (%s) — failing closed" % type(e).__name__)

    if not ticket:
        abstain()

    try:
        if event.get("hook_event_name") == "PostToolUse":
            post_tool_use(event, ticket)
        else:
            pre_tool_use(event, ticket)
    except SystemExit:
        raise
    except Exception as e:
        deny("claim-gate: internal error (%s) — failing closed" % type(e).__name__)


if __name__ == "__main__":
    main()
