---
title: Product Owner Package — MedStream Ambulance AI (condensed sample)
stage: 1. Product Owner
type: po-package
status: sample
---

# Product Owner Package — MedStream Ambulance AI (sample)

> Condensed end-to-end PO package: the three must-have docs (Vision · Requirements · Test Scenarios) for the fictional MedStream product, in one file.

---

## 1. Vision

**TL;DR:** MedStream lets paramedics stream clinical data from a moving ambulance to the cloud so the receiving hospital has an ML-assisted pre-arrival summary before the patient arrives. Success = hospitals are ready before the doors open.

**Problem:** Receiving hospitals learn a patient's condition only on arrival, losing minutes that matter for time-critical conditions (stroke, MI, trauma).

**Who it's for:**

| Persona | Context | Need |
|---|---|---|
| Paramedic | moving ambulance, intermittent signal, hands-busy | fast, low-friction capture |
| ED charge nurse | receiving hospital | accurate pre-arrival picture |

**Business value:** Earlier hospital readiness → faster door-to-treatment for time-critical patients.

**What this is NOT:**

- Not a replacement for the hospital EHR.
- Not an autonomous diagnosis system (clinician oversight always).
- Not a consumer/patient-facing app.
- Not a billing or claims product.

---

## 2. Requirements

**MVP — In:** stroke + cardiac vitals capture, cloud streaming with offline resilience, ML pre-arrival summary to one hospital system (FHIR). **Out:** multi-hospital routing, non-cardiac/stroke protocols, analytics dashboards.

| ID | Capability | User | Priority | Acceptance criteria | Source |
|---|---|---|---|---|---|
| R-01 | Stream vitals to cloud | paramedic | must | vitals visible in cloud < 1s after capture | ride-along notes |
| R-02 | Offline capture + resync | paramedic | must | connectivity loss → local capture continues; resync produces **no duplicates** | EMS interview |
| R-03 | Pre-arrival summary to hospital | ED nurse | must | hospital receives summary **before** ambulance arrival | hospital interview |
| R-04 | Stroke-screen completeness check | paramedic | should | incomplete stroke screen flagged before arrival | clinical SME |

---

## 3. Test Scenarios

### TS-01 — Stroke patient, good signal
- **Situation:** paramedic documents a suspected stroke in a moving ambulance, normal cellular signal.
- **Flow:** capture vitals + stroke screen + timestamped interventions; stream to cloud.
- **Expected:** all events in cloud < 1s; hospital sees live picture.
- **Proves:** R-01, R-04.

### TS-02 — Connectivity drops mid-transport
- **Situation:** signal lost for 30s in a tunnel, then restored.
- **Flow:** capture continues locally during outage; resync on restore.
- **Expected:** all events arrive, **zero duplicates**, correct order.
- **Failure mode covered:** connectivity loss + resync.
- **Proves:** R-02.

### TS-03 — Pre-arrival summary
- **Situation:** 12-minute transport to the ED.
- **Flow:** full capture; ML builds summary; pushed to hospital FHIR.
- **Expected:** hospital receives the pre-arrival summary **before** arrival.
- **Proves:** R-03.

## Definition of Done

- [ ] TS-01 vitals stream < 1s, good signal
- [ ] TS-02 no duplicates after connectivity drop
- [ ] TS-03 pre-arrival summary before arrival

<!-- ───────────── AI-AGENT CONTEXT BELOW ───────────── -->

## Open questions / assumptions

- (Assumption) Single receiving-hospital FHIR endpoint for MVP — multi-hospital is out of scope.
- (Open) Retention period for PHI at rest — assumed 7y pending compliance confirmation.

## Handoff to SA

Vision + Requirements + Test Scenarios above, plus non-goals and the two open items. A cold SA can design from this: it yields MedStream's Data Model (PHI entities, dedupe key), Data Flow (one path per TS), and Service Map (4 services).
