#!/usr/bin/env python3
"""SessionStart hook: re-inject the pre-compaction handoff snapshot after compaction.

Loads ~/.claude/handoffs/<session_id>.md and emits it as SessionStart additionalContext
when this start is post-compaction (source == "compact") OR the snapshot is fresh
(written < 15 min ago — a robust fallback if the source field/matcher is unavailable).
Then renames it to *.loaded so it is injected at most once. Pure-Python (reads stdin).
Never raises.
"""
import json
import os
import sys
import time


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return

    sid = data.get("session_id") or ""
    source = data.get("source") or ""
    if not sid:
        return

    path = os.path.join(os.path.expanduser("~/.claude/handoffs"), sid + ".md")
    if not os.path.exists(path):
        return

    is_compact = (source == "compact")
    try:
        fresh = (time.time() - os.path.getmtime(path)) < 900
    except Exception:
        fresh = False
    if not (is_compact or fresh):
        return

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            body = f.read()
    except Exception:
        return

    # consume-once
    try:
        os.replace(path, path + ".loaded")
    except Exception:
        pass

    ctx = (
        "Post-compaction handoff (auto-restored by the handoff hook). Continue where the "
        "pre-compaction context left off:\n\n" + body
    )
    try:
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "SessionStart",
                "additionalContext": ctx,
            }
        }))
    except Exception:
        pass


if __name__ == "__main__":
    main()
