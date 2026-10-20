---
name: contract-check
description: Validate an agent hand-off (Evidence Bundle, Root Cause, Design Spec, Implementation Report, Validation Report, Knowledge Entry) against its data contract before consuming it. Use at any pipeline seam to enforce LOCAL-reject ("escalate, don't guess") and the unforgeable-evidence rule (a PASS must carry test counts) instead of trusting prose. Triggers on "check the handoff", "is this evidence bundle complete", "verify the validation report", "contract check".
allowed-tools: Read, Bash
---

# contract-check — reject incomplete hand-offs before you act on them

Goal: stop a malformed or under-evidenced hand-off from flowing downstream where
the next agent quietly copes — or guesses. This is the data-transform lens'
**LOCAL reject** rule and the promise-theory **unforgeable-evidence** rule, made
runnable. The contracts are defined in `CONTRACTS` in `check_contract.py` (table below);
the producing skills' output templates use the same section names.

## When to run it
- A consuming agent receives an upstream artifact → check it **before** consuming.
  `REJECT` ⇒ kick back to the producer with the listed gaps; do not proceed.
- The orchestrator / a human reviews a `Validation Report` claiming PASS →
  confirm it carries test-count evidence (not "looks green").
- CI or a pre-commit hook wants a cheap structural gate on agent outputs.

## How to run it
```bash
# reads a file or stdin (install.sh links this skill into ~/.claude/skills)
python3 ~/.claude/skills/contract-check/check_contract.py <contract> path/to/artifact.txt

# contracts: evidence_bundle | root_cause | design_spec |
#            implementation_report | validation_report | knowledge_entry
```
Exit `0` + `OK` → consume. Exit `1` + `REJECT` → kick back; the output lists each
missing section and rule violation. Exit `2` → usage error.

## What each contract requires
| contract | produced by | required sections |
|---|---|---|
| `evidence_bundle` | codebase-understanding / dependency-mapping | SYMPTOM, SCOPE, FLOW, EVIDENCE, RULED OUT, CANDIDATE FAILURE POINTS, UNKNOWNS, PRIOR FINDING |
| `root_cause` | root-cause-investigation | ROOT CAUSE, MECHANISM, EVIDENCE BASIS, BLAST RADIUS, FIX OPTIONS, CONFIDENCE |
| `design_spec` | feature-planning | FEATURE/FIX, ACCEPTANCE, APPROACH, FILES TO TOUCH, TEST PLAN, ADR |
| `implementation_report` | the builder | CHANGED, BUILD, READY FOR |
| `validation_report` | test-strategy | INTENDED, TESTED, RESULT, VERDICT |
| `knowledge_entry` | context-management | an `F-###`/`D-###` id and a source |

The rules with teeth:
- `evidence_bundle` / `root_cause` — must carry a real `file:line` citation.
- `validation_report` — `VERDICT` ∈ PASS|CONDITIONAL|FAIL, and a **PASS must
  carry test counts** showing at least one test ran and none failed or errored
  (a bare "PASS", "0 tests" or "12 failed" with PASS → REJECT).
- `knowledge_entry` — must have an `F-###`/`D-###` id **and** a source.

## Maintaining it (the checker is itself test-first)
The checker is built RED→GREEN and guarded by tests:
```bash
python3 ~/.claude/skills/contract-check/check_contract_test.py
```
The suite also fills in each producing skill's output template and checks it
passes, so a renamed section in a skill fails here. If you add or change a
contract: change `CONTRACTS` and the producing skill's template together, add a
RED test first, keep the suite green. No secrets/PII in fixtures.
