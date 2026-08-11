---
title: The Dark Factory Beyond Software — Autonomous Innovation in Any Domain
type: reference
status: living
source: PWW Dark Factory process + Promise Theory (Bergstra & Burgess 2019); generalization thesis by M. Bacia, 2026-06-11
applies-to: strategy; domain-entry planning for non-software Dark Factories
---

# The Dark Factory Beyond Software

## TL;DR

The Dark Factory is not a software-development process. It is a **domain-general process for autonomous innovation and problem solving**: agents supply unbounded synthesis; the factory's product is *trusted* output; its rate limiter is **unforgeable evidence per unit time**. Software was the first domain because its evidence happened to be free — not because the method is about code.

> **The process is domain-invariant. What varies per domain is (1) the cost and latency of unforgeable evidence and (2) the reversibility profile of actions. Those two numbers — not the subject matter — determine how fast a domain's safe space can widen.**

Scope is limited only by **input context** (can the semantics be specified?) and the ability to give agents **eyes and hands** (can promises be observed, and effects be actuated?). Protein folding, rockets, reforestation — all are reachable; each requires building its own evidence infrastructure first.

## What is domain-invariant

Everything in [`operating-agents-promise-theory.md`](operating-agents-promise-theory.md) survives translation unchanged:

- Promises, observers, assessment; self-reports are never evidence
- The forgeability ladder (T1 mechanical / T2 measured-against-judged-standard / T3 irreducible judgment)
- Blind synthesis and the withheld holdout (the anti-Goodhart firewall)
- Decoy probes (run-time verifier qualification — "never trust a green you've never seen red")
- Substrate trust (trust attaches to a pinned configuration, never a brand)
- The two-axis autonomy model: safe autonomy = unforgeable evidence × reversibility
- The human role: legislator, judge, trust-anchor — never the execution loop

## Eyes and hands, formally

The colloquial scope condition — "can we give agents eyes and hands?" — maps exactly onto existing model terms:

- **Eyes = the assessment surface.** "You cannot verify a promise you cannot observe" already makes observability constitutive, not optional. Satellites and soil sensors are reforestation's Grafana; telemetry from a static-fire stand is rocketry's dashboard rendering live data.
- **Hands = `effect` transforms.** Every actuator inherits the full `pure | effect` analysis from the data-transform model: idempotency, compensation, reversibility classification, human gates on the irreversible.
- **Input context = the Product Owner stage.** Domain SMEs defining data contracts and validation rules. Crisp formal specs (binding affinity ≥ X) make a domain automate fast; fuzzy specs ("reforestation success") mean more T3 judgment and slower trust-widening.

## Why software was first — and what that predicts

Software is the domain where the environment hands you near-free, millisecond-latency T1 evidence (compilers, asserting tests, exit codes) and where most work is reversible pre-merge. Maximum autonomy at minimum verification cost. Other domains differ only in those two coordinates:

| Domain | Cheapest T1 evidence | Cost / latency | Reversibility |
|---|---|---|---|
| **Software** | test exit codes, schema validation | ~free, milliseconds | high (pre-merge) |
| **Protein folding** | wet-lab assay, crystallography | high, days–weeks | high (it's information) |
| **Rockets** | static fire, test flight | extreme | very low |
| **Reforestation** | survival rates, canopy growth | low (remote sensing) but **years** of latency | very low |

Because LLMs made *synthesis* cheap in every domain at once, the binding constraint everywhere is now **verification bandwidth, not synthesis bandwidth**. Therefore:

> **"Generalize the Dark Factory to domain X" = "build X's evidence infrastructure."** Simulators, assays, sensors, holdout institutions — the eyes and hands ARE the product of domain entry.

**The confirming precedent is protein folding itself.** The first scientific domain to be "agent-solved" was the one that already had a Dark Factory verification institution: **CASP is blind synthesis with a withheld holdout set** — predictors never see the unreleased structures they are judged against. AlphaFold did not just have a good model; it had a pre-built, Goodhart-proof evidence standard to earn trust against. Prediction: autonomous innovation lands next in domains that build their CASP first.

## The reality ladder — DTAP equivalents for the physical world

Software's dev → staging → acceptance → prod was never really about environments; it is a **reversibility gradient** — each rung trades fidelity for cheapness and undo-ability. Every physical domain needs its own ladder. The generic rungs:

| Rung | Software | Generic physical equivalent | Properties |
|---|---|---|---|
| 1 | **dev** | **Simulation / virtual reality** — pure model of the domain | Fully reversible, near-free iteration, unlimited parallelism. Fidelity is the limit. The simulator is the domain's "compiler." |
| 2 | **test / staging** | **Sandbox** — controlled synthetic environment | Real physics, synthetic context: lab bench, wind tunnel, greenhouse, testnet. Contained, repeatable, instrumented. |
| 3 | **acceptance** | **Isolated real-world experiment** — real materials, contained blast radius | Pilot plot, test range, canary deployment, phase-1 trial. Reality is present; consequences are fenced. |
| 4 | **prod** | **Real-world test / full deployment** | Irreversible. Human-gated regardless of evidence quality (Axis 2). |

Examples:

- **Rockets**: CFD + flight-dynamics simulation → component test stands / wind tunnel → static fire, suborbital test article → orbital flight.
- **Protein / drug**: in silico (folding, docking) → in vitro (assay) → in vivo / phase-1 → clinical use.
- **Reforestation**: growth + hydrology models → greenhouse / nursery → pilot plots → landscape-scale planting.

Rules that govern the ladder:

1. **Promotion between rungs is a gate.** Evidence standards for promotion are fixed *before* the work at rung N, not negotiated at promotion time. Trust earned at rung N is the admission ticket to rung N+1 — exactly the integration-branch → staging → main discipline, transplanted.
2. **The simulator is itself a promiser.** Its promise — "my physics matches reality" — must be qualified by detection, not inspection: sim predictions validated against real outcomes from rungs 2–4 are the simulator's RED step (see *Qualifying the verifier* in the promise-theory reference). The sim-to-real gap is not a nuisance; it is an unqualified verifier.
3. **Move work down the ladder, not up the trust.** Increasing a domain's autonomy means engineering more of the work to be provable at rungs 1–2 (better simulators, richer sandboxes) — the physical analogue of TDD converting judgment into mechanism. It never means trusting agents harder at rung 4.
4. **Each rung needs its own eyes.** A rung without an assessment surface produces no evidence and therefore no trust — running it is motion, not progress.

## Domain-entry checklist

To stand up a Dark Factory in a new domain:

1. **Semantics** (PO + SME): data contracts, validation rules, what counts as success — and how much of it is formally specifiable (the T3 share sets the autonomy ceiling).
2. **Evidence ladder**: per claim, the cheapest unforgeable signal and the chain of progressively cheaper proxies standing in for expensive ground truth.
3. **Reality ladder**: the domain's four rungs, with promotion gates and pre-fixed evidence standards.
4. **Eyes**: the assessment surface per rung — sensors, assays, telemetry, rendered and verified against live data.
5. **Hands**: the effect transforms, each classified for reversibility, with idempotency/compensation where engineerable and human gates where not.
6. **Holdout institution**: the domain's CASP — who holds the withheld acceptance set, and how is it kept blind from synthesizers?
7. **Decoy battery**: known-bad inputs for continuous, unannounced qualification of every agentic verifier in the loop.
8. **Substrate accounting**: pinned configurations, requalification on model/harness change.

## What stays human, in every domain

- **The PO problem does not generalize away.** "Is this the right protein target / the right forest / the right rocket?" is T3 in every domain.
- **Irreversible effects keep their human gate** regardless of evidence quality: launch, plant, release, dose.
- **Only the human trust-anchor widens the safe space.** Per-domain T3→T1 conversions (a new trusted assay, a newly qualified simulator) are acts of legislation, and each new mechanism must be shown to *reject* before it is trusted (RED-first).

## Relationship to the rest of `reference/`

- [`operating-agents-promise-theory.md`](operating-agents-promise-theory.md) — the domain-invariant operating model this document generalizes; the two-axis autonomy model, verifier qualification, and substrate trust are used here unchanged.
- [`data-transform-model.md`](data-transform-model.md) — `pure | effect` supplies the hands-side analysis; every physical actuator is an effect transform.
- [`observability-standard.md`](observability-standard.md) — the eyes-side standard; "verified rendering live data" applies to a soil-moisture dashboard exactly as to a service dashboard.
