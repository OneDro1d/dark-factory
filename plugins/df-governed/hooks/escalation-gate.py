#!/usr/bin/env python3
"""PreToolUse hook (matcher: AskUserQuestion|ExitPlanMode) — "answer it yourself first" as a
MECHANISM, not an instruction.

WHY THIS EXISTS. `mission-completeness-gate.py` (a Stop hook, same plugin's sibling under
`~/.claude/hooks/`) already enumerates the operator-only categories and proves, with a dated
example, that a capable model produces PLAUSIBLE, TRUE-SOUNDING reasons to hand work back that
was never the operator's to take. That hook only fires at Stop, after the question was already
asked and answered by a human mid-mission. This hook moves the same discipline to where the
premature question actually happens: the `AskUserQuestion` / `ExitPlanMode` tool call itself.
DESIGN.md (M-KITV2-20260905, D1, Objective 4, Half B) is the source of this mechanism; the
operator-only category list below is copied verbatim from
`~/.claude/hooks/mission-completeness-gate.py:69-76` rather than re-invented, because a second
copy that drifts from the first is worse than no copy.

THE CONTRACT (docs: code.claude.com/docs/en/hooks):
  "PreToolUse" exit-code-2 behaviour: "Blocks the tool call."
  JSON shape: {"hookSpecificOutput": {"hookEventName": "PreToolUse",
               "permissionDecision": "allow"|"deny", "permissionDecisionReason": "..."}}
This hook never uses exit code 2 — it always exits 0 and lets the JSON `permissionDecision`
carry the verdict, so the reason text always reaches the transcript rather than being reduced
to a bare non-zero exit.

WHEN THIS GATE ABSTAINS ({}). Outside a RUNNING mission, the operator's ordinary interactive
sessions are not gated — asking a question in a normal working session is exactly what the tool
is for. The gate only arms once a mission is actually running, which is also the only condition
under which "answer it yourself first" is even meaningful (there is a map, a frontier, a
notepad to write the escalation into).

  - no notepad found by walking up from cwd for NOTES.md               -> {}
  - a notepad found, but no `.df/missions/<id>/state` reads RUNNING    -> {}
  - a RUNNING mission, and a fresh, on-topic escalation file exists    -> {}
  - a RUNNING mission, and no such file exists                        -> deny

THE ESCALATION FILE IS THE MECHANISM, NOT THE PROSE ASKING FOR ONE. A file under
`.df/missions/<id>/escalations/` that is both RECENT (mtime within `DF_ESCALATION_TTL` seconds,
default 1800 — a stale file from three days ago proves nothing about THIS question) and
ON-TOPIC (names one of the enumerated categories — an escalation file that never says why is a
free pass through the gate written once and reused forever) is treated as "the agent tried to
answer this itself, on the most capable model available, and is recording why it could not."
Writing that file, with that content, freshly, IS the act of answering-first; a hook cannot
verify the THINKING behind it, only that the record exists, is current, and is on-topic — which
is the same class of proxy `mission-completeness-gate.py` accepts (it cannot verify the
enumeration is complete, only that one was attempted).

FAILS CLOSED. Any internal error — malformed stdin, an unreadable escalations directory, an
unexpected exception — denies rather than allows. A hook that fails open on its own bug is a
gate with a bug-shaped hole in it.
"""
import json
import os
import re
import sys
import time

# Verbatim from ~/.claude/hooks/mission-completeness-gate.py:69-76 — one list, one home. A
# second copy of the operator-only category text that could drift from the original is exactly
# the aliasing failure this notepad's CLAUDE.md names four separate times ("a stale, present-
# looking record stops the next reader from checking").
CATEGORIES = [
    ("decision",     "a decision they have not made"),
    ("irreversible", "an irreversible or outward-facing act"),
    ("credential",   "a credential or login only they hold"),
    ("merge",        "a merge or permission you are blocked from"),
    ("permission",   "a merge or permission you are blocked from"),
    ("dead end",     "their attention on a genuine dead end"),
    ("attention",    "their attention on a genuine dead end"),
]

DEFAULT_TTL_SECONDS = 1800

ANSWER_FIRST = (
    "Answer it yourself first (Skill: critical-thinking). If you still cannot, write the "
    "escalation file naming the category, then ask."
)


def allow():
    print("{}")
    return 0


def deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
    return 0


def find_notepad(start_dir):
    """Walk up from start_dir for the first directory carrying NOTES.md — the notepad root
    marker (CLAUDE.md: 'Root marker: NOTES.md (the dir name is not parsed).')."""
    d = os.path.abspath(start_dir)
    while True:
        if os.path.isfile(os.path.join(d, "NOTES.md")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def running_missions(notepad):
    """Every mission id under <notepad>/.df/missions/ whose state file's FIRST LINE, stripped,
    reads exactly RUNNING. Missing/unreadable state files are silently skipped — not RUNNING is
    the safe default for a file we cannot read, same as a missing one."""
    missions_dir = os.path.join(notepad, ".df", "missions")
    if not os.path.isdir(missions_dir):
        return []
    out = []
    for entry in sorted(os.listdir(missions_dir)):
        state_path = os.path.join(missions_dir, entry, "state")
        if not os.path.isfile(state_path):
            continue
        try:
            with open(state_path, "r") as f:
                first_line = f.readline().strip()
        except Exception:
            continue
        if first_line == "RUNNING":
            out.append(entry)
    return out


def category_hit(text):
    lowered = text.lower()
    for keyword, _label in CATEGORIES:
        if keyword in lowered:
            return keyword
    return None


def fresh_escalation(notepad, mission_id, ttl_seconds):
    """True (with the matching keyword) if escalations/*.md holds a file that is BOTH within
    ttl_seconds of now AND names one of CATEGORIES — both conditions on the SAME file, because a
    stale on-topic file or a fresh off-topic one proves nothing about THIS question."""
    esc_dir = os.path.join(notepad, ".df", "missions", mission_id, "escalations")
    if not os.path.isdir(esc_dir):
        return None
    now = time.time()
    for name in sorted(os.listdir(esc_dir)):
        if not name.endswith(".md"):
            continue
        path = os.path.join(esc_dir, name)
        try:
            mtime = os.path.getmtime(path)
        except Exception:
            continue
        if (now - mtime) > ttl_seconds:
            continue
        try:
            with open(path, "r") as f:
                content = f.read()
        except Exception:
            continue
        hit = category_hit(content)
        if hit:
            return (name, hit)
    return None


def deny_reason(notepad, mission_id):
    # De-duplicate labels (merge/permission and dead end/attention each share one label) while
    # keeping first-seen order, so the reason names each of the five categories exactly once.
    labels = list(dict.fromkeys(label for _kw, label in CATEGORIES))
    cats = "  ·  ".join(labels)
    example_path = os.path.join(
        notepad, ".df", "missions", mission_id, "escalations", "<name>.md"
    )
    return (
        "escalation-gate: no fresh, on-topic escalation on file for mission '{mid}'. "
        "Allowed categories: {cats}. Write one to {path} naming the category. {answer_first}"
    ).format(mid=mission_id, cats=cats, path=example_path, answer_first=ANSWER_FIRST)


def main():
    try:
        raw = sys.stdin.read()
        event = json.loads(raw) if raw.strip() else {}
        if not isinstance(event, dict):
            raise ValueError("top-level event is not a JSON object")
    except Exception as e:
        return deny("escalation-gate: internal error {}".format(type(e).__name__))

    try:
        cwd = event.get("cwd") or os.getcwd()

        notepad = find_notepad(cwd)
        if not notepad:
            return allow()

        missions = running_missions(notepad)
        if not missions:
            return allow()

        ttl = DEFAULT_TTL_SECONDS
        try:
            ttl = int(os.environ.get("DF_ESCALATION_TTL", DEFAULT_TTL_SECONDS))
        except Exception:
            ttl = DEFAULT_TTL_SECONDS

        for mid in missions:
            if fresh_escalation(notepad, mid, ttl):
                return allow()

        return deny(deny_reason(notepad, missions[0]))
    except Exception as e:
        return deny("escalation-gate: internal error {}".format(type(e).__name__))


if __name__ == "__main__":
    sys.exit(main() or 0)
