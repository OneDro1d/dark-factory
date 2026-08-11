---
name: contract-check
description: Validate an agent hand-off (Evidence Bundle, Root Cause, Design Spec, Implementation Report, Validation Report, Knowledge Entry) against its data contract before consuming it. Use at any pipeline seam to enforce LOCAL-reject ("escalate, don't guess") and the unforgeable-evidence rule (a PASS must carry test counts) instead of trusting prose. Triggers on "check the handoff", "is this evidence bundle complete", "verify the validation report", "contract check".
allowed-tools: Read, Bash
---

# contract-check — reject incomplete hand-offs before you act on them

Goal: stop a malformed or under-evidenced hand-off from flowing downstream where
the next agent quietly copes — or guesses. This is the data-transform lens'
**LOCAL reject** rule and the promise-theory **unforgeable-evidence** rule, made
runnable. The contracts are defined in `.claude/context/AGENT-CONTRACTS.md`; this
skill runs the checker that mirrors them.

## When to run it
- A consuming agent receives an upstream artifact → check it **before** consuming.
  `REJECT` ⇒ kick back to the producer with the listed gaps; do not proceed.
- The orchestrator / a human reviews a `Validation Report` claiming PASS →
  confirm it carries test-count evidence (not "looks green").
- CI or a pre-commit hook wants a cheap structural gate on agent outputs.

## How to run it
```bash
# from repo root; reads a file or stdin
python3 .claude/skills/contract-check/check_contract.py <contract> path/to/artifact.txt

# contracts: evidence_bundle | root_cause | design_spec |
#            implementation_report | validation_report | knowledge_entry
```
Exit `0` + `OK` → consume. Exit `1` + `REJECT` → kick back; the output lists each
missing section and rule violation. Exit `2` → usage error.

## What each contract requires
See the table in `.claude/context/AGENT-CONTRACTS.md`. The rules with teeth:
- `evidence_bundle` / `root_cause` — must carry a real `file:line` citation.
- `validation_report` — `VERDICT` ∈ PASS|CONDITIONAL|FAIL, and a **PASS must
  carry test counts** (a bare "PASS" is UNVERIFIED → REJECT).
- `knowledge_entry` — must have an `F-###`/`D-###` id **and** a source.

## Maintaining it (the checker is itself test-first)
The checker is built RED→GREEN and guarded by tests:
```bash
python3 .claude/skills/contract-check/check_contract_test.py            # author suite
python3 .claude/skills/contract-check/check_contract_adversary_test.py  # blind adversary suite
```
If you add or change a contract: update `AGENT-CONTRACTS.md` (the source of
truth) **and** `check_contract.py` (its mirror), add a RED test first, keep both
suites green. No secrets/PII in fixtures.
