#!/usr/bin/env python3
"""
Agent handoff contract checker — the LOCAL validation rule, mechanised.

Each agent emits a structured artifact that the next agent consumes
(Evidence Bundle -> Root Cause -> Design Spec -> Implementation Report ->
Validation Report; plus Knowledge Entry into the context store). Today those
shapes are prose conventions: nothing stops a malformed or under-evidenced
hand-off from flowing downstream, where the next agent quietly copes — or
guesses. This module turns the data-transform lens' "LOCAL reject" rule and the
promise-theory "unforgeable evidence" rule into a check a consuming agent (or a
human, or CI) can run:

    validate(contract, text) -> Result(ok, missing, errors, warnings)

A consumer SHOULD reject (kick back to the producer) when ok is False, instead
of proceeding on an incomplete promise. Pure function, stdlib only, no I/O in
validate() — so it is cheap to call and trivial to test.

Contract specs live in CONTRACTS below; the producing skills' output templates
(feature-planning, root-cause-investigation, test-strategy) use the same section
names, and check_contract_test.py checks they stay in step.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field

# A file:line citation: `path.ext:123` or `dir/File.cs:706`. The `:digits` must
# be glued to the token, so a label like "EVIDENCE: foo" never counts as one.
_FILE_LINE = re.compile(r"[\w./\-]+\.[A-Za-z0-9]+:\d+")

# Knowledge-store ids and sources.
_KNOWLEDGE_ID = re.compile(r"\b[FD]-\d{2,}\b")
_TICKET = re.compile(r"\bCAT-\d+\b")
_SOURCE_LABEL = re.compile(r"(?i)\bsource\s*:")

_VALID_VERDICTS = ("PASS", "CONDITIONAL", "FAIL")

# A *test-count*-shaped token, not just any digit. "12 passed, 0 failed",
# "10/10 green", "Ran 34 tests", "0 failures" qualify; "shipped on day 3",
# "version 2" do not. (Found by blind adversary: a bare digit forged a PASS.)
_TEST_COUNT = re.compile(
    r"(?i)(?:"
    r"\b\d+\s*/\s*\d+\b"                                                       # 10/10
    r"|\b\d+\s+(?:passed|passing|passes|pass|failed|failing|fail|failures?|tests?|errors?|skipped|green|ok)\b"
    r"|\b(?:passed|passing|failed|failing|tests?|pass|fail|ran|green)\b[^\n]{0,12}?\d+"
    r")"
)


@dataclass
class Result:
    contract: str
    ok: bool = True
    missing: list = field(default_factory=list)   # required sections absent
    errors: list = field(default_factory=list)    # rule violations (block)
    warnings: list = field(default_factory=list)  # advisory, non-blocking

    def finalize(self) -> "Result":
        self.ok = not self.missing and not self.errors
        return self


def _present(text: str, label: str) -> bool:
    """A section is present if its LABEL appears followed by a colon, at line
    start or after a `|`/bullet separator (handles `A: x | B: y` one-liners)."""
    pat = r"(?im)(?:^|[|>*#\-\s])" + re.escape(label) + r"\s*:"
    return re.search(pat, text) is not None


def _value_after(text: str, label: str) -> str:
    """Text following `LABEL:` up to the next `|` or newline (best-effort)."""
    m = re.search(r"(?im)" + re.escape(label) + r"\s*:\s*(.+?)(?:\||\n|$)", text)
    return m.group(1).strip() if m else ""


# contract -> (required sections, rule function)
def _rule_evidence(text: str, r: Result) -> None:
    if not _FILE_LINE.search(text):
        r.errors.append("no file:line citation (no-guessing rule): evidence must cite source")


def _rule_root_cause(text: str, r: Result) -> None:
    if not _FILE_LINE.search(text):
        r.errors.append("MECHANISM must cite a file:line (no-guessing rule)")
    conf = _value_after(text, "CONFIDENCE").lower()
    if conf and not conf.startswith(("high", "med", "low")):
        r.warnings.append(f"CONFIDENCE '{conf}' is not high|med|low")


def _rule_validation(text: str, r: Result) -> None:
    verdict = _value_after(text, "VERDICT").upper()
    token = verdict.split("(")[0].strip().split()[0] if verdict else ""
    if token not in _VALID_VERDICTS:
        r.errors.append(f"VERDICT '{verdict or '(none)'}' must be one of {_VALID_VERDICTS}")
        return
    if token == "PASS":
        result_line = _value_after(text, "RESULT")
        if not _TEST_COUNT.search(result_line):
            r.errors.append(
                "PASS verdict without test-count evidence (unforgeable-evidence rule): "
                "RESULT must carry pass/fail counts (e.g. '12 passed, 0 failed'), "
                "not a bare assertion or an unrelated number"
            )
            return
        passed, bad = _counts(result_line)
        if bad:
            r.errors.append("PASS verdict contradicts RESULT: it reports failures or errors (a red run is not a PASS)")
        elif passed <= 0:
            r.errors.append("PASS verdict with zero tests run: RESULT must show at least one executed test")


# Counts inside a RESULT line.
# Failures: ANY failure word (failed, failing, failures, errors, errored, FAIL) that is not paired with a zero count
# ("0 failed", "failures: 0", "no failures") is a red run, however it is spelled: "failed 3", "2 tests failed",
# "two failed", "--- FAIL: TestX". Executed: "12 passed", "34 tests", "ran 5", "passed: 7", and N of an N/M ratio
# that sits next to a test word ("10/10 green", "passed 8/10") — a bare ratio like "(shard 1/4)" is not a count.
_FAIL_WORD = re.compile(r"(?i)\b(?:failed|failing|failures?|fail|errors?|errored)\b|\bFAIL\b")
_ZERO_BEFORE = re.compile(r"(?i)(?:^|[\s,;(])(?:0|no|zero|none)\s+(?:tests?\s+)?$")
_ZERO_AFTER = re.compile(r"(?i)^\s*[:=]?\s*(?:0|none)\b")
_RUN_N = re.compile(r"(?i)\b(\d+)\s+(?:passed|passing|passes|pass|tests?|green|ok)\b"
                    r"|\b(?:passed|passing|pass|ran|tests?|green)\s*[:=]?\s*(\d+)\b(?!\s*/)")
_RATIO = re.compile(r"(?i)(?:\b(?:passed|passing|pass|green|ok|tests?)\s*[:=]?\s*)?\b(\d+)\s*/\s*(\d+)\b"
                    r"(?:\s*(?:passed|passing|pass|green|ok|tests?)\b)?")


def _counts(line: str) -> tuple:
    """(executed-or-passed, number of red signals) found in a RESULT line."""
    bad = 0
    for m in _FAIL_WORD.finditer(line):
        before, after = line[max(0, m.start() - 16):m.start()], line[m.end():m.end() + 8]
        if not (_ZERO_BEFORE.search(before) or _ZERO_AFTER.match(after)):
            bad += 1
    passed = max([int(a or b) for a, b in _RUN_N.findall(line)] or [0])
    for m in _RATIO.finditer(line):
        if not re.search(r"(?i)passed|passing|pass|green|ok|tests?", m.group(0)):
            continue                                   # "(shard 1/4)": not a test count
        n, total = int(m.group(1)), int(m.group(2))
        passed = max(passed, n)
        bad += total > n
    return passed, bad


def _rule_knowledge(text: str, r: Result) -> None:
    if not _KNOWLEDGE_ID.search(text):
        r.errors.append("knowledge entry must carry an F-### or D-### id")
    has_source = bool(_FILE_LINE.search(text) or _TICKET.search(text) or _SOURCE_LABEL.search(text))
    if not has_source:
        r.errors.append("knowledge entry must cite a source (file:line, CAT-####, or 'Source:')")


CONTRACTS = {
    "evidence_bundle": (
        ["SYMPTOM", "SCOPE", "FLOW", "EVIDENCE", "RULED OUT",
         "CANDIDATE FAILURE POINTS", "UNKNOWNS", "PRIOR FINDING"],
        _rule_evidence,
    ),
    "root_cause": (
        ["ROOT CAUSE", "MECHANISM", "EVIDENCE BASIS", "BLAST RADIUS",
         "FIX OPTIONS", "CONFIDENCE"],
        _rule_root_cause,
    ),
    "design_spec": (
        ["FEATURE/FIX", "ACCEPTANCE", "APPROACH", "FILES TO TOUCH",
         "TEST PLAN", "ADR"],
        None,
    ),
    "implementation_report": (
        ["CHANGED", "BUILD", "READY FOR"],
        None,
    ),
    "validation_report": (
        ["INTENDED", "TESTED", "RESULT", "VERDICT"],
        _rule_validation,
    ),
    "knowledge_entry": (
        [],  # free-form line(s); structure enforced by the rule, not headers
        _rule_knowledge,
    ),
}


def validate(contract: str, text: str) -> Result:
    """Check `text` against the named contract. Pure — no I/O, no exceptions."""
    spec = CONTRACTS.get(contract)
    r = Result(contract=contract)
    if spec is None:
        r.errors.append(f"unknown contract: {contract!r} (known: {sorted(CONTRACTS)})")
        return r.finalize()
    required, rule = spec
    for label in required:
        if not _present(text, label):
            r.missing.append(label)
    if rule is not None:
        rule(text, r)
    return r.finalize()


def _main(argv: list) -> int:
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print("usage: check_contract.py <contract> [file]   "
              "(reads stdin if no file)\n"
              f"contracts: {', '.join(sorted(CONTRACTS))}", file=sys.stderr)
        return 2
    contract = argv[1]
    text = open(argv[2], encoding="utf-8").read() if len(argv) > 2 else sys.stdin.read()
    r = validate(contract, text)
    if r.ok:
        print(f"OK  {contract}: contract satisfied")
        return 0
    print(f"REJECT  {contract}: kick back to producer")
    for m in r.missing:
        print(f"  missing section: {m}")
    for e in r.errors:
        print(f"  rule violation:  {e}")
    for w in r.warnings:
        print(f"  warning:         {w}")
    return 1


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv))
