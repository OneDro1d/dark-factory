# Agent Contracts — the data-transform view of the pipeline

> **Why this file exists.** The agent pipeline hands a structured artifact from
> each agent to the next. This file makes those hand-offs **checkable data
> contracts** instead of prose conventions, tags each agent a **pure** or
> **effect** transform, and states the **validation rule** a consumer applies
> before it trusts an upstream result. Companion to `agents/README.md` (which says
> *who runs when*); this says *what a valid hand-off looks like and when to reject
> one*. Executable mirror: `.claude/skills/contract-check/check_contract.py`.

## The pipeline as a transform graph

Model the system as **data nodes** (the artifacts + the context store) flowing
through **transforms** (the agents). Each transform is `pure` (reads only, changes
no world state — safe to re-run, safe to discard) or `effect` (writes code /
memory / git — needs idempotency + a compensation path).

```
requirement / symptom
      │
      ▼  investigator (pure) ─────────► Evidence Bundle
      ▼  root-cause-analyzer (pure) ──► Root Cause
      ▼  feature-architect (pure) ────► Design Spec  (incl. the RED test list)
      ▼  implementer (EFFECT) ────────► Implementation Report  (+ code diff)
      ▼  validator (EFFECT, adversarial) ► Validation Report (verdict + evidence)
      ▼  knowledge-keeper (EFFECT) ───► Knowledge Entry → FINDINGS/DECISIONS/MAP
```

| Transform | Kind | Idempotency | Compensation (undo / on failure) |
|---|---|---|---|
| investigator | pure | re-run yields same bundle | none needed (no writes) |
| root-cause-analyzer | pure | same evidence → same cause | none needed |
| feature-architect | pure | same requirement → same spec | none needed |
| implementer | **effect** | re-run must not double-apply (check before edit; migrations idempotent) | revert the diff; never pushed without approval |
| validator | **effect** | tests deterministic; re-run = same verdict | delete scratch fixtures; no commit |
| knowledge-keeper | **effect** | **upsert by id** — update existing `F-###`/`D-###`, never append a duplicate | remove the entry if later disproven; cite source on every write |

**Authority (source of truth) the agents must not relitigate.** These live in this
repo's `DECISIONS.md` and bind the *data*, not just the code — e.g. which store is
system-of-record, fail-safe defaults (default to the restricted class), the
transport/IPC rule, where relationships live. A transform that would move authority
off a node of record **blocks and escalates** rather than "fixing" it silently.

## The validation rule (LOCAL reject — "escalate, don't guess", mechanised)

> A consuming agent **rejects an incomplete hand-off and kicks it back** rather
> than proceeding on a partial promise. This is the data-transform lens' *LOCAL
> reject* applied at every seam. `check_contract.py` makes it runnable.

| Contract | Producer → Consumer | Required sections | Rule (beyond presence) |
|---|---|---|---|
| `evidence_bundle` | investigator → analyzer | SYMPTOM, SCOPE, FLOW, EVIDENCE, RULED OUT, CANDIDATE FAILURE POINTS, UNKNOWNS, PRIOR FINDING | ≥1 `file:line` citation |
| `root_cause` | analyzer → architect | ROOT CAUSE, MECHANISM, EVIDENCE BASIS, BLAST RADIUS, FIX OPTIONS, CONFIDENCE | MECHANISM cites `file:line`; CONFIDENCE ∈ high\|med\|low |
| `design_spec` | architect → implementer | FEATURE/FIX, ACCEPTANCE, APPROACH, FILES TO TOUCH, TEST PLAN, ADR | TEST PLAN present **before** code (test-first) |
| `implementation_report` | implementer → validator | CHANGED, BUILD, READY FOR | — |
| `validation_report` | validator → human/keeper | INTENDED, TESTED, RESULT, VERDICT | VERDICT ∈ PASS\|CONDITIONAL\|FAIL; **a PASS must carry test-count evidence** |
| `knowledge_entry` | keeper → context store | (id line) | carries an `F-###`/`D-###` id **and** a source |

```bash
python3 .claude/skills/contract-check/check_contract.py validation_report report.txt
# OK     → consume it
# REJECT → kick back to the producer with the listed gaps
```

## Test-first seam (RED → GREEN → REFACTOR)

The `design_spec` carries the acceptance criteria as a **RED test list**; the
implementer's promise is "make these RED tests GREEN **without weakening them**,"
and the validator owns REFACTOR-safety + the adversarial holdout. The test list is
*derived from* ACCEPTANCE — never invented at validation time.

## Promise-theory verification (no agent is its own auditor)

1. **Unforgeable evidence — re-run, don't trust.** A consumer does not accept
   "VERDICT: PASS" or "all green." It requires the literal evidence (test output
   with pass/fail counts, real `file:line`) and **re-runs it**. `check_contract.py`
   enforces the floor: a PASS without counts is `REJECT` (UNVERIFIED).
2. **Blind adversary.** The agent that authored the acceptance tests is **not** the
   sole judge. The validator derives its **own** holdout and tries to **refute** the
   change; it must not simply re-run the implementer's tests. (Pattern: *three-layer
   audit chain — no single agent is its own auditor*.)

---
_Companion: `agents/README.md` (routing) · `context/README.md` (read-first store)
· `skills/contract-check/` (the executable checker). Keep this terse; one rule per
row, cite a source, no prose drift._
