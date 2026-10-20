"""
TDD test list for the agent handoff contract checker.

This is the RED list — written before check_contract.py exists. Each case is
derived from a validation rule in CONTRACTS (check_contract.py), NOT invented
here. The rules under test:

  - LOCAL reject (data-transform lens): a consumer rejects a structurally
    incomplete handoff instead of guessing — every required section must be present.
  - No-guessing / cite-the-source: evidence-bearing artifacts must carry a
    real `file:line` citation.
  - Unforgeable evidence (promise theory): a validation verdict of PASS is only
    accepted if it carries test-count evidence; a bare "PASS" is UNVERIFIED.
  - Sourced knowledge: a knowledge-store entry must carry an id + a source.

Run: python3 check_contract_test.py   (stdlib only, no deps)
"""

import unittest

from check_contract import validate


GOOD_EVIDENCE_BUNDLE = """
SYMPTOM: copy yields 0 rules
SCOPE: service-a, DB
FLOW: HandleCopyAsync at service-a/Handlers/CommandHandlers.cs:706
EVIDENCE: rules never re-scoped; service-a/Handlers/CommandHandlers.cs:809 hardcodes RuleCount=0
RULED OUT: graph edges (relationship copied fine)
CANDIDATE FAILURE POINTS: missing INSERT into scoped_rule (ranked #1)
UNKNOWNS: none
PRIOR FINDING: F-001
"""

GOOD_VALIDATION_REPORT_PASS = """
INTENDED: copy re-scopes rules to new scope id
TESTED: HandleCopyAsync re-scope path
RESULT: 12 passed, 0 failed (test command for ServiceA.Tests)
EDGE CASES: empty source, 0 rules
REGRESSIONS: checked LIST-by-scope both sides
VERDICT: PASS
"""


class EvidenceBundleContract(unittest.TestCase):
    def test_wellformed_bundle_passes(self):
        r = validate("evidence_bundle", GOOD_EVIDENCE_BUNDLE)
        self.assertTrue(r.ok, msg=f"missing={r.missing} errors={r.errors}")

    def test_missing_required_section_is_rejected(self):
        # Drop UNKNOWNS — the LOCAL reject rule must catch it, not let it slide.
        text = GOOD_EVIDENCE_BUNDLE.replace("UNKNOWNS: none\n", "")
        r = validate("evidence_bundle", text)
        self.assertFalse(r.ok)
        self.assertIn("UNKNOWNS", r.missing)

    def test_evidence_without_file_line_citation_is_rejected(self):
        # No-guessing rule: EVIDENCE must cite file:line.
        text = """
SYMPTOM: x
SCOPE: y
FLOW: somewhere in the catalog
EVIDENCE: it just looks wrong, probably the copy handler
RULED OUT: nothing
CANDIDATE FAILURE POINTS: the copy handler
UNKNOWNS: everything
PRIOR FINDING: none
"""
        r = validate("evidence_bundle", text)
        self.assertFalse(r.ok)
        self.assertTrue(any("file:line" in e for e in r.errors))


class ValidationReportContract(unittest.TestCase):
    def test_pass_with_counts_is_accepted(self):
        r = validate("validation_report", GOOD_VALIDATION_REPORT_PASS)
        self.assertTrue(r.ok, msg=f"missing={r.missing} errors={r.errors}")

    def test_pass_without_evidence_counts_is_unverified(self):
        # Unforgeable-evidence rule: a bare PASS with no counts is rejected.
        text = GOOD_VALIDATION_REPORT_PASS.replace(
            "RESULT: 12 passed, 0 failed (test command for ServiceA.Tests)",
            "RESULT: looks good, tests are green",
        )
        r = validate("validation_report", text)
        self.assertFalse(r.ok)
        self.assertTrue(any("evidence" in e.lower() for e in r.errors))

    def test_pass_with_unrelated_stray_digit_is_unverified(self):
        # Regression (found by the blind adversary): a stray digit unrelated to a
        # test count ("day 3") must NOT forge a PASS — the count must look like one.
        text = GOOD_VALIDATION_REPORT_PASS.replace(
            "RESULT: 12 passed, 0 failed (test command for ServiceA.Tests)",
            "RESULT: works fine, shipped on day 3",
        )
        r = validate("validation_report", text)
        self.assertFalse(r.ok)
        self.assertTrue(any("evidence" in e.lower() for e in r.errors))

    def _pass_with_result(self, result):
        return validate("validation_report", GOOD_VALIDATION_REPORT_PASS.replace(
            "RESULT: 12 passed, 0 failed (test command for ServiceA.Tests)", "RESULT: " + result))

    def test_pass_with_failures_is_contradictory(self):
        # Regression (PR #22 review): a red run must not satisfy PASS just because it has a count.
        for result in ("12 failed", "10 passed, 2 failed", "8/10 green", "34 tests, 1 error", "ran 5, failures: 2",
                       # round 2 (adversary): other spellings of a red run
                       "10 passed; failed 3", "10 passed, 2 tests failed", "12 passed, 0 failed, 3 errored",
                       "--- FAIL: TestX (0.00s); 11 passed", "10 passed, two failed"):
            r = self._pass_with_result(result)
            self.assertFalse(r.ok, msg=result)

    def test_pass_with_zero_tests_is_unverified(self):
        for result in ("0 tests", "0 passed, 0 failed", "0/0", "ran 0 tests"):
            r = self._pass_with_result(result)
            self.assertFalse(r.ok, msg=result)

    def test_pass_with_clean_counts_is_accepted(self):
        for result in ("12 passed, 0 failed", "10/10 green", "Ran 34 tests, OK", "34 tests, 0 failures, 0 errors",
                       "passed: 7", "12 passed, 0 failed (shard 1/4)", "12 passed, no failures", "failures: 0, 9 passed"):
            r = self._pass_with_result(result)
            self.assertTrue(r.ok, msg=f"{result}: {r.errors}")

    def test_fail_verdict_may_carry_failures(self):
        text = GOOD_VALIDATION_REPORT_PASS.replace("0 failed", "3 failed").replace("VERDICT: PASS", "VERDICT: FAIL")
        self.assertTrue(validate("validation_report", text).ok)

    def test_unknown_verdict_value_is_rejected(self):
        text = GOOD_VALIDATION_REPORT_PASS.replace("VERDICT: PASS", "VERDICT: probably fine")
        r = validate("validation_report", text)
        self.assertFalse(r.ok)


class KnowledgeEntryContract(unittest.TestCase):
    def test_entry_with_id_and_source_passes(self):
        text = "F-007 - copy loses rules - FIXED. Source: CommandHandlers.cs:809"
        r = validate("knowledge_entry", text)
        self.assertTrue(r.ok, msg=f"errors={r.errors}")

    def test_entry_without_source_is_rejected(self):
        text = "F-007 - copy loses rules - FIXED"
        r = validate("knowledge_entry", text)
        self.assertFalse(r.ok)


class ProducerTemplatesMatchContracts(unittest.TestCase):
    """Regression (PR #22 review): each producing skill's output template, filled in, must satisfy its contract.
    A skill that renames a section (FEATURE vs FEATURE/FIX) or a verdict (safe vs PASS) fails here."""
    import os as _os
    SKILLS = _os.path.dirname(_os.path.dirname(_os.path.realpath(__file__)))
    FILL = {
        "RESULT": "12 passed, 0 failed (pytest)", "CONFIDENCE": "high",
    }

    def _template(self, skill):
        import os, re
        with open(os.path.join(self.SKILLS, skill, "SKILL.md"), encoding="utf-8") as f:
            text = f.read()
        block = re.search(r"## Output[^\n]*\n```\n(.*?)```", text, re.S)
        self.assertIsNotNone(block, f"{skill}: no ## Output code block")
        filled = []
        for part in re.split(r"(\||\n)", block.group(1)):
            m = re.match(r"\s*([A-Z][A-Z /]+):\s*(.*)", part)
            if m:
                label = m.group(1).strip()
                value = self.FILL.get(label, "see svc/handler.go:42")
                if label == "VERDICT":  # the template's own first verdict word, so a renamed vocabulary fails
                    value = re.sub(r"[^A-Za-z ]", " ", m.group(2)).split()[0]
                filled.append(f" {label}: {value} ")
            else:
                filled.append(part)
        return "".join(filled)

    def test_templates(self):
        for skill, contract in (("feature-planning", "design_spec"), ("root-cause-investigation", "root_cause"),
                                ("test-strategy", "validation_report")):
            with self.subTest(skill=skill):
                r = validate(contract, self._template(skill))
                self.assertTrue(r.ok, msg=f"{skill} -> {contract}: missing={r.missing} errors={r.errors}")


class UnknownContract(unittest.TestCase):
    def test_unknown_contract_name_errors(self):
        r = validate("not_a_contract", "anything")
        self.assertFalse(r.ok)
        self.assertTrue(any("unknown contract" in e.lower() for e in r.errors))


if __name__ == "__main__":
    unittest.main(verbosity=2)
