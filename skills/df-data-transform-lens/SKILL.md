---
name: df-data-transform-lens
description: Model any system as data nodes (schema, origin, authority) and transforms tagged pure|effect, governed by validation rules and an authority that resolves conflicts. The shared frame the other df-* skills build on. Triggers on "data contract", "data flow", "validation rule", "transform", "pure or effect", "authority", "system of record".
---

# Dark Factory — The Data-Transform Lens

## Overview
An application is not a machine with features; it is a **data-transformation algorithm**: input data → transforms → output data, carrying state forward in time. Modelling a system this way collapses the design space and concentrates effort where the risk actually lives. Every other `df-*` skill is this model applied at one stage.

## The model: two primitives + two tags

- **Data node** = a schema + its single-datum invariants, carrying context:
  - `location` — which store/system holds it now (not a trust signal).
  - `origin` — where it came from (web/mobile/scan/API/another service). Travels for audit; **never** a trust signal.
  - `authority` — is this the system-of-record for this fact? A ranking; the conflict resolver.
  - `governance` — security class, retention, residency. Travels with the datum.
- **Transform** = `(state, inputs) → (state', outputs)`, tagged:
  - `pure` — replayable, no marker needed.
  - `effect` — irreversible world-change (send / charge / publish / notify / external write). **Must** carry an **idempotency key** (retry ≠ double-action) + a **compensation** path (the hand-written un-transform).
- **Validation rule** (tag over data) = a predicate that must hold. The only axis that changes architecture is **enforcement locus**:
  - `LOCAL` — checkable at one ingress/commit with all operands present → **reject at the door**.
  - `GLOBAL` — ranges across records/systems/time → **flag, then reconcile by `authority`**.
  - "Invariants" are just one species; the genus also covers parity bits, regex, Schematron, NEMSIS, double-entry.
- **Authority** = the resolution policy a GLOBAL failure appeals to (who wins on conflict; drives reconciliation).

## Two rules that are the heart of the model

1. **The boundary is the data.** Every input edge of every unit (function, service, DB, queue) is a boundary. Data crossing in is untrusted until validated **here**. Trust is **non-transitive and does not travel** — re-earned at every crossing. Your own services can be corrupt; a message off your own bus still gets validated.
2. **Authority ≠ origin.** A 3rd-party (bank, exchange) can be the authoritative source-of-truth that overrides your own well-formed cached copy. "Ours vs theirs" carries zero trust signal.

## The `pure | effect` distinction earns its keep
Mechanically everything is data transformation — but the reduction loses **reversibility**. Proof it's real: idempotency keys, at-least-once delivery, and saga compensation exist **only because** effects are not reversible transforms. Tag every transform; `pure` gets a schema and moves on, `effect` gets idempotency + compensation. That is where all the engineering goes.

## Every stage is this model
- **PO** = data contracts + validation rules (`df-product-owner`).
- **SA** = the transform graph (`df-solution-architect`).
- **Dev** = transform implementations, test-first (`df-tdd-developer`).
- **Infra** = where data lives + boundaries (`df-infrastructure`).
- **QA** = validation rules executed (`df-qa`).
- **Ops** = invariants monitored + reconciled.

## Anti-patterns
- **Sticky trust** — a `trusted` flag that travels downstream so consumers skip their own ingress validation.
- **Origin-as-trust** — "it's from our own service, so it's safe." Internal can be corrupt.
- **Authority-by-convenience** — treating the local cache as truth because it's local.
- **Effects modelled as pure outputs** — discovered only when a retry double-acts.
- **Validation by location guess** — enforcing a GLOBAL rule at one edge, or deferring a LOCAL rule to async reconcile.
