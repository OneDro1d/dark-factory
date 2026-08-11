---
title: Product Owner (What / Why) — Stage Guide
stage: 1. Product Owner
type: stage-guide
status: living
consumes: raw input context (the "Product Process", owned upstream)
produces: Vision, Requirements, Test Scenarios
---

# Product Owner (What / Why) — Stage Guide

## TL;DR

The Product Owner turns messy, unstructured intent into a self-contained, testable target. It produces **three must-have docs: Vision, Requirements, and Test Scenarios.** This is the highest-leverage stage — if the target is wrong, every downstream agent executes perfectly and still builds the wrong thing. The exit bar is the **cold Solution Architect test**: can an SA who knows nothing about the product design the right architecture from these three docs alone?

## Where this stage sits

`Inputs (Product Process) → **Product Owner** → Solution Architect → …`

## Inputs (the raw Product Process)

Owned upstream (at PWW/ESO, by MT / Rene's team — the board's "Product Process" lane). The PO consumes whatever exists:

notes · calls/recordings · emails · customer interviews · existing docs · current workflows · prior versions · support tickets · compliance inputs · data samples · mockups · similar-product examples.

The PO preserves source traceability but is **not** responsible for generating these inputs.

## Must-have outputs (the small list)

| Output | Purpose | Template |
|---|---|---|
| **Vision** | Why / what / who / business value — folds in problem statement, personas, and **non-goals** ("what this is not") | [`templates/vision-template.md`](templates/vision-template.md) |
| **Requirements** | Structured capabilities + acceptance criteria — folds in **MVP scope** and priority | [`templates/requirements-template.md`](templates/requirements-template.md) |
| **Test Scenarios** | Real-life situations that prove the product works — folds in the **Definition of Done** | [`templates/test-scenarios-template.md`](templates/test-scenarios-template.md) |

Test Scenarios are central: in a Dark Factory, tests are how the factory *knows* the product works. They drive the SA's Data Flow and QA's Test Plan directly.

## Optional outputs

- **User Stories** ([`templates/user-stories-template.md`](templates/user-stories-template.md)) — explicitly optional
- Prototype / mockup references; Glossary; Open-questions & decision log; Source-feedback traceability

## Exit gate

> **Cold SA test:** If this package goes to a Solution Architect who knows nothing about the product, business, prior versions, or domain, can they design the right architecture from Vision + Requirements + Test Scenarios alone?
>
> **Real-life test test:** If we built exactly this and ran these scenarios, would we know whether we solved the right problem?
>
> **Wrong-target test:** Is there any realistic way the factory could build the wrong thing while still satisfying this package? If yes, clarify before handoff.
>
> **Org NFR overlay (optional, org-supplied):** an organisation may bind an NFR checklist at
> this point. Where one is bound, its PO-owned rows (background, owners/leads, synopsis,
> milestones, criticality, data classification, continuity inputs) are surfaced in Vision /
> Requirements / Test Scenarios before SA handoff. The overlay itself is **Tier-2 content** and
> lives in the organisation's own repo — this tier defines only the hook.

<!-- ───────────── AI-AGENT CONTEXT BELOW ───────────── -->

## Through the data-transform lens

See [`reference/data-transform-model.md`](../../reference/data-transform-model.md). At this stage the model says **Requirements = data contracts + validation rules** and **Test Scenarios = those rules as cases.**

- Every requirement names its **data** (schema) and its **context**: `origin` (web form · mobile · scanned doc · 3rd-party API · another service), `authority` (who is system-of-record for this fact), `governance` (PHI/PII class, retention, residency). `origin` is for audit — **never** a trust signal.
- Every acceptance criterion is a **validation rule** — state the **predicate** and its **business scope** (holds within one record, or must agree across systems/time), plus the **`authority`** that wins on conflict where relevant. The SA assigns the formal enforcement locus (`LOCAL`/`GLOBAL`) and mechanism; you state what must be true, not where it is checked.
- The "State 0 → Trigger → State 1" framing below *is* the model's transform `(state, input) → (state', output)`. Mark any trigger that touches the outside world (send / charge / notify / write-external) as an **effect**, so the SA gives it idempotency + compensation.

## Ownership handoff (PO → SA)

The PO (with SMEs) owns the **semantics** — *what* data is collected, its `origin`, `trust`, `authority`, `governance`, and the **validation rules** (the business predicates). The SA owns the **formalization** — schemas, Avro data contracts, each rule's enforcement **locus** (`LOCAL`/`GLOBAL`) and **mechanism**, and `pure`/`effect` tagging with idempotency + compensation. In one line: **the PO states what must be true and who is authoritative; the SA decides where it is checked and how.** Deliver the semantics completely — that is exactly what the cold-SA test measures.

## Interaction mode

**Human-AI, interactive, iterative.** The human supplies judgment, business context, and priorities; the AI organises inputs, asks clarifying questions, drafts the three docs, and flags gaps. The human approves problem statement, MVP scope, non-goals, and scenarios before handoff.

## Why three docs (the 10→3 collapse)

The old PO stage spread one deliverable list across a manual, a contract, an ai-workflow, and an exit-criteria doc, plus 9 templates. Vision now absorbs problem/personas/workflow/non-goals; Requirements absorbs MVP/scope; Test Scenarios absorbs Definition of Done. Traceability, glossary, prototypes, and stories become optional. Same signal, a third of the surface.

## Workflow

1. **Gather** inputs; do not prematurely filter. Record provenance.
2. **Normalise** into shared context: product, users, current state, problem, desired outcome, value, constraints.
3. **Draft Vision** — including the "what this is not" non-goals (the single biggest scope-creep guard).
4. **Draft Requirements** — capability + user + priority + acceptance criteria; flag any requirement that is not testable.
5. **Write Test Scenarios** — concrete real-life situations (a paramedic in a moving ambulance with intermittent signal), not feature assertions. Include happy path, edge cases, failure modes.
6. **Label every claim:** Confirmed / Inferred / Assumption / Open question. Never silently invent product facts.
7. **Run Adversary PO review**, then pass the exit gate.

## Strong vs weak test scenarios

> Weak: "The app should stream ambulance data to the cloud."
>
> Strong: "A paramedic documents a suspected stroke patient in a moving ambulance with intermittent cellular connectivity. Vitals, stroke-screen responses, and timestamped interventions stream to the cloud; the receiving hospital sees a pre-arrival summary before arrival; if connectivity drops, local capture continues and cloud sync resumes without duplicate events."

The strong version gives the SA, Developer, QA, and Ops a concrete reality to design and test against.

**Frame every scenario as a state change:** State 0 (precondition) → Trigger (input data/action) → State 1 (end state). It is deterministic — given State 0 and the Trigger, State 1 is fixed — so QA validates it with a mechanical equality check, not a judgement call. This is the most efficient testing shape: every product behaviour is a state transition, and a state transition is trivially verifiable.

## Handoff to Solution Architect

Vision + Requirements + Test Scenarios + open questions + non-goals + adversary findings. No hidden tribal knowledge.

## PO Final Sign-off (loop closure)

The PO also owns the **Final Sign-off** gate at the end of the pipeline (board: between QA and Operations). When QA returns a Pass, the PO re-runs the cold-target test against QA's evidence: *do the captured results actually satisfy the original Test Scenarios and Definition of Done?* A Pass releases the system to Operations; a gap loops back to the owning stage. This is the same three docs used as the acceptance bar — no new artifact.

## Failure modes

- Requirements without business context; feature list without user workflow.
- Vision without test scenarios; scenarios that test screens, not real work.
- Missing non-goals; architecture assumptions disguised as product requirements.
- Silent AI-invented facts (use the Confirmed/Inferred/Assumption labels).

## References

- [`reference/data-transform-model.md`](../../reference/data-transform-model.md) — the lens: Requirements = data contracts + validation rules; Test Scenarios = those rules as cases
- [`01-adversary-product-owner.md`](01-adversary-product-owner.md)
