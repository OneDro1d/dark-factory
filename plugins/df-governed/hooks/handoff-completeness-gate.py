#!/usr/bin/env python3
"""Stop hook: while a mission is RUNNING, refuse to end the turn until this notepad's
handoff for that mission is real — not just present.

WHY. `mission-completeness-gate.py` proved the shape and also proved the two traps around
it: emitting a decision from `Stop` on every turn loops (that hook shipped blocking 9
consecutive times before the harness force-ended it), and a headless worker has nobody to
read a "please write a handoff" message. This hook PROMOTES that proven shape from advice
(`additionalContext`) to a decision (`decision: "block"`). Per code.claude.com/docs/en/hooks:
Stop's `decision: "block"` "Prevents Claude from stopping, continues the conversation";
`reason` is "Required when decision is block. Tells Claude why it should continue";
`stop_hook_active` is "true when Claude Code is already continuing as a result of a stop
hook" — the harness itself caps at 8 consecutive blocks, but this hook must not rely on that.

Both loop guards are copied from `mission-completeness-gate.py`, not reinvented:
stop_hook_active -> release immediately, and CLAUDE_CODE_ENTRYPOINT == "sdk-cli" -> release
immediately (headless workers do not author handoffs; the supervisor does, between turns).

Fails OPEN on any internal error: a Stop gate that crashes closed traps the session.
Pure-Python stdlib, reads stdin once, never raises past main().

OWNER-AWARE. A RUNNING mission with a `.df/missions/<id>/owner` file only demands a handoff
from the session named in it (measured: this event's own `session_id` field, present on every
Stop payload — no env var needed here, unlike the payload-less mission-tick.sh monitor). A
non-owner session gets `{}` plus, once per session, a systemMessage naming the owner. No owner
file at all is unowned, and unowned behaves exactly as before this file changed.
"""
import glob
import json
import os
import re
import sys

PLACEHOLDERS = ("TODO", "TBD", "FIXME", "<fill")
CHECKS = (
    ("next action", re.compile(r"next action", re.IGNORECASE)),
    ("blocked", re.compile(r"blocked", re.IGNORECASE)),
    ("evidence/artefacts/artifacts", re.compile(r"evidence|artefacts|artifacts", re.IGNORECASE)),
)
HEADING_RE = re.compile(r"^(#{1,6})[ \t]+(.*)$", re.MULTILINE)


def emit(obj):
    print(json.dumps(obj))


def resolve_notepad(cwd):
    """Walk up from cwd for the nearest NOTES.md — same resolution as the notepad's own
    SessionStart hook, so this gate and the delivery mechanism never disagree on scope."""
    if not cwd:
        return None
    p = os.path.abspath(cwd)
    while True:
        if os.path.isfile(os.path.join(p, "NOTES.md")):
            return p
        parent = os.path.dirname(p)
        if parent == p:
            return None
        p = parent


def read_owner(notepad, mission_id):
    """The owning session id from .df/missions/<id>/owner, or None. No file, or an empty
    file, means unowned — today's behaviour applies unchanged."""
    path = os.path.join(notepad, ".df", "missions", mission_id, "owner")
    if not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8", errors="replace") as f:
        owner = f.readline().strip()
    return owner or None


def notify_non_owner_once(notepad, mission_id, owner, reader_session_id):
    """Once per (mission, reading session) pair, return the one-line systemMessage naming the
    owner; every later Stop from the same non-owner session returns None. The marker lives
    beside the mission's own owner/state files, so a fresh notepad (as every test uses) starts
    with a clean slate and two different non-owner sessions each get their own notice."""
    safe = re.sub(r"[^A-Za-z0-9_.-]", "_", reader_session_id or "unknown")
    marker = os.path.join(notepad, ".df", "missions", mission_id, ".owner-notified.%s" % safe)
    if os.path.isfile(marker):
        return None
    try:
        with open(marker, "w", encoding="utf-8") as f:
            f.write("")
    except OSError:
        pass
    return "mission %s: owned by %s, not this session." % (mission_id, owner)


def running_missions(notepad):
    missions_dir = os.path.join(notepad, ".df", "missions")
    out = []
    if not os.path.isdir(missions_dir):
        return out
    for name in sorted(os.listdir(missions_dir)):
        state_path = os.path.join(missions_dir, name, "state")
        if not os.path.isfile(state_path):
            continue
        with open(state_path, encoding="utf-8", errors="replace") as f:
            if f.readline().strip() == "RUNNING":
                out.append(name)
    return out


def newest_handoff(notepad, mission_id):
    """The handoff for a running mission is the newest handoffs/*.md that mentions its id."""
    hits = []
    for path in glob.glob(os.path.join(notepad, "handoffs", "*.md")):
        with open(path, encoding="utf-8", errors="replace") as f:
            content = f.read()
        if mission_id in content:
            hits.append((os.path.getmtime(path), path, content))
    if not hits:
        return None, None
    hits.sort(key=lambda t: t[0])
    _, path, content = hits[-1]
    return path, content


def failed_check(path, content, map_mtime):
    """Returns the first failed check's description, or None if the handoff is complete."""
    sections = []
    matches = list(HEADING_RE.finditer(content))
    for i, m in enumerate(matches):
        start = m.end()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(content)
        sections.append((m.group(2), content[start:end]))
    for label, pattern in CHECKS:
        bodies = [body for heading, body in sections if pattern.search(heading)]
        if not bodies:
            return "no heading matching /%s/" % label
        blob = "\n".join(bodies)
        for tok in PLACEHOLDERS:
            if tok in blob:
                return "placeholder %r under the /%s/ heading" % (tok, label)
    if map_mtime is not None and os.path.getmtime(path) < map_mtime:
        return "handoff is older than MAP.md — the map moved and the handoff did not"
    return None


def main():
    event = json.load(sys.stdin) or {}

    if os.environ.get("CLAUDE_CODE_ENTRYPOINT") == "sdk-cli":
        return emit({})
    if event.get("stop_hook_active"):
        return emit({})
    if os.environ.get("DF_HANDOFF_GATE") == "off":
        return emit({"systemMessage": "handoff-completeness-gate: DF_HANDOFF_GATE=off — gate disabled"})

    notepad = resolve_notepad(event.get("cwd"))
    if not notepad:
        return emit({})

    missions = running_missions(notepad)
    if not missions:
        return emit({})

    map_path = os.path.join(notepad, "MAP.md")
    map_mtime = os.path.getmtime(map_path) if os.path.isfile(map_path) else None

    session_id = str(event.get("session_id") or "")

    # A notice about a mission owned elsewhere must not pre-empt the check on a mission this
    # session DOES own: collect notices, keep walking, and only emit them if nothing blocks.
    notices = []
    for mission_id in missions:
        owner = read_owner(notepad, mission_id)
        if owner and owner != session_id:
            msg = notify_non_owner_once(notepad, mission_id, owner, session_id)
            if msg:
                notices.append(msg)
            continue

        path, content = newest_handoff(notepad, mission_id)
        if path is None:
            reason = "mission %s: handoff none — no handoffs/*.md mentions this mission id." % mission_id
        else:
            check = failed_check(path, content, map_mtime)
            if check is None:
                continue
            reason = "mission %s: handoff %s — %s." % (mission_id, path, check)
        reason += " Write or refresh the handoff (Skill: handoff), then stop again."
        return emit({"decision": "block", "reason": reason})

    if notices:
        return emit({"systemMessage": " ".join(notices)})
    return emit({})


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        try:
            emit({"systemMessage": "handoff-completeness-gate: internal error %s — not blocking" % type(e).__name__})
        except Exception:
            pass
