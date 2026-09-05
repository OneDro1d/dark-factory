#!/usr/bin/env python3
"""git merge driver for sessions/index.json — a sessionId-keyed union.

WHY A CUSTOM DRIVER AND NOT `merge=union`
-----------------------------------------
The obvious fix is one line in .gitattributes:

    sessions/index.json merge=union

⛔ IT CORRUPTS THE FILE. git's built-in union driver is LINE-BASED: it concatenates both sides'
lines and does not know it is looking at JSON. MEASURED 2026-09-05:

    [                                     python3 -c "json.load(...)"
      {"sessionId": "shared"},            -> Expecting ',' delimiter:
      {"sessionId": "laptop"}                line 4 column 3
      {"sessionId": "poland"}
    ]

The comma between the two added entries is missing, because neither side's line had one. So
the remedy that removes a visible conflict would have produced an invisible corruption in the
one file this estate has already destroyed twice.

WHAT THIS DOES INSTEAD
----------------------
Parses both sides as JSON, unions them keyed by `sessionId`, keeps the LATER measurement when
both sides carry the same session, and preserves order.

AND WHAT IT REFUSES TO DO
-------------------------
Exits 1 (leaving a normal conflict for a human) when:
  - either side does not parse, or is not a list        -- a driver that cannot read its input
                                                           must REFUSE, not write its default
  - the union would be SHORTER than either input        -- entries are only ever appended, so a
                                                           shrink means the merge is wrong
  - the union contains duplicate sessionIds

⚠️ REGISTRATION IS PER-CLONE AND FAIL-SAFE. .gitattributes names the driver; the driver itself
must be registered with `git config merge.loom-session-index.driver`. On a clone where that has
not run, git falls back to a normal conflict -- the behaviour we have today -- never to
corruption. So shipping the attribute early is safe.

Usage (git calls it):  merge-session-index.py %O %A %B
  %O base, %A ours (also the OUTPUT path), %B theirs.
"""
import io
import json
import sys


def load(path, label):
    try:
        with io.open(path, encoding="utf-8") as fh:
            d = json.load(fh)
    except Exception as e:
        sys.stderr.write("merge-session-index: %s did not parse (%s) -- leaving a conflict\n"
                         % (label, e))
        return None
    if not isinstance(d, list):
        sys.stderr.write("merge-session-index: %s is %s, expected a list -- leaving a conflict\n"
                         % (label, type(d).__name__))
        return None
    return d


def key(e):
    return e.get("sessionId") if isinstance(e, dict) else json.dumps(e, sort_keys=True)


def stamp(e):
    if not isinstance(e, dict):
        return ("", 0)
    return (e.get("lastInteractionAt") or "", e.get("turns") or 0)


def main():
    if len(sys.argv) < 4:
        sys.stderr.write("merge-session-index: expected %O %A %B\n")
        return 1
    _base, ours_path, theirs_path = sys.argv[1], sys.argv[2], sys.argv[3]

    ours = load(ours_path, "ours")
    theirs = load(theirs_path, "theirs")
    if ours is None or theirs is None:
        return 1

    merged, order = {}, []
    for e in ours + theirs:
        k = key(e)
        if k not in merged:
            merged[k] = e
            order.append(k)
        elif stamp(e) > stamp(merged[k]):
            # Same session on both sides: keep the LATER measurement. Never synthesise one --
            # `turns` and `cursor` are measurements of a session nobody here observed.
            merged[k] = e
    out = [merged[k] for k in order]

    if len(out) < max(len(ours), len(theirs)):
        sys.stderr.write("merge-session-index: union %d < ours %d / theirs %d -- refusing\n"
                         % (len(out), len(ours), len(theirs)))
        return 1
    ids = [key(e) for e in out]
    if len(ids) != len(set(ids)):
        sys.stderr.write("merge-session-index: duplicate sessionIds in the union -- refusing\n")
        return 1

    try:
        with io.open(ours_path, "w", encoding="utf-8") as fh:
            json.dump(out, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
    except Exception as e:
        sys.stderr.write("merge-session-index: could not write the result (%s)\n" % e)
        return 1

    sys.stderr.write("merge-session-index: %d + %d -> %d entries, 0 duplicates\n"
                     % (len(ours), len(theirs), len(out)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
