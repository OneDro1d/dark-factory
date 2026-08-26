---
name: df-adversary-gate
description: 'Run the adversary gate: assess whether presented evidence proves a promise was kept, without redoing the work and never trusting a self-report. Use before trusting any "done/passing" claim, PR, or handoff. Triggers on "adversary review", "verify", "gate", "assess evidence", "is this really done".'
---

# Dark Factory — Adversary / Verification Gate

## Overview
Every stage handoff is a **promise**; every gate is an **observer**. The agent that did the work is the *promiser*; whether the promise was kept is decided by the *observer*, never the promiser. This skill is the reusable verification primitive used at every gate.

## The verification primitive
An agent does the work, **declares the promise kept, and presents evidence**. The verifier validates **only** that the evidence proves the promise — it does **not** redo the work. That asymmetry is what lets one observer police many workers (verifying is cheap; doing is expensive).

> **Trust the evidence *less* than the promise.** Evidence the promiser fully controls is weak evidence. Demand evidence that is **independent and unforgeable** — produced by the *environment* or *another agent*, never solely by the promiser (exit codes from asserting tests, dashboards rendering live data, reconciliation vs an external authority, immutable audit entries — not a self-printed "PASSED").

## Blind synthesis (anti-Goodhart)
Independence of the verifier is necessary but not sufficient: the **worker must not have seen the acceptance cases**, or it games the test (`if input == known_case: return known_answer`). The acceptance/holdout set is withheld from the builder; verify against cases it never saw.

## Two checks, never conflated
1. `evidence ⊢ promise P` — was the declared promise kept? (the verifier's job)
2. `P = the needed promise` — was it the right promise? (guaranteed upstream by correct specification, not derivable from the evidence — a perfectly-kept *wrong* promise still fails the mission).

## How to run a gate
1. Restate the **promise** and the **pre-declared evidence standard** (acceptance criteria fixed with the task, not negotiated now).
2. Demand the unforgeable evidence; if it's a self-report or self-produced artifact, mark **unverified**.
3. Prefer a **mechanism** over a judgment. If the verifier is itself an agent, its verdict is also a best-effort promise — use **independence + diversity** (an adversarial panel), never one agent vouching for another.
4. Verdict: Pass / Conditional / Fail, with the evidence cited.

## Gate the verdict itself, not only the work

The last gate audits the **verification package**: every row of a results table must trace to raw evidence the gate quotes back. Two failure shapes recur often enough to name, and both are produced by a competent verifier having a good day — they are not sloppiness:

- **Label inflation** — a row labelled PASS whose own note discloses a shortfall. **Rule: if the note contains a "but", the label is CONDITIONAL.** The label is what every downstream consumer reads; the note is what almost nobody does.
- **Unevidenced mitigation claims** — a Conditions or Risks section leaning on a reassurance ("the client is idempotent", "that path is unreachable") with no evidence pointer. **Rule: every mitigation claim carries a pointer** — a file, a `path:line` code citation, or a test name — and where the honest answer is "code-evidenced, not observed live", it says exactly that.

Apply the gate's notes (relabel, add the citations), commit the gate report **into** the evidence package, and only then declare the work closed. A gate report that is not in the package is a gate that can be quietly dropped.

## Per-stage gates
Use the matching stage skill's exit gate: `df-product-owner` (cold-SA / wrong-target), `df-solution-architect` (cold-Dev/Infra, coverage), `df-tdd-developer` (asserting tests green, `-race`), `df-qa` (evidence by correlationId, holdout), `df-infrastructure` (renders live data, no implicit trust), `df-observability` (verified rendering live data).

## Anti-patterns
Trusting self-reports · self-produced evidence (assertion-free tests, agent-controlled screenshots) · single-agent vouching · negotiating the evidence standard at verify time · leaking the acceptance cases to the worker.
