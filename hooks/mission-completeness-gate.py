#!/usr/bin/env python3
"""Stop hook: before ending, enumerate what was deferred and name who each item belongs to.

WHY THIS EXISTS, and it is a measured failure rather than a worry.

In one session on 2026-09-02 the orchestrator stopped short FOUR times, and every excuse was
a TRUE STATEMENT used as a boundary:

    "it's a false positive"          -- it was; the fix was still ours (the caller was wrong)
    "that's a deliberate decision"   -- the operator had already made it, twice
    "separate repo, wants its own PR" -- true, and not a reason to hand it back
    "blocked on context"             -- real, and not one of the delete conditions given

Each was accurate. None was an operator-only blocker. The work was authorised, the path was
clear, and it was handed back anyway with a plausible sentence attached.

⚠️ A TRUE OBSERVATION ABOUT SCOPE IS NOT A SCOPE BOUNDARY. That is the whole rule. A more
capable model produces MORE convincing boundaries, not fewer -- the same asymmetry
`work-autonomously` already records for hard stops, pointed at the opposite failure.

⚠️ AND THE COST IS INVISIBLE. Over-asking produces a visible question. Under-finishing
produces a confident summary with a "still outstanding" list the operator must audit to
discover that half of it was never theirs. Silence looks like completion.

THE TEST THIS HOOK FORCES is deliberately narrow, because a broad one produces paralysis:

    For each thing you did not finish, NAME THE OPERATOR-ONLY THING IT NEEDS.
      a decision they have not made · an irreversible act · a credential only they hold ·
      a merge or permission you are blocked from · their attention on a genuine dead end
    If you cannot name one, it was yours. Do it before you stop.

This hook cannot know what was deferred -- no hook can. It forces the ENUMERATION, which is
the step that was skipped: each item was individually plausible and none was ever listed
beside the others, where the pattern is obvious.

Pure-Python, reads stdin, never raises. A Stop hook that errors would block the turn.
"""
import json
import sys

GATE = """⛔ BEFORE YOU STOP — the completeness gate.

List everything you did NOT finish this mission: deferred, "out of scope", "worth a separate
change", "recommend next", "left for the operator", or silently dropped.

For EACH item, name the OPERATOR-ONLY blocker:
  · a decision they have not made       · an irreversible or outward-facing act
  · a credential or login only they hold · a merge/permission you are blocked from
  · their attention on a genuine dead end, after memory, the code, the internet and the docs

⚠️ IF YOU CANNOT NAME ONE, THE ITEM WAS YOURS. Do it now, before you stop.

⚠️ These are NOT blockers, they are true statements wearing a blocker's clothes:
  "it's a separate repo / its own PR"   "it's a deliberate decision"   "it's pre-existing"
  "it's a false positive"               "that's a bigger change"       "out of scope"
  "context is tight"                    "someone else owns that file"

A true observation about scope is not a scope boundary. If the path is clear and nothing
above is missing, finishing IS the mission.

If every remaining item has a named operator-only blocker: say so plainly, one line each,
and stop. That is a complete report, not an unfinished one."""


def main():
    try:
        json.load(sys.stdin)
    except Exception:
        pass  # a malformed event must not block the turn
    try:
        print(json.dumps({
            "systemMessage": GATE,
            "hookSpecificOutput": {"hookEventName": "Stop", "additionalContext": GATE},
        }))
    except Exception:
        pass


if __name__ == "__main__":
    main()
