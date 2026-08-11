---
title: Operations Runbook — MedStream Ambulance AI (condensed sample)
stage: 6. Operations
type: operations-runbook
status: sample
---

# Operations Runbook — MedStream Ambulance AI (sample)

> Condensed end-to-end example of the must-have Operations output. Fictional product (ambulance clinical-data capture → cloud streaming → ML-assisted hospital pre-arrival summary).

## TL;DR

MedStream streams patient vitals and stroke-screen data from ambulances to the cloud during transport. The one thing to watch: **pre-arrival summary delivered before ambulance arrival** — if that SLO breaks, hospitals lose the head-start the product exists to provide.

## Service snapshot

| Service | Purpose | Cluster(s) | Health | Dashboard |
|---|---|---|---|---|
| `intake-api` | 202-accept ambulance streams | eks-dev02, eks-prod | `:8080/healthz` | grafana/medstream-intake |
| `vitals-classifier` | classify + validate vitals events | eks-prod | `:8080/healthz` | grafana/medstream-classify |
| `summary-builder` | build ML pre-arrival summary | eks-prod | `:8080/healthz` | grafana/medstream-summary |
| `handoff-notifier` | push summary to receiving hospital | eks-prod | `:8080/healthz` | grafana/medstream-handoff |

## SLOs

| SLO | Target | Source |
|---|---|---|
| Pre-arrival summary delivered before arrival | 99% of transports | TS-03 |
| Intake ack latency | < 500ms p95 | TS-01 |
| No duplicate events after connectivity drop | 100% | TS-02 |

## Operational knobs

| Knob | Action | How | Reversible? | Approval |
|---|---|---|---|---|
| Slow | rate-limit intake per ambulance | `settings.yaml intake.rate` reload | yes | none |
| Stop | pause classifier consumer | `fulcrum-ctl pause vitals-classifier` | yes | on-call |
| Redirect | route handoff to backup hospital endpoint | `fulcrum-ctl route handoff --to backup` | yes | **human** |
| Inspect | replay summary DLQ | `fulcrum-ctl dlq-replay summary-builder` | yes | none |

## Alert → response playbook

| Alert | Symptom | Likely cause | Diagnostic | Mitigation | Escalate when |
|---|---|---|---|---|---|
| `summary_late` | summary after arrival | ML latency / queue backlog | inspect summary queue depth | slow intake; scale summary-builder | > 5% transports in 10m → SEV1 |
| `dup_events` | duplicate vitals | idempotency key miss on resync | inspect correlationId dedupe metric | stop classifier; replay clean | any duplicate → SEV2 |
| `intake_5xx` | ambulances cannot stream | intake-api unhealthy | `:8080/healthz`, pod logs | redirect to standby region (**human**) | > 1% 5xx → SEV1 |

## Escalation

| Severity | Who | Channel | Approves irreversible |
|---|---|---|---|
| SEV1 | on-call → clinical-systems lead | #medstream-oncall | clinical-systems lead |
| SEV2 | on-call | #medstream-oncall | on-call |

## Loop-back

- `dup_events` recurring → SA: idempotency design flaw on resync path.
- Hospitals want summary 2 min earlier → PO: tighten SLO / re-scope.

<!-- ───────────── AI-AGENT CONTEXT BELOW ───────────── -->

## Secrets & rotation

| Secret | Used by | Source | Rotation |
|---|---|---|---|
| `HOSPITAL_FHIR_TOKEN` | handoff-notifier | AWS SM | 90d |
| `RABBIT_URL` | all | sealed-secret / SM | per cluster policy |

## Notes for the AI on-call agent

- PHI in flight — every inspect action logs to Armarium audit sink.
- Region redirect and any patient-data action = human approval.
