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

## ⚠️ Gate the method too, not only the deliverable

Both checks above ask about the WORK. Neither asks whether the work was done **the way the
mission said to do it** — and that omission has its own silent failure mode, because a
directive that was never followed leaves the same trace as one that was: none.

When a mission record carries a **"What actually ran"** block (`Skill(vinculum-map)`), read it
as evidence and challenge it like any other:

- **Skills named by the binding but not loaded** — is the stated reason real, or is the block
  a copy of the binding's list? A block that lists exactly what was prescribed, with no skips,
  is *intent recorded as outcome* and should be trusted less than one admitting an omission.
- **Everything inline, nothing delegated** — check that against the judgment ladder in
  `Skill(df-dispatch-subagents)`. Pure enumeration or retrieval done at the top tier is a
  right-sizing miss, and it is usually invisible because the output is *correct*: the result
  looks the same, only the cost differs.
- **No block at all** — that is a finding, not an absence. Say so rather than passing.

⚠️ **Absence of evidence is not evidence of compliance.** Measured 2026-09-01: a session
invoked a binding naming six skills, loaded two, dispatched zero workers, and produced correct
work — green tests, green preflight, right files on disk. Nothing in any artefact recorded that
four directives were skipped. **Every check that looked at the output passed.**

⚠️ **And a declaration is not proof.** It shows a skill was *loaded*, never that it changed how
the work was done. Same class as a doc-move check: it catches the mechanical case; a reader
catches the rest. Do not let a filled-in block end the conversation.

## How to run a gate
1. Restate the **promise** and the **pre-declared evidence standard** (acceptance criteria fixed with the task, not negotiated now).
2. Demand the unforgeable evidence; if it's a self-report or self-produced artifact, mark **unverified**.
3. Prefer a **mechanism** over a judgment. If the verifier is itself an agent, its verdict is also a best-effort promise — use **independence + diversity** (an adversarial panel), never one agent vouching for another.
4. Verdict: an **outcome**, and for NOT KEPT a **reason**, each with the evidence cited — see below.

## The verdict — say WHY a promise was not kept, because the why picks the next move

"Fail" alone throws away the one fact the dispatcher needs next. CFEngine, which has run
promise-keeping agents at fleet scale for decades, splits every outcome the same way, and warns
that *"a promise is not simply 'OK' or 'not OK'"* ([masterfiles `results` body](https://docs.cfengine.com/docs/3.23/reference-masterfiles-policy-framework-lib-common.html)).

| Outcome | Means | Label | Next move |
|---|---|---|---|
| **KEPT** | the state already held; no work was needed | Pass | nothing to review — say so, and do not invent a diff to look at |
| **REPAIRED** | the work made it hold | Pass | review the change, which is what the evidence shows |
| **NOT KEPT: failed** | the promiser tried and the evidence disproves the promise | Fail | the spec or the approach is wrong — fix that, then re-dispatch |
| **NOT KEPT: denied** | the promiser was refused: a permission, a spend limit, a gate, a missing credential | Fail | not a quality problem — re-tier, grant, or escalate the refusal; re-running the same brief fails the same way |
| **NOT KEPT: timeout** | it hit its time or turn bound (`df-dispatch-subagents`, step 3) | Fail | re-dispatch narrower, or with a larger bound if the size was the misjudgment |
| **NOT KEPT: unverified** | a conclusion arrived without the evidence demanded | Fail | verify it yourself or re-dispatch with a tighter evidence ask — never read as negative |

**Partly kept is Conditional.** A promise with several parts can keep some and not others; name
the outcome of each part rather than averaging them. The label inflation rule below still
applies: a note with a "but" in it makes the label Conditional.

⚠️ The labels are unchanged on purpose — the stage gates and `df-ui-verify`'s verdict script
emit Pass / Conditional / Fail, and those stay valid. The outcome and reason are what a verdict
now adds, not a rename.

⚠️ **denied ≠ failed, and the difference costs real money.** Observed 2026-09-18: a retrieval
sub-agent died on the account's monthly spend limit. Read as *failed*, the obvious move is to
tighten the brief and re-run it — on the same tier, into the same limit. Read as *denied*, the
move is a cheaper tier, which is what worked.

## Gate the verdict itself, not only the work

The last gate audits the **verification package**: every row of a results table must trace to raw evidence the gate quotes back. Two failure shapes recur often enough to name, and both are produced by a competent verifier having a good day — they are not sloppiness:

- **Label inflation** — a row labelled PASS whose own note discloses a shortfall. **Rule: if the note contains a "but", the label is CONDITIONAL.** The label is what every downstream consumer reads; the note is what almost nobody does.
- **Unevidenced mitigation claims** — a Conditions or Risks section leaning on a reassurance ("the client is idempotent", "that path is unreachable") with no evidence pointer. **Rule: every mitigation claim carries a pointer** — a file, a `path:line` code citation, or a test name — and where the honest answer is "code-evidenced, not observed live", it says exactly that.

Apply the gate's notes (relabel, add the citations), commit the gate report **into** the evidence package, and only then declare the work closed. A gate report that is not in the package is a gate that can be quietly dropped.

## Per-stage gates
Use the matching stage skill's exit gate: `df-product-owner` (cold-SA / wrong-target), `df-solution-architect` (cold-Dev/Infra, coverage), `df-tdd-developer` (asserting tests green, `-race`), `df-qa` (evidence by correlationId, holdout), `df-infrastructure` (renders live data, no implicit trust), `df-observability` (verified rendering live data).

## Anti-patterns
Trusting self-reports · self-produced evidence (assertion-free tests, agent-controlled screenshots) · single-agent vouching · negotiating the evidence standard at verify time · leaking the acceptance cases to the worker.
