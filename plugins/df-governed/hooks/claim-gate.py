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
      the claim write succeeded -> create <marker dir>/.claim-done

MARKER LOCATION: `$DF_SCRATCH/.claim-done` when DF_SCRATCH is set, else the hook event's
own `cwd` (the pre-existing behaviour). WHY THIS CHANGED (measured, first live dispatch,
2026-09-05): the marker used to be keyed on the hook stdin's `cwd`, but a worker's cwd is
not fixed for the life of the session — it moves when the worker `cd`s into the target
repo it was told to edit. A write claimed from the scratch dir left a marker there; the
very next tool call arrived with `cwd` pointing at the repo, found no marker at THAT path,
and the worker was denied as still-unclaimed after it had already claimed. df-worker now
exports DF_SCRATCH (the one directory that does not move for the worker's whole life) into
the child env, and this gate prefers it. Backward compatible: DF_SCRATCH unset (a session
this gate ran in before this fix, or any session df-worker did not launch) falls straight
back to the old cwd-keyed path — nothing that already worked stops working.

CLAIM CONTENT, NOT JUST CLAIM SHAPE (measured same dispatch): unarmed by DF_CLAIM_COLUMNS,
ANY write to DF_TICKET was accepted as "the claim" — a worker wrote an email address into
one text column and never touched DF Status, and the gate could not tell that apart from a
real claim. When DF_worker passes `--claim-columns <json>` it exports DF_CLAIM_COLUMNS, a
JSON object of `{columnId: expectedValue}` (a value may be a plain string, e.g. an email
address, or an object like `{"label": "Doing"}` for a status column). With DF_CLAIM_COLUMNS
set, a PreToolUse write to DF_TICKET only abstains (is treated as the claim) when its
`columnValues` — itself a JSON string OR an already-decoded object, both handled — contains
every required key at its exact expected value; anything else is DENIED, and the denial
prints the exact expected columnValues JSON so the worker can copy it verbatim rather than
guess again. PostToolUse mirrors this: the marker is written only for a write that matched.
DF_CLAIM_COLUMNS unset -> unchanged: any write to DF_TICKET is the claim, exactly as before.

ACTIVE ONLY WHEN `DF_TICKET` IS SET. Hooks inherit the launching process's environment
("A hook process inherits the parent environment"), and df-worker exports DF_TICKET,
DF_ROLE and DF_MISSION. So this gate is armed in exactly the sessions df-worker launched,
and is inert — `{}` — in the orchestrator's own session and in any session that is not a
worker. That is not a convenience: an orchestrator denied every tool call until it claimed
a ticket it does not have would be bricked.

TOOL_INPUT FOR MCP TOOLS, QUOTED (code.claude.com/docs/en/hooks) before this file assumed
its shape: "MCP tools follow the naming pattern `mcp__<server>__<tool>`" and the hook's
`tool_input` field is the literal arguments object passed to that tool call — i.e. for the
tracker's `change_item_column_values`, `tool_input["columnValues"]` is exactly what the
model passed for that argument. The monday-pww tool schema types `columnValues` as a JSON
string, so that is the case this file optimizes for; parsing also accepts an already-decoded
object in case a hub ever passes one, since the docs describe the field as "the arguments
passed to the tool", not a wire format.

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
    # DF_SCRATCH, when set, is the worker's one fixed directory for its whole life; the
    # hook event's own `cwd` moves when the worker `cd`s into the repo it was told to edit.
    # Falling back to `cwd` keeps every session that predates DF_SCRATCH working unchanged.
    scratch = os.environ.get("DF_SCRATCH", "").strip()
    if scratch:
        return os.path.join(scratch, MARKER)
    cwd = event.get("cwd") if isinstance(event, dict) else None
    if not isinstance(cwd, str) or not cwd:
        cwd = os.getcwd()
    return os.path.join(cwd, MARKER)


def load_claim_columns():
    """DF_CLAIM_COLUMNS, parsed, or None when unset (old behaviour: any write is the claim).
    Invalid JSON while armed is left to raise — the caller's fail-closed handling in main()
    turns that into a DENY, never a silent fall-back to "any write counts"."""
    raw = os.environ.get("DF_CLAIM_COLUMNS", "").strip()
    if not raw:
        return None
    obj = json.loads(raw)
    if not isinstance(obj, dict):
        raise ValueError("DF_CLAIM_COLUMNS is not a JSON object")
    return obj


def parsed_column_values(tool_input):
    """tool_input['columnValues'] as a dict, whether the caller passed a JSON string (the
    monday-pww tool's documented shape) or an already-decoded object."""
    if not isinstance(tool_input, dict):
        return None
    cv = tool_input.get("columnValues")
    if isinstance(cv, dict):
        return cv
    if isinstance(cv, str):
        try:
            obj = json.loads(cv)
        except Exception:
            return None
        return obj if isinstance(obj, dict) else None
    return None


def value_matches(expected, actual):
    """A plain string must match exactly (e.g. an email address). An object (e.g. a status
    column's {"label": ...}) matches when every one of ITS keys matches — so the caller only
    has to state the keys it cares about, not the column's full internal shape."""
    if isinstance(expected, dict):
        return isinstance(actual, dict) and all(
            actual.get(k) == v for k, v in expected.items()
        )
    return actual == expected


def claim_matches(tool_input, claim_columns):
    values = parsed_column_values(tool_input)
    if not isinstance(values, dict):
        return False
    return all(
        col in values and value_matches(expected, values[col])
        for col, expected in claim_columns.items()
    )


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

    claim_columns = load_claim_columns()
    claimed = os.path.isfile(marker_path(event))

    if not claimed:
        if is_tracker_write and item == ticket:
            if claim_columns is None or claim_matches(tool_input, claim_columns):
                abstain()
            deny(
                "claim-gate: this write to item %s does not carry the claim. "
                "DF_CLAIM_COLUMNS requires columnValues to match exactly: %s"
                % (ticket, json.dumps(claim_columns, sort_keys=True))
            )
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
    tool_input = event.get("tool_input")
    if not TRACKER_WRITE.match(tool_name):
        abstain()
    if item_id_of(tool_input) != ticket:
        abstain()
    if response_failed(event.get("tool_response")):
        abstain()

    claim_columns = load_claim_columns()
    if claim_columns is not None and not claim_matches(tool_input, claim_columns):
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
