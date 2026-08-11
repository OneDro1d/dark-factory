---
title: The Data-Transform Model
type: reference
status: living
source-of-truth: this repo (markdown). Confluence pages are summaries.
applies-to: all six stages (Product Owner → Operations)
---

# The Data-Transform Model

## TL;DR

An application is **not** a machine with levers and buttons that "does things." It is a **data-transformation algorithm**: input data, output data, and transforms that turn one into the other while carrying state forward in time. The machine/user-story mental model is sometimes useful but it hides where the engineering risk actually lives.

Modelling a system this way collapses the design space, which is exactly why it makes AI-generated docs and code dramatically better: requirements and tests become **data contracts + validation rules**, architecture becomes **schemas + transforms + state changes**, the platform architecture is **locked** (see `reference/`), and **reference implementations** already exist. The agent is left to fill a small, well-bounded gap — so it produces focused, correct output instead of inventing structure.

The whole model is **two primitives + two cross-cutting tags**:

| Element | What it is |
|---|---|
| **Data node** | A schema + its single-datum invariants, carrying context: `location`, `origin`, `authority`, `governance`. |
| **Transform** | `(state, inputs) → (state', outputs)`, tagged `pure \| effect`. Effects carry an idempotency key + a compensation path. |
| **Validation rule** *(tag over data)* | A predicate that must hold. `LOCAL` → reject at the edge. `GLOBAL` → flag, then resolve by authority. |
| **Authority** *(tag over a fact)* | The source-of-truth ranking that decides who wins when a global rule fails. Drives reconciliation. |

Everything else you already do — sagas, security gates, reconciliation, trust boundaries — is **composition or a tag**, not a new concept.

## The one distinction that earns its keep: `pure` vs `effect`

Mechanically, *everything* a computer does is data transformation — even "send email" is just publishing bytes from one server to another. That reduction is true but lossy in **one** dimension that decides correctness: **reversibility**.

- A **pure** transform is replayable. Recompute it a thousand times → same result, no harm. No marker needed.
- An **effect** changes the world outside your boundary and **cannot be retracted** by any transform of your state. Sending the email, charging the card, writing to an external ledger.

The proof this distinction is real and not philosophy: **idempotency keys, at-least-once delivery, and saga compensation exist only because effects are not reversible transforms.** If "send" were genuinely just a transform, retry would be free and nobody would have invented idempotency keys. So:

> Tag every transform `pure` or `effect`. `pure` gets a schema and moves on. `effect` gets an **idempotency key** (so retry ≠ double-action) and a **compensation path** (the hand-written un-transform). That is where all the engineering goes.

## Data context — the four fields, and why trust is not origin

A data node carries four pieces of context. They behave differently, so keep them separate:

| Field | Meaning | Travels with the datum? | Is it a trust signal? |
|---|---|---|---|
| `location` | Which store/system holds it **now**. | no | no |
| `origin` | Where it **came from** (system, document, API, screen, scan). | **yes** (for audit) | **NEVER** |
| `authority` | Is this the **system of record** for this fact? A ranking. | n/a (per fact) | it is the *conflict* signal |
| `governance` | Security class, retention, residency, who may read. | **yes** | n/a |

Two rules fall out of this, and they are the heart of the model:

1. **The boundary *is* the data.** Every input edge of every unit — function, service, database, queue — is a boundary. Data crossing **in** is untrusted until validated **here**. Trust is **not transitive and does not travel**: service A validating its input does not let B trust A's output; B re-validates at its own edge. The moment a `trusted` tag becomes sticky, you have rebuilt the "internal is safe" mistake one layer down. Origin travels for audit; **trust is re-earned at every crossing.** Your own services can be corrupt; a message off your own bus still gets validated.

2. **Authority ≠ origin.** A third-party bank balance can be *both* well-formed *and* the authoritative truth that overrides your own well-formed cached copy. "Ours vs theirs" carries zero trust signal. The source of truth for a fact is declared, per fact (`account.balance → the upstream provider is SoR; our DB is a replica`), and authority is what decides who is corrected when copies disagree.

## Validation rules — one genus, split only by enforcement locus

What we casually call "invariants" are just one species of **validation rule** — the genus that also covers a parity bit, a regex, a Schematron file, a NEMSIS medical-data validator, and double-entry accounting. A validation rule is a **predicate over some scope of data that must hold.**

The only parameter that changes your architecture is **enforcement locus** — *can this rule be checked at a single point, with all the data it ranges over present there?*

| | LOCAL | GLOBAL |
|---|---|---|
| **Scope** | field · record · single transaction | across records · across systems · across time |
| **Checkable at one edge?** | yes — all operands present at the crossing | no — operands live in different systems / arrive at different times |
| **Examples** | parity bit, type/regex, `balance ≥ 0`, Schematron, NEMSIS, debits==credits *within* a txn | our ledger == exchange balance, sub-ledgers == master, settlement vs custody |
| **On failure** | **reject at the door** | **flag, then resolve by authority** (reconciliation) |

Note double-entry straddles the line by scope: *within* one transaction it is LOCAL (assert at commit); *across* systems it is GLOBAL (reconcile). Same principle, two loci. That is the proof the useful axis is locus, not the rule's content.

Consequence: **validate-at-every-edge handles ~90% of correctness for free** (all LOCAL rules reject synchronously). Reconciliation loops exist only for the irreducible GLOBAL remainder that no edge can see — and those are exactly the ones that need `authority`.

## Why this is a force-multiplier for the Dark Factory

The model is the conceptual spine the pipeline already implies. Stated explicitly, it **bounds the AI's decision space at every stage** — which is the entire reason AI-generated docs and code get better, not worse, the more rigorously you specify:

| You lock down… | …so the agent no longer has to invent… |
|---|---|
| Data contracts (schema + context) | the shape, source, trust, and governance of every input/output |
| Validation rules (local/global) | what "correct" means and where to enforce it |
| Transforms tagged `pure \| effect` | which steps need idempotency + compensation |
| Authority rankings | how to resolve conflicts / what reconciliation asserts |
| Platform architecture (`reference/`) | messaging, observability, trust, bulkheading — already non-negotiable |
| Reference implementations | the idiom for a transform / service |

When all six are fixed, the only freedom left is *filling a small, typed gap*. A small decision space is what makes a focused, high-quality generation possible.

<!-- ───────────── AI-AGENT CONTEXT BELOW ───────────── -->

## How to apply the model when generating each stage's artifacts

Use this as the lens. Do **not** restate the model in stage docs — reference it and apply its vocabulary.

| Stage | The model says the must-have output IS… |
|---|---|
| **1. Product Owner** | A set of **data contracts** (each input/output: schema + `origin`/`authority`/`governance`) and the **validation rules** over them. "Requirements" = the data and the predicates that must hold. "Test Scenarios" = those validation rules expressed as cases (LOCAL → unit/contract tests that reject; GLOBAL → reconciliation/E2E checks). |
| **2. Solution Architect** | The **transform graph**: data nodes (Data Model), the transforms between them tagged `pure \| effect` (Data Flow), and which unit owns each transform (Service Map). The Runtime Trust Profile is just the `origin`/`authority`/boundary tags made explicit. State changes are `(state, in) → (state', out)` transitions, not "actions." |
| **3. Developer** | **Reference implementations of transforms.** Each service implements its transforms; `effect` transforms must ship an idempotency key + compensation; every ingress applies its LOCAL validation rules before consuming a datum. |
| **4. Infrastructure Architect** | **Where data lives and where the boundaries are.** `location` per data node, the trust boundary at every unit edge, residency/`governance` enforced by placement. |
| **5. QA** | **Validation rules executed.** LOCAL rules → tests that must reject bad input at the edge; GLOBAL rules → reconciliation tests across systems/time. A test that asserts nothing about a validation rule protects nothing. |
| **6. Operations** | **Invariant monitoring + reconciliation.** GLOBAL validation rules become live checks; failures resolve by `authority`. Incidents are usually a transform that lost an invariant or an effect that ran without idempotency/compensation. |

## Worked example — `chargeCard` through the model

```
data:    Payment { amount: Decimal≥0, currency, ... }          # schema + single-datum invariant
context: amount  ← internal order   (origin=internal-order, authority=us,        governance=normal)
         card    ← Stripe vault      (origin=stripe,         authority=stripe,    governance=PCI, vault-only)

transform: chargeCard(state, Payment) → (state', Receipt)
           kind:         EFFECT                                  # irreversible — cannot un-charge by a state transform
           idempotency:  order_id                               # retry ≠ double-charge
           compensation: refund(Receipt)                        # the hand-written un-transform
           guard:        order.approved == true                 # authz/approval gate, concentrated on the effect
           ingress:      validate(Payment) — LOCAL, reject if amount<0 or currency∉allowed

invariant: Σ receipts == Σ ledger debits                        # GLOBAL validation rule
           on-fail → reconcile, authority = payment-processor   # processor is SoR for "did the charge happen"
```

Every hard part — idempotency, compensation, the reconciliation check, the approval gate — hangs off `kind: EFFECT` and the GLOBAL rule. The `pure` parts need almost no spec. The model **concentrates attention exactly where the risk is**; user-stories spread it evenly.

## Anti-patterns the model is designed to kill

- **Sticky trust.** A `validated`/`trusted` flag that travels downstream so consumers skip their own ingress validation. Trust is re-earned per edge.
- **Origin-as-trust.** "It's from our own service, so it's safe." Internal can be corrupt.
- **Authority-by-convenience.** Treating your cached copy as truth because it is local. Declare the SoR per fact and reconcile toward it.
- **Effects modelled as pure outputs.** Treating "send / charge / write-external" as just another output column — discovered only when a retry double-acts. If it can't be safely replayed, it is an `effect` and needs idempotency + compensation.
- **Validation by location guess.** Trying to enforce a GLOBAL rule at a single edge (it can't see all operands), or deferring a LOCAL rule to an async reconcile (reject it at the door instead).

## Relationship to the rest of `reference/`

This is the **lens**; the others are the **fixtures** it focuses on:

- [`10-prime-directives.md`](10-prime-directives.md) — platform non-negotiables; several are this model in directive form (validate at the boundary, idempotent consumers, append-only).
- [`8-implementation-patterns.md`](8-implementation-patterns.md) — the idioms that implement `pure`/`effect` transforms and reconciliation.
- [`service-anatomy.md`](service-anatomy.md) — a service is a unit: its edges are boundaries, its handlers are transforms.
- An org-supplied NFR overlay (Tier-2) — many NFRs are GLOBAL validation rules with an authority and an SLO.
