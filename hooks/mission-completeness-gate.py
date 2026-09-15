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

⚠️ IT GOES QUIET AFTER THE FIRST FIRING IN A SESSION, and that is a correctness property
rather than a politeness. Measured on the day it shipped: five consecutive firings, the last
three re-deriving an identical settled list. A gate that repeats a full screen of rules over
an unchanged answer is the seven-no-change-tick failure arriving through a Stop hook instead
of a cron — and an operator who skims the fifth learns to skim the first.

So the FULL text fires once per session; later firings carry a two-line reminder that still
demands a re-run if the list changed. The guard survives; the wall of text does not.

⚠️ The marker is keyed by session_id under a temp dir, so it dies with the machine's temp
state and a genuinely new session always gets the full gate. A missing or unwritable marker
falls back to the FULL text: if the hook cannot tell whether it has fired, the safe answer is
to prompt, not to stay silent.

⛔ It RELEASES THE TURN when `stop_hook_active` is true -- i.e. when it is firing because a
previous Stop hook blocked. Emitting anything from a Stop hook means 'not finished yet',
so without that check the hook re-triggers itself until the harness force-ends the turn
after 9 consecutive blocks. Measured on this hook, the day it shipped.

Pure-Python, reads stdin, never raises. A Stop hook that errors would block the turn.
"""
import json
import os
import re
import sys
import tempfile

GATE = """⛔ BEFORE YOU STOP — the completeness gate.

List everything you did NOT finish this mission: deferred, "out of scope", "worth a separate
change", "recommend next", "left for the operator", or silently dropped.

For EACH item, name the OPERATOR-ONLY blocker:
  · a decision they have not made       · an irreversible or outward-facing act
  · a credential or login only they hold · a merge/permission you are blocked from
  · their attention on a genuine dead end, after memory, the code, the internet and the docs

⚠️ IF YOU CANNOT NAME ONE, THE ITEM WAS YOURS. Do it now, before you stop.

⛔ NOW CHALLENGE WHAT YOU CALLED DONE — the list above only covers what you KNOW you left.
For each thing you are reporting as finished, name the test THE OPERATOR could run.
  "merged" · "pushed" · "shipped" · "it's in Tier 1" · "the PR is green" are NOT done-tests.
  They say where the code is, not that anybody can use it. If nobody can reach it, it is
  not done — it is staged. Shipping a skill nobody installs is the shape to watch for.
  ⛔ DONE IS PROVEN-BY-EVIDENCE, NEVER DECLARED. Your own "it works" is a self-report, and a
  self-report is not an assessment — the same bar you hold a sub-agent's return to.

⛔ AND IF YOU ARE HANDING BACK A DECISION: did you SEARCH for one already made? Memory, this
page's own git history, the notepad, the mission record. Re-asking an answered question
spends the operator's attention twice and teaches them the queue is noise.

⚠️ These are NOT blockers, they are true statements wearing a blocker's clothes:
  "it's a separate repo / its own PR"   "it's a deliberate decision"   "it's pre-existing"
  "it's a false positive"               "that's a bigger change"       "out of scope"
  "context is tight"                    "someone else owns that file"

A true observation about scope is not a scope boundary. If the path is clear and nothing
above is missing, finishing IS the mission.

If every remaining item has a named operator-only blocker: say so plainly, one line each,
and stop. That is a complete report, not an unfinished one."""


BRIEF = """⛔ Completeness gate (already run this session). If anything is still
deferred, name its OPERATOR-ONLY blocker — a decision, an irreversible act, a credential, a
merge you are blocked from, a real dead end. Anything without one is yours: do it now.
Anything you are calling DONE: name the test the operator could run — "merged" is not one.
If the list is unchanged and every item has a named blocker, say so in one line and stop."""


def open_item_count(start=None):
    """Count open items on the nearest operator-todo.md, walking up from cwd.

    The two prose tests above are questions the model answers about itself. This one is a
    MEASUREMENT, and it exists because the failure it catches is invisible to self-report:
    a session that ends with MORE open items than it started, and none closed, has diverged
    into surveying instead of converging on done. Each new item is individually defensible;
    the pattern is only visible as a count.

    Returns None when there is no such file — a session outside a notepad, a worker, a
    scratch dir. Absent is not zero, and a wrong number here would be worse than no number.
    Never raises: this is an enhancement to a Stop hook, and a Stop hook that errors blocks
    the turn.
    """
    try:
        d = os.path.abspath(start or os.getcwd())
        for _ in range(12):                      # bounded: never walk to / on a deep path
            p = os.path.join(d, "operator-todo.md")
            if os.path.isfile(p):
                with open(p, encoding="utf-8", errors="replace") as f:
                    # Only unchecked items. A checked one is done and awaiting deletion;
                    # counting it would make closing an item look like no progress.
                    return sum(1 for ln in f if ln.lstrip().startswith("- [ ]"))
            parent = os.path.dirname(d)
            if parent == d:
                break
            d = parent
    except Exception:
        pass
    return None


def already_fired(session_id):
    """True if the full gate has fired for this session. Falls back to False on any error:
    if we cannot tell, prompt — a missed reminder is worse than a repeated one."""
    if not session_id:
        return False
    try:
        d = os.path.join(tempfile.gettempdir(), "claude-completeness-gate")
        os.makedirs(d, exist_ok=True)
        marker = os.path.join(d, re.sub(r"[^A-Za-z0-9_.-]", "_", session_id))
        if os.path.exists(marker):
            return True
        with open(marker, "w") as f:
            f.write("1")
        return False
    except Exception:
        return False


def main():
    sid = ""
    stop_hook_active = False
    try:
        event = json.load(sys.stdin) or {}
        sid = event.get("session_id") or ""
        stop_hook_active = bool(event.get("stop_hook_active"))
    except Exception:
        pass  # a malformed event must not block the turn

    # ⛔ RELEASE THE TURN ON RE-ENTRY. Emitting anything from a Stop hook tells the harness the
    # turn is not finished, so it runs the model again -- which fires this hook again. Without
    # this check that is an unbounded loop, and Claude Code force-ends it after 9 consecutive
    # blocks with "A hook blocked the turn from ending 9 consecutive times".
    #
    # ⚠️ MEASURED THE DAY THIS HOOK SHIPPED. It happened, to this hook, and the earlier
    # "go quiet after the first firing" change did NOT fix it -- that made the message SHORTER
    # while it still BLOCKED. Verbosity was the symptom; never releasing the turn was the
    # cause. A brief block is still a block, and fixing the visible half of a defect is how
    # the real half survives a fix that looks like it worked.
    #
    # `stop_hook_active` is true exactly when this hook is firing BECAUSE a previous Stop hook
    # blocked. The contract is: return success, emit nothing, let the turn end.
    # ⛔ HEADLESS RUNS: RELEASE. A Stop hook that emits anything means "not finished", so the
    # model takes another turn and THAT turn's text becomes the run's `result`. Interactively
    # that is the whole point — a human reads the prompt and acts on it. In `claude -p` there is
    # nobody to read it, and the only effect is that the worker's ANSWER is replaced by prose
    # about completeness. Promise-Theory dispatch reads that field as evidence.
    #
    # MEASURED 2026-09-04 (ESO kit-validation run):
    #   claude -p 'Reply with exactly this and nothing else: MARKER-9F3A-OK'
    #     -> result = "Nothing outstanding. The turn was a single instruction…"
    #   ...the same prompt with --setting-sources project (user hooks not loaded)
    #     -> result = "MARKER-9F3A-OK"
    #
    # ⚠️ THE DISCRIMINATOR IS MEASURED, NOT GUESSED. The filed patch proposed "cli-print" and
    # flagged it as unverified. Dumping the environment inside a real headless run:
    #     interactive   CLAUDE_CODE_ENTRYPOINT = cli
    #     headless -p   CLAUDE_CODE_ENTRYPOINT = sdk-cli
    # "cli-print" occurs nowhere, so the patch as filed would have been INERT — correct-looking,
    # shipped, and changing nothing.
    #
    # ⚠️ `sys.stdin.isatty()` is NOT a discriminator here and is deliberately not used: it is
    # false in BOTH cases, because a Stop hook always receives its event as JSON on stdin.
    # Including it would read like a second safeguard while contributing nothing.
    #
    # ⚠️ FAILS SAFE. This is a POSITIVE test for a headless run; an unknown or absent value keeps
    # the gate. If the harness renames this value the gate becomes too talkative in workers again
    # — the defect being fixed — rather than silently switching off where a human relies on it.
    if os.environ.get("CLAUDE_CODE_ENTRYPOINT") == "sdk-cli":
        return 0

    if stop_hook_active:
        return

    text = BRIEF if already_fired(sid) else GATE

    # Appended to BOTH texts, because the count is the one part that can CHANGE between
    # firings — the prose is the same reminder twice, the number may not be.
    n = open_item_count()
    if n is not None:
        text += (
            "\n\n⛔ operator-todo.md currently has %d open item(s). If that went UP this "
            "session and you closed none, you diverged: you surveyed instead of finishing. "
            "Adding an item is only progress when it names an operator-only blocker."
            % n
        )

    try:
        print(json.dumps({
            "systemMessage": text,
            "hookSpecificOutput": {"hookEventName": "Stop", "additionalContext": text},
        }))
    except Exception:
        pass


if __name__ == "__main__":
    main()
