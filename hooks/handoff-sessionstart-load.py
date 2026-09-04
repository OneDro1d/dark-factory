#!/usr/bin/env python3
"""SessionStart hook: point a fresh session at the handoff, on EVERY cold path.

Two independent sources, in priority order:

  1. The PreCompact snapshot ~/.claude/handoffs/<session_id>.md, when one exists and
     applies (source == "compact", or written < 15 min ago). Consumed once, then renamed
     to *.loaded. This is the mechanical detail: files touched, recent intent.

  2. FALLBACK, and the reason this hook is not a compaction hook: the newest
     <notepad>/handoffs/*.md resolved by walking up from cwd for NOTES.md. Needs no
     snapshot, so it works on the paths that write none.

WARNING -- THE GAP THIS CLOSES, measured 2026-09-02. /clear and auto-compaction are NOT the
same path. Compaction fires PreCompact, so a snapshot exists and source 1 fires. /clear fires
no PreCompact at all -- no snapshot is ever written, and this hook used to return at the
os.path.exists check with nothing emitted. A cleared session was therefore told about the
deliberate handoff by nothing except whatever NOTES.md happened to say. The estate's own rule
-- "the handoff is the single entry point for a cold session" -- held for compaction and
silently did not hold for the clear that operators actually type.

WARNING -- the wiring was never the bug. settings.json already registers this hook with an
EMPTY matcher, so it fires on startup/resume/clear/compact alike. The gate was in this file.
A hook that is correctly wired and returns early is indistinguishable, from outside, from one
that was never wired -- which is why lock-verify L9 could not have caught this and a test had
to.

WARNING -- it POINTS, it does not COPY. Inlining the handoff would create a second store of
the same facts and the two would drift, which is the failure the single-entry-point rule
exists to prevent.

Pure-Python (reads stdin). Never raises.
"""
import json
import os
import sys
import time

# Cap the injected handoff. Bounded because an unbounded read is how the SessionStart argv
# defect got in; the cap ANNOUNCES itself when it bites, so a partial handoff can never be
# mistaken for a whole one. Handoffs on this estate top out around 17 KB, so this is headroom,
# not a squeeze.
MAX_HANDOFF_BYTES = int(os.environ.get("HANDOFF_MAX_BYTES") or 65536)

# Sources that mean "this session has no prior context in the window".
# `resume` is deliberately absent: the context is still there, so a pointer is noise.
COLD_SOURCES = ("clear", "startup", "compact")


def find_newest_handoff(cwd):
    """Walk up from cwd for the notepad root (NOTES.md), return its newest handoffs/*.md.

    Returns (notepad_root, handoff_path). Either may be "" -- a missing notepad and a
    notepad with no handoffs are different findings, and the caller reports them differently.
    """
    d = os.path.abspath(cwd) if cwd else ""
    while d and d != os.path.dirname(d):
        if os.path.isfile(os.path.join(d, "NOTES.md")):
            hdir = os.path.join(d, "handoffs")
            try:
                cands = [os.path.join(hdir, n) for n in os.listdir(hdir) if n.endswith(".md")]
                if cands:
                    return d, max(cands, key=os.path.getmtime)
            except Exception:
                pass
            return d, ""
        d = os.path.dirname(d)
    return "", ""


def emit(ctx):
    """Emit BOTH systemMessage and hookSpecificOutput.additionalContext.

    Belt-and-suspenders, and it settles a contradiction this estate hit twice. One record
    says non-tool events (PreCompact/SessionStart/Stop) must use `systemMessage` because
    `additionalContext` is PreToolUse/PostToolUse only; `additionalContext` is nevertheless
    observed working for SessionStart here. The resolving measurement (2026-06-26) is that
    the known-good SessionStart hook in this environment emits BOTH with the same text.
    Emitting one field costs nothing to double and removes the whole question.
    """
    try:
        print(json.dumps({
            "systemMessage": ctx,
            "hookSpecificOutput": {
                "hookEventName": "SessionStart",
                "additionalContext": ctx,
            },
        }))
    except Exception:
        pass


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return

    sid = data.get("session_id") or ""
    source = data.get("source") or ""
    cwd = data.get("cwd") or os.getcwd()

    # ---- source 1: the PreCompact snapshot, when one exists and applies ----
    if sid:
        path = os.path.join(os.path.expanduser("~/.claude/handoffs"), sid + ".md")
        if os.path.exists(path):
            is_compact = (source == "compact")
            try:
                fresh = (time.time() - os.path.getmtime(path)) < 900
            except Exception:
                fresh = False
            if is_compact or fresh:
                try:
                    with open(path, "r", encoding="utf-8", errors="replace") as f:
                        body = f.read()
                except Exception:
                    body = ""
                if body:
                    try:
                        os.replace(path, path + ".loaded")   # consume-once
                    except Exception:
                        pass
                    emit(
                        "Post-compaction handoff (auto-restored by the handoff hook). Continue "
                        "where the pre-compaction context left off:\n\n" + body
                    )
                    return

    # ---- source 2: the deliberate handoff itself, needing no snapshot ----
    if source and source not in COLD_SOURCES:
        return

    notepad, handoff = find_newest_handoff(cwd)
    if not notepad:
        return          # not in a notepad; silence is correct, this hook has no business here

    if not handoff:
        # A notepad with no handoffs at all. Worth one line on the paths where continuity was
        # expected -- but never on a plain startup, where a new notepad legitimately has none.
        if source in ("clear", "compact"):
            emit(
                "WARNING: no deliberate handoff found in "
                + os.path.join(notepad, "handoffs") + "\n\n"
                "This session started from '" + source + "' -- a path that expects continuity "
                "-- and there is nothing to resume from. Orient from NOTES.md. **This is a gap, "
                "not a clean state:** a handoff should have been published before the context "
                "was discarded."
            )
        return

    # ⛔ INJECT THE CONTENT. THIS HOOK USED TO EMIT THE PATH AND SAY "read it before acting".
    #
    # MEASURED 2026-09-04 on a real /clear, and again mechanically with `claude -p`: the session
    # answered "session start auto-loads NOTES.md, not the handoff file" and carried on without
    # the mission. A hook cannot make a model open a file. It can only put text in the context,
    # so a PATH is a request and CONTENT is delivery -- and a request competes with everything
    # else in a large payload.
    #
    # ⚠️ WORSE, TWO HOOKS WERE ANSWERING THE SAME QUESTION DIFFERENTLY. agent-notepad's
    # session-start.sh injects the handoff body; this one emitted a pointer, and both opened with
    # "READ THIS FIRST". The model believed the pointer and reported the handoff absent WHILE THE
    # BODY WAS ALSO IN ITS CONTEXT. One artifact, two homes, and the halves disagreed.
    #
    # The de-duplication is deliberate and is why this reads a marker rather than just injecting:
    # inside an agent-notepad, that hook OWNS the handoff and this one must stay silent. Emitting
    # both would put the same 17 KB in twice and reintroduce the contradiction the moment the two
    # texts drift apart again.
    notepad_hook = os.path.join(
        os.path.expanduser("~"), ".claude", "hooks", "agent-notepad", "hooks", "session-start.sh"
    )
    if os.path.isfile(notepad_hook):
        try:
            with open(notepad_hook, encoding="utf-8", errors="replace") as fh:
                owns_handoff = "NEWEST HANDOFF" in fh.read()
        except Exception:
            owns_handoff = False
        if owns_handoff:
            return      # agent-notepad injects it. Silence here is the de-duplication.

    try:
        with open(handoff, encoding="utf-8", errors="replace") as fh:
            body = fh.read(MAX_HANDOFF_BYTES + 1)
    except Exception as e:
        # ⚠️ Falling back to the PATH is correct ONLY here, where the content is genuinely
        # unavailable -- and it says so, rather than presenting a request as a delivery.
        emit("## READ THIS FIRST -- the deliberate handoff\n\n    " + handoff + "\n\n"
             "Its content could NOT be read (" + str(e) + "), so this is a path, not the "
             "document. Open it before acting.")
        return

    truncated = len(body) > MAX_HANDOFF_BYTES
    if truncated:
        body = body[:MAX_HANDOFF_BYTES]

    msg = (
        "## READ THIS FIRST -- the deliberate handoff (full text below)\n\n"
        "    " + handoff + "\n\n"
        "This session began from '" + (source or "unknown") + "', so it carries no prior "
        "context. This is the ENTRY POINT: where the work stands, the ONE next action, links to "
        "every artefact touched, and what is blocked and on whom. Resume from it -- do not "
        "re-derive it, and do not re-explore what it already links.\n\n"
        "WARNING: if it is stale or describes different work, say so and fall back to NOTES.md "
        "and the mission's own MISSION.md. A handoff that does not orient you is a finding "
        "about the session that wrote it, not a reason to guess.\n\n"
        "---8<--- handoff begins ---8<---\n" + body
    )
    msg += ("\n---8<--- TRUNCATED at %d bytes. THIS IS NOT THE WHOLE HANDOFF -- open %s "
            "for the rest. ---8<---\n" % (MAX_HANDOFF_BYTES, handoff)) if truncated \
        else "\n---8<--- handoff ends ---8<---\n"
    emit(msg)


if __name__ == "__main__":
    main()
