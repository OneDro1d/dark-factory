#!/usr/bin/env python3
"""PreCompact hook: write a deterministic resumable handoff snapshot before compaction.

Pairs with handoff-sessionstart-load.py, which re-injects it after compaction.
Keyed by session_id so the post-compaction SessionStart loads the matching one.
Pure-Python file (reads json.load(sys.stdin)) so stdin is not consumed by a heredoc.
Never raises — a failure must never block compaction; worst case a thinner snapshot.
"""
import json
import os
import sys
import time


def _clip(s, n=600):
    s = " ".join((s or "").split())
    return s if len(s) <= n else s[:n] + " …"


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return

    sid = data.get("session_id") or "unknown"
    cwd = data.get("cwd") or ""
    tpath = data.get("transcript_path") or ""

    files = []          # edited/written files (unique, order-preserving)
    seen = set()
    user_msgs = []      # recent user prompt texts
    last_assistant = ""

    if tpath and os.path.exists(tpath):
        try:
            with open(tpath, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        ev = json.loads(line)
                    except Exception:
                        continue
                    msg = ev.get("message", ev)
                    role = ev.get("type") or ev.get("role") or msg.get("role")
                    content = msg.get("content")
                    if content is None:
                        continue
                    blocks = content if isinstance(content, list) else [{"type": "text", "text": content}]
                    for b in blocks:
                        if not isinstance(b, dict):
                            continue
                        bt = b.get("type")
                        if bt == "tool_use":
                            name = b.get("name", "")
                            inp = b.get("input", {}) or {}
                            fp = inp.get("file_path") or inp.get("path")
                            if name in ("Edit", "Write", "MultiEdit", "NotebookEdit") and fp and fp not in seen:
                                seen.add(fp)
                                files.append(fp)
                        elif bt == "text":
                            txt = (b.get("text") or "").strip()
                            if not txt:
                                continue
                            if role == "user":
                                user_msgs.append(txt)
                            elif role == "assistant":
                                last_assistant = txt
        except Exception:
            pass

    hd = os.path.expanduser("~/.claude/handoffs")
    try:
        os.makedirs(hd, exist_ok=True)
    except Exception:
        return
    out = os.path.join(hd, sid + ".md")

    # POINT AT THE DELIBERATE HANDOFF, do not try to replace it.
    #
    # This file is the MECHANICAL snapshot: files touched, recent intent. The DELIBERATE
    # handoff -- the one that states where the work stands, the single next action, and links
    # every artefact -- is written by Skill(handoff) into <notepad>/handoffs/ and is a
    # different artefact entirely.
    #
    # ⚠️ THE GAP THIS CLOSES, measured 2026-09-01. On SessionStart(source=compact) the loader
    # re-injects THIS file. Nothing re-injected the deliberate handoff, and session-start.sh
    # never mentions handoffs/ at all -- so the estate's own rule that "the handoff is the
    # single entry point for a cold session" held on paper and not in the wiring. Orientation
    # survived compaction only because NOTES.md happened to be thorough, which is a property
    # of a good session rather than of the mechanism.
    #
    # One line of pointer fixes it. Naming the newest handoff costs nothing and turns this
    # snapshot into a signpost; COPYING it would create a second store of the same facts and
    # the two would drift, which is the failure the single-entry-point rule exists to prevent.
    newest_handoff = ""
    d = os.path.abspath(cwd) if cwd else ""
    while d and d != "/":
        if os.path.isfile(os.path.join(d, "NOTES.md")):      # this is the notepad root
            hdir = os.path.join(d, "handoffs")
            try:
                cands = [os.path.join(hdir, n) for n in os.listdir(hdir) if n.endswith(".md")]
                if cands:
                    newest_handoff = max(cands, key=os.path.getmtime)
            except Exception:
                pass
            break
        d = os.path.dirname(d)

    lines = [
        "# Pre-compaction handoff snapshot",
        "",
    ]
    if newest_handoff:
        lines += [
            "## ⛔ READ THIS FIRST — the deliberate handoff",
            "",
            f"    {newest_handoff}",
            "",
            "That file is the ENTRY POINT: where the work stands, the ONE next action, links to "
            "every artefact, and what is blocked and on whom. **Read it before anything below.** "
            "Everything in this snapshot is mechanical detail that the handoff already frames.",
            "",
            "⚠️ If it is stale or about different work, say so and fall back to `NOTES.md` and the "
            "mission's own `MISSION.md` — a handoff that does not orient you is a finding about "
            "the session that wrote it, not a reason to guess.",
            "",
        ]
    else:
        lines += [
            "## ⚠️ No deliberate handoff found",
            "",
            "No `<notepad>/handoffs/*.md` was found from this cwd, so this mechanical snapshot is "
            "all there is. Orient from `NOTES.md`. ⚠️ This is a gap, not a clean state: the 85% "
            "context gate exists precisely so a handoff is written BEFORE compaction.",
            "",
        ]
    lines += [
        f"- session: `{sid}`",
        f"- cwd: `{cwd}`",
        f"- saved: {time.strftime('%Y-%m-%d %H:%M:%S')} (epoch {int(time.time())})",
        "",
        "## Files written/edited this session",
    ]
    if files:
        lines += [f"- `{fp}`" for fp in files[-40:]]
    else:
        lines.append("- (none detected)")
    lines += ["", "## Recent user intent (last few prompts)"]
    if user_msgs:
        lines += [f"- {_clip(m)}" for m in user_msgs[-4:]]
    else:
        lines.append("- (none captured)")
    lines += [
        "",
        "## Where we left off (last assistant message)",
        _clip(last_assistant, 1500) if last_assistant else "(none captured)",
        "",
        "> Deterministic snapshot written by the PreCompact hook. For a richer narrative, run the `handoff` skill manually.",
    ]

    try:
        with open(out, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
    except Exception:
        return

    try:
        print(json.dumps({
            "systemMessage": (
                "Pre-compaction handoff snapshot saved; it will be re-injected after compaction. "
                "When summarizing, preserve open threads, files in progress, decisions, and next steps."
            )
        }))
    except Exception:
        pass


if __name__ == "__main__":
    main()
