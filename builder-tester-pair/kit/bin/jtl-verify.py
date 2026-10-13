#!/usr/bin/env python3
"""
jtl-verify.py — the ONE correct way to read a JMeter result in this estate.

Usage:  jtl-verify.py <file-with-jtl-in-it> [<file2> ...]
        kubectl logs job/x -n ns | jtl-verify.py -

Exists because ad-hoc parsing got it wrong twice in one session (2026-09-08):

  * Trusting JMeter's own `summary =` line reported **Err 0.00%** on a run whose
    JTL held **504 failures** — the summariser is blind to Transaction-Controller
    samplers, and 100% of the failures were inside that blind spot. (rulebook G72)

  * A line-by-line parser silently DROPPED a record whose failureMessage spans
    multiple lines (a Groovy stack trace), reporting 5 samples when there were 6 —
    and the dropped one was the only failure.

And once more, in THIS tool (2026-09-14):

  * A JTL block ended only at a line starting `=====`. A multi-plan job
    prints `=== JTL xx END ===`, so every block ran to end-of-file and re-read the later
    plans: 12 + 9 + 4 = 25 "samples" from 12 distinct rows, failures duplicated too —
    and the reconciliation MISMATCH it raised was self-inflicted, while the summary lines
    (3 + 5 + 4 = 12) were right. A block now ends at the first line starting `===` or at
    the next `timeStamp,` header, whichever comes first. `--selftest` pins it.

So this tool:
  1. parses the JTL as ONE csv stream, never line-by-line;
  2. counts failures from the `success` column, never from `summary =`;
  3. RECONCILES its own count against every `summary =` line it finds and shouts
     if they disagree — a mismatch is a blind spot, and that subtraction is the
     ten-second check that exposes it;
  4. exits 1 if anything failed or if the reconciliation disagrees, so it can gate.
"""
import csv
import io
import re
import sys

SUMMARY_RE = re.compile(r"^summary\s*=\s*(\d+)\s+in\b", re.M)


def parse(text):
    lines = text.split("\n")
    starts = [i for i, l in enumerate(lines) if l.startswith("timeStamp,")]
    rows = []
    for si in starts:
        # A block ends at the first `===` marker (`=== JTL xx END ===`, `=====`) OR at the
        # next JTL header — never at end-of-file when another plan follows, or that plan's
        # rows are counted again for every block before it.
        end = next((j for j in range(si + 1, len(lines))
                    if lines[j].startswith("===") or lines[j].startswith("timeStamp,")),
                   len(lines))
        block = "\n".join(lines[si:end])
        for r in csv.reader(io.StringIO(block)):
            if len(r) < 9 or r[0] == "timeStamp":
                continue
            try:
                int(r[0]); int(r[1])
            except ValueError:
                continue
            rows.append(r)
    return rows


HDR = ("timeStamp,elapsed,label,responseCode,responseMessage,threadName,dataType,success,"
       "failureMessage,bytes,sentBytes,grpThreads,allThreads,URL,Latency,IdleTime,Connect")


def _row(ts, label, ok=True, msg=""):
    return f"{ts},10,{label},{200 if ok else 500},{'OK' if ok else 'Err'},T 1-1,text,{'true' if ok else 'false'},{msg},1,1,1,1,http://x,5,0,1"


def selftest():
    """Synthetic logs with KNOWN counts. Each case must fail against the old `=====`-only boundary
    or against a line-by-line parser; run `jtl-verify.py --selftest` after any change here."""
    def plan(tag, n, fail_at=None, summary=True):
        rows = [_row(1789000000000 + i, f"{tag}{i}", ok=(i != fail_at)) for i in range(n)]
        return (["########## " + tag + " ##########"] + (["summary =      %d in 00:00:01 =    3.0/s" % n] if summary else [])
                + [f"=== JTL {tag} BEGIN ===", HDR] + rows + [f"=== JTL {tag} END ==="])
    cases = []
    # (a) the 2026-09-14 bug: three plans, `=== … END ===` markers, 3/5/4, one failure in plan 1
    cases.append(("multi-plan === END === markers", "\n".join(plan("cs", 3, 1) + plan("ce", 5) + plan("as", 4)), 12, 1, 12))
    # (b) legacy single block closed by `=====`
    cases.append(("legacy ===== terminator", "\n".join(["summary =      6 in 00:00:01", HDR] + [_row(1789000000100 + i, f"L{i}") for i in range(6)] + ["=====", "trailing noise"]), 6, 0, 6))
    # (c) no terminator at all — rows run to end of text
    cases.append(("no terminator", "\n".join([HDR] + [_row(1789000000200 + i, f"N{i}") for i in range(4)]), 4, 0, None))
    # (d) consecutive headers with no marker between them — must not double-count the second plan
    cases.append(("back-to-back headers", "\n".join([HDR] + [_row(1789000000300 + i, f"A{i}") for i in range(2)] + [HDR] + [_row(1789000000400 + i, f"B{i}") for i in range(3)]), 5, 0, None))
    # (e) a multi-line quoted failureMessage stays ONE record (the 2026-09-08 line-by-line bug)
    cases.append(("multi-line failureMessage", "\n".join([HDR, _row(1789000000500, "ok1"), _row(1789000000501, "bad", ok=False, msg='"Groovy trace\n  at line 1\n  at line 2"'), "=== END ==="]), 2, 1, None))
    ok = bad = 0
    for name, text, want_rows, want_fails, want_claimed in cases:
        rows = parse(text)
        fails = sum(1 for r in rows if r[7] != "true")
        claimed = _claimed(text)
        good = len(rows) == want_rows and fails == want_fails and (want_claimed is None or claimed == want_claimed)
        ok, bad = (ok + 1, bad) if good else (ok, bad + 1)
        print(f"  {'ok  ' if good else 'FAIL'}  {name}: rows={len(rows)} (want {want_rows}) failures={fails} (want {want_fails})"
              + ("" if want_claimed is None else f" summary={claimed} (want {want_claimed})"))
    # (f) zero samples is never a pass
    empty_ok = parse("no jtl here\nsummary =      0 in 00:00:00") == []
    ok, bad = (ok + 1, bad) if empty_ok else (ok, bad + 1)
    print(f"  {'ok  ' if empty_ok else 'FAIL'}  no JTL → 0 rows (main() then reports FAIL, not PASS)")
    print(f"\nselftest: {ok} passed, {bad} failed")
    return 0 if bad == 0 else 1


def _claimed(text):
    # A job may run SEVERAL plans, each printing its own cumulative summary.
    # Take the LAST summary of each plan (its final cumulative count) and sum
    # those -- max() across the whole file under-counts multi-plan jobs and
    # raised a false mismatch, which is exactly how a guard gets ignored.
    blocks = text.split("timeStamp,")
    per_plan = []
    for b in blocks[:-1] if len(blocks) > 1 else []:
        nums = [int(m) for m in SUMMARY_RE.findall(b)]
        if nums:
            per_plan.append(nums[-1])
    tail = [int(m) for m in SUMMARY_RE.findall(blocks[-1])] if blocks else []
    if tail:
        per_plan.append(tail[-1])
    return sum(per_plan) if per_plan else None


def main():
    if sys.argv[1:] == ["--selftest"]:
        return selftest()
    args = sys.argv[1:] or ["-"]
    text = ""
    for a in args:
        text += sys.stdin.read() if a == "-" else open(a, errors="replace").read()

    rows = parse(text)
    fails = [r for r in rows if r[7] != "true"]
    claimed = _claimed(text)

    # ZERO SAMPLES IS NOT A PASS. Caught 2026-09-08 reading a job that was still
    # RUNNING: no JTL had been emitted yet, and this tool printed
    # "samples 0 / failures 0 / VERDICT: PASS" -- the exact defect it exists to
    # prevent, in the tool itself. An empty result is not a checked-and-empty one.
    if not rows:
        print("  samples parsed from JTL : 0")
        print("\n  🛑 NO SAMPLES FOUND. This is NOT a pass — there is nothing to")
        print("     pass. Usual causes: the job is still RUNNING and has not")
        print("     printed its JTL; the plan died before the first sampler; or")
        print("     you piped the wrong logs. Check the Job's completion state")
        print("     BEFORE reading a verdict.")
        print("\n  VERDICT: FAIL (no data)")
        return 1

    print(f"  samples parsed from JTL : {len(rows)}")
    print(f"  failures (success!=true): {len(fails)}")
    if claimed is not None:
        print(f"  JMeter 'summary =' says : {claimed}")

    rc = 0
    if fails:
        rc = 1
        print("  FAILURES:")
        for r in fails:
            print(f"    ✗ {r[2][:52]:54s} code={r[3][:8]:10s} {r[4].splitlines()[0][:70]}")

    if claimed is not None and claimed != len(rows):
        rc = 1
        print(f"\n  🛑 RECONCILIATION MISMATCH: summary={claimed} vs JTL={len(rows)}"
              f" (delta {abs(claimed-len(rows))}).")
        print("     One of them cannot see something. That delta IS the blind spot —"
              " find what lives in it before reporting any result.")
    elif claimed is not None:
        print("  ✅ reconciles: summary count == JTL row count (no blind spot)")

    print(f"\n  VERDICT: {'PASS' if rc == 0 else 'FAIL'}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
