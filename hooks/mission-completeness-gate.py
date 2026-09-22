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
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

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


PAGE = """⛔ operator-todo.md IS NOT IN SHAPE. Fix it before you stop.

Operator ruling 2026-09-22: every session keeps this page, and it holds ONLY OPEN items for the
human. A decision is asked in plain English, with the options, what each one means and what
follows from it, and a recommendation. No closed items, no narration, no history.

How: rewrite each item with `df-operator-todo add` (the same --id replaces it; a decision takes
two or more --option and one --recommend). Close finished ones with `df-operator-todo done`.
History goes to NOTES.md or git, never onto the page. Then `df-operator-todo lint` must say clean.

{lint}"""


def _find_notepad(start):
    d = os.path.abspath(start)
    for _ in range(12):
        if os.path.isfile(os.path.join(d, "NOTES.md")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent
    return None


def operator_page_problem(session_id, cwd):
    """Every session in a notepad keeps an operator-todo.md, and keeps it in shape (operator
    ruling 2026-09-22). Creates the page if absent; returns the block text if `lint` finds defects
    in a version of the page this session has not already been told about, else None.

    Once per PAGE VERSION (mtime+size), not once per stop: a page the session has not touched
    since the last nag is not re-nagged, and a fix — any rewrite — is re-checked at once.
    ⚠️ FAILS OPEN, deliberately the opposite of the rest of this hook: an old tool with no `lint`
    (rc 2), a missing tool, a timeout — all None. A page check that errors must not become a
    forced turn on every stop fleet-wide."""
    try:
        notepad = _find_notepad(cwd or os.getcwd())
        tool = os.environ.get("DF_OPERATOR_TODO_BIN") or shutil.which("df-operator-todo")
        if not notepad or not tool:
            return None
        page = os.path.join(notepad, "operator-todo.md")
        if not os.path.isfile(page):
            subprocess.run([tool, "--file", page, "init"], capture_output=True, timeout=10)
            return None
        st = os.stat(page)
        sig = "%d:%d" % (st.st_mtime_ns, st.st_size)
        mark = _state_path(session_id or "nosession", ".page")
        if os.path.exists(mark):
            with open(mark) as f:
                if f.read().strip() == sig:
                    return None
        r = subprocess.run([tool, "--file", page, "lint"], capture_output=True, text=True, timeout=10)
        os.makedirs(os.path.dirname(mark), exist_ok=True)
        with open(mark, "w") as f:
            f.write(sig)
        if r.returncode != 1:
            return None
        out = r.stdout
        if len(out) > 3000:
            out = out[:3000] + "\n… (cut; run `df-operator-todo lint` for the rest)"
        return PAGE.format(lint=out.rstrip())
    except Exception:
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


# ---- WHEN TO FIRE AT ALL: the cost of this hook is a whole model turn ----------------------------
# ⛔ MEASURED 2026-09-18 (Claude Code 2.1.276, a throwaway project whose Stop hook emits one output
# shape per run): `hookSpecificOutput.additionalContext` on Stop DOES make the model take another
# turn (two API requests where the control made one), exactly like `decision: block`. A
# `systemMessage` alone does not, and the model never sees it. So EVERY firing of this gate costs a
# full re-read of the context. Fleet-wide that day: 1,355 forced turns, ~807M cache-read tokens
# (~$390), mostly "nothing has changed" answered after a reply that did no work at all.
#
# The gate's purpose is unchanged: nudging REAL deferred work. What changes is WHEN it pays for that:
#   * a turn that made NO tool calls did no work, so it cannot have deferred any → emit nothing;
#   * the FULL gate still fires once per session, on the first turn that did work;
#   * after that, the brief reminder fires only when the turn did work AND either its final text
#     shows deferral language, or the operator page grew since the session's first firing.
# ⚠️ FAILS TOWARD PROMPTING: if the transcript cannot be read, the hook cannot tell whether the
# turn did work, and it fires as before. Absent evidence of "text-only" is not evidence of it.
TAIL_BYTES = 4 * 1024 * 1024
DEFERRAL = re.compile(
    r"\b(next step|follow[- ]?up|left for|remaining|still (?:open|outstanding|pending|to do)|"
    r"not (?:yet )?(?:done|finished)|deferred|out of scope|separate (?:pr|change|ticket)|"
    r"later|todo|to do next|recommend(?:ed)? next|worth a separate|not in this pr)\b",
    re.IGNORECASE)


# ---- STALL GUARD: a turn that ENDS on an announced action it did not take (2026-09-21) -----------
#
# ⛔ THE GAP THIS CLOSES IS THIS FILE'S OWN. "No work, no firing" (above) returns `{}` on any turn
# with no tool calls — and "Now I'll build feature X" followed by the end of the turn is exactly
# such a turn. A turn that DID work and then ends "now I'll build Y" slipped too: "I'll build" is
# not DEFERRAL language, and the brief form is throttled to 30 minutes. The operator reported
# sessions stopping mid-mission this way with open items left.
#
# ⛔ RE-CHECK CONDITION (the rule every gate here states first): fires only when the closing text
# announces an undone first-person action; ONCE per distinct text; and inside a stop chain
# (`stop_hook_active`) ONLY if the continuation made tool calls — i.e. it is progressing, not
# spinning. No progress -> release. Same text -> release. Claude Code's 9-consecutive-block cap is
# the backstop, not the design.
#
# ⛔ PRECISION IS THE WHOLE CONSTRAINT, because a firing costs a full model turn (the 1,355/day
# incident above). BACKTESTED on this estate's real transcripts, 2026-09-21, modelling the true
# Stop condition (turn's last block is TEXT; harness entries recorded as `user` mid-turn excluded):
#   tune    451 turn ends -> 2 fires, both genuine stalls; 21 future-phrase ends let through, all
#           correctly (external waits, conditionals, operator handoffs)
#   holdout 657 turn ends -> 7 fires, CLEAN: 2 stalls, 2 ambiguous, 3 false — every false one a
#           commitment tied to a SCHEDULED pass in a tick-driven session. That rule was then added,
#           so the holdout is CONTAMINATED from here: 3 fires, 2 stalls, 1 ambiguous.
#   overall fire rate 0.45% of real turn ends. There was no clean third set (one transcript
#   store). Recall has no labelled ground truth — humans here rarely type a bare "continue".
# ⚠️ The strongest single tell is a message whose RAW text ends on a colon: it was introducing a
# tool call that never came. RAW, because "Your test:" + a code block is the commonest legitimate
# ending there is, and stripping the fence first would turn it into a colon.
_COMMIT = re.compile(
    r"(?:^|[.!:;\n]\s*|\b(?:now|next|then|so|ok(?:ay)?|first|right)[,]?\s+)"
    r"(i'?ll|i will|i'm going to|i am going to|let me|going to)\s+([a-z][a-z'-]+)",
    re.IGNORECASE)
# After the commitment, verbs that describe WAITING, not doing. Ambiguous ones ("check", "keep",
# "follow") are DOING by default — "I'll check the logs" is work — and only the phrases in
# _WAIT_PHRASE count as waiting.
_WAIT_VERBS = {"wait", "hold", "stop", "pause", "leave", "report", "monitor", "watch", "hear",
               "ping", "circle", "revisit", "be", "know"}
_WAIT_PHRASE = re.compile(
    r"\b(check (?:back|in)|keep (?:an eye|watching|you posted)|follow up (?:when|once|after)|"
    r"get back to you|let you know|pick (?:this|it) up (?:when|once|after))\b", re.IGNORECASE)
# Handing a decision or an action to the operator is a legitimate stop.
_HANDOFF = re.compile(
    r"\b(let me know|say the word|your call|up to you|if you (?:want|'d like|prefer|agree)|"
    r"want me to|should i|shall i|do you want|would you like|once you|when you|after you|"
    r"waiting (?:on|for)|blocked on|need(?:s)? your|your (?:go|approval|decision|confirmation)|"
    r"on your go|with your go|give me the go|tell me (?:which|whether|if))\b", re.IGNORECASE)
# A commitment CONDITIONED ON AN EXTERNAL OR SCHEDULED EVENT is a wait: the event is not the
# agent's to produce ("once the developer returns", "when it fires", "on the next monitor pass").
_WAIT_EVENT = re.compile(
    r"\b(?:once|when|after|until|as soon as)\b[^.!?]{0,60}?\b(?:returns?|finish(?:es)?|"
    r"complete[sd]?|lands?|arrives?|comes? back|pass(?:es)? back|is done|are done|fires?|merges?|"
    r"(?:is|are|gets?) merged|responds?|repl(?:y|ies)|reports? back|is ready|are ready|wakes?|"
    r"confirms?|passes|is green|goes green|succeeds|clears)\b|"
    r"\b(?:on the next tick|at the next tick|nothing else i can do|unless you'?d rather|"
    r"unless you would rather|whatever \w+ (?:passes|sends|returns|decides))\b|"
    r"\b(?:on|at|in|by|during|for|to) (?:the |my |its |this )?(?:first|next|following|upcoming|"
    r"hourly|daily|nightly|scheduled) (?:\w+ ){0,2}(?:pass|tick|run|cycle|check|update|report|"
    r"sweep|round|poll|iteration|window)\b",
    re.IGNORECASE)
_FENCE = re.compile(r"```.*?```", re.DOTALL)

STALL = """⛔ STALLED ON AN ANNOUNCEMENT. Your last message ends with:
    "{phrase}"
and the turn ended without doing it. Do it now.
If it genuinely needs the operator — a decision, an irreversible act, a credential, a merge you
cannot make — name that one blocker in a line and stop. That is a complete answer, not a stall."""


def _closing_paragraph(text):
    text = _FENCE.sub("", text or "").strip()
    paras = [p.strip() for p in re.split(r"\n\s*\n", text) if p.strip()]
    return paras[-1] if paras else ""


def announced_intent(text):
    """The committed phrase if the message ENDS on an undone first-person action, else None."""
    para = _closing_paragraph(text)
    if not para or para.rstrip().endswith("?"):
        return None
    if _HANDOFF.search(para) or _WAIT_PHRASE.search(para) or _WAIT_EVENT.search(para):
        return None
    if (text or "").rstrip().endswith(":"):
        return re.split(r"(?<=[.!])\s+", para.strip())[-1][-80:]
    hit = None
    for m in _COMMIT.finditer(para):
        if m.group(2).lower() not in _WAIT_VERBS:
            hit = m
    if not hit:
        return None
    return para[hit.start(1):hit.start(1) + 80].split("\n")[0]


def _autoclear_owns_this_stop(session_id):
    """True when the context gate has ARMED autoclear for this session. It then owns this stop:
    phase 2 either fires `/clear` — which would discard a nudged turn's work, unrecorded in the
    checkpoint — or refuses and asks for the checkpoint itself. Its resume prompt continues the
    mission after the clear, so a stall nudge here only costs a turn that gets thrown away.
    Read from the arm marker, which was written on an EARLIER stop — the two Stop hooks run in
    parallel, so reading anything this stop writes would be a race."""
    if os.environ.get("DF_CONTEXT_GATE_MODE") != "autoclear":
        return False
    d = os.path.join(os.path.expanduser("~"), ".claude", "state", "context-budget")
    key = str(session_id or "nosession").replace("/", "_")
    try:
        for p in glob.glob(os.path.join(glob.escape(d), glob.escape(key) + ".e*")):
            if re.search(r"\.e\d+$", p) and not (os.path.exists(p + ".cleared")
                                                 or os.path.exists(p + ".disarmed")):
                return True
    except Exception:
        pass
    return False


def _stall_already_nudged(session_id, text):
    """Once per distinct text: records it and returns False the first time, True after."""
    h = hashlib.sha1((text or "").encode("utf-8", "replace")).hexdigest()
    try:
        p = _state_path(session_id or "nosession", ".stall")
        if os.path.exists(p):
            with open(p) as f:
                if f.read().strip() == h:
                    return True
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(h)
    except Exception:
        pass
    return False


def _is_real_prompt(rec):
    """A user entry that is a genuine prompt, not a tool result coming back."""
    if rec.get("type") != "user":
        return False
    c = (rec.get("message") or {}).get("content")
    if isinstance(c, str):
        return True
    if isinstance(c, list):
        return any(isinstance(b, dict) and b.get("type") == "text" for b in c) and \
            not all(isinstance(b, dict) and b.get("type") == "tool_result" for b in c)
    return False


def last_turn(transcript):
    """(did_work, final_text) for the turn that just ended, or (None, "") if unreadable.

    Reads only the tail of the transcript (they reach 100+ MB) and walks back to the last genuine
    prompt. did_work = any assistant tool_use after it; final_text = its last assistant text.
    """
    try:
        size = os.path.getsize(transcript)
        with open(transcript, "rb") as f:
            f.seek(max(0, size - TAIL_BYTES))
            lines = f.read().decode("utf-8", "replace").splitlines()
        recs = []
        for ln in lines:
            try:
                recs.append(json.loads(ln))
            except Exception:
                continue
        start = None
        for i in range(len(recs) - 1, -1, -1):
            if _is_real_prompt(recs[i]):
                start = i
                break
        if start is None:
            return None, ""
        did_work, text = False, ""
        for r in recs[start + 1:]:
            if r.get("type") != "assistant":
                continue
            for b in (r.get("message") or {}).get("content") or []:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "tool_use":
                    did_work = True
                elif b.get("type") == "text" and b.get("text"):
                    text = b["text"]
        return did_work, text
    except Exception:
        return None, ""


def _state_path(session_id, ext):
    d = os.path.join(tempfile.gettempdir(), "claude-completeness-gate")
    return os.path.join(d, re.sub(r"[^A-Za-z0-9_.-]", "_", session_id) + ext)


def _baseline_path(session_id):
    return _state_path(session_id, ".todo")


def todo_grew(session_id, n):
    """True if the open-item count is above what it was at this session's first firing.
    Records the baseline on first sight. Never raises."""
    if n is None or not session_id:
        return False
    try:
        p = _baseline_path(session_id)
        if not os.path.exists(p):
            with open(p, "w") as f:
                f.write(str(n))
            return False
        with open(p) as f:
            return n > int(f.read().strip() or n)
    except Exception:
        return False


# ---- THROTTLE: at most one brief reminder per BRIEF_INTERVAL_S per session -----------------------
# ⛔ MEASURED 2026-09-18 (gate recount after the "no work, no firing" change above): fleet forced
# turns fell 2.8 → 0.5 per 100 replies, but ONE session went UP, 1.1 → 1.7. Its replies were status
# lines naming the blocker ("waiting on the merge"), which the DEFERRAL regex matches — so the brief
# form fired on every working turn and asked for the list the reply had just given. Rewording the
# regex would be gamed by wording; a time budget cannot be. This is CFEngine's `ifelapsed`: a
# promise already checked is not re-checked until the interval has passed.
# ⚠️ The throttle applies ONLY to the brief form. The full gate still fires on a session's first
# working turn, whatever the clock says.
# ⚠️ FAILS TOWARD PROMPTING, like everything else here: if the stamp cannot be read or written, the
# reminder fires.
BRIEF_INTERVAL_S = 30 * 60


def brief_due(session_id, now=None):
    """True if no brief reminder fired for this session in the last BRIEF_INTERVAL_S; records the
    firing when it is due. Never raises; any error → True."""
    if not session_id:
        return True
    try:
        now = time.time() if now is None else now
        p = _state_path(session_id, ".brief")
        if os.path.exists(p):
            with open(p) as f:
                last = float(f.read().strip() or 0)
            if 0 <= now - last < BRIEF_INTERVAL_S:
                return False
        with open(p, "w") as f:
            f.write(str(now))
        return True
    except Exception:
        return True


def main():
    sid = ""
    cwd = ""
    stop_hook_active = False
    transcript = ""
    final_text = ""
    try:
        event = json.load(sys.stdin) or {}
        sid = event.get("session_id") or ""
        stop_hook_active = bool(event.get("stop_hook_active"))
        transcript = event.get("transcript_path") or ""
        final_text = event.get("last_assistant_message") or ""
        cwd = event.get("cwd") or ""
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

    did_work, tail_text = (None, "")
    if transcript and os.path.isfile(transcript):
        did_work, tail_text = last_turn(transcript)
    final_text = final_text or tail_text

    # ⛔ THE STALL GUARD RUNS BEFORE BOTH RELEASES BELOW, deliberately: the stall IS a text-only
    # turn, so placed after "no work, no firing" it could never fire. Inside a stop chain it fires
    # only when the continuation made tool calls — `last_turn` walks back to the last real prompt,
    # and the previous nudge is recorded as one, so `did_work` here means work SINCE the nudge.
    # Off switch: a fleet-wide hook that forces turns needs one that is not "revert the file".
    intent = None if os.environ.get("DF_STALL_GUARD") == "off" else announced_intent(final_text)
    if intent and not _autoclear_owns_this_stop(sid) and (not stop_hook_active or did_work is True):
        if not _stall_already_nudged(sid, final_text):
            print(json.dumps({"decision": "block", "reason": STALL.format(phrase=intent)}))
            return

    if stop_hook_active:
        return

    # ⛔ NO WORK, NO FIRING. Decided from the transcript when it can be read; see the block above.
    if did_work is False:
        print("{}")
        return
    final_text = final_text or tail_text

    # The operator page, checked on working turns only (a text-only turn changed nothing). It
    # outranks the completeness prose: a page the operator cannot read is the more concrete defect.
    page = None if os.environ.get("DF_OPERATOR_PAGE_CHECK") == "off" else operator_page_problem(sid, cwd)
    if page:
        print(json.dumps({"decision": "block", "reason": page}))
        return

    n = open_item_count()
    if already_fired(sid):
        # After the session's first firing: only when there is something the brief form can act on.
        # did_work is True here, or None (unreadable transcript → fail toward prompting).
        if did_work is True and not DEFERRAL.search(final_text or "") and not todo_grew(sid, n):
            print("{}")
            return
        if not brief_due(sid):
            print("{}")
            return
        text = BRIEF
    else:
        text = GATE
        todo_grew(sid, n)  # record this session's baseline count

    # Appended to BOTH texts, because the count is the one part that can CHANGE between
    # firings — the prose is the same reminder twice, the number may not be.
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
