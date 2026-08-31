#!/usr/bin/env python3
"""
Agent handoff contract checker — the LOCAL validation rule, mechanised.

Each agent in the chain emits a structured artifact that the next one consumes
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

Contract specs live in .claude/context/AGENT-CONTRACTS.md (the human source of
truth); this file is its executable mirror.
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
