---
title: Deployment & Infrastructure Spec — MedStream Ambulance AI (condensed sample)
stage: 4. Infrastructure Architect
type: deployment-infrastructure-spec
status: sample
---

# Deployment & Infrastructure Spec — MedStream Ambulance AI (sample)

> Condensed example of the must-have Infra output for the fictional MedStream product.

## TL;DR

MedStream runs on EKS Graviton for prod (HIPAA PHI residency in `us-east-1`), with on-prem `startrek`/`aequor` for dev parity. The constraint that drives everything: **PHI in flight and at rest** — encryption, audit, and segregation are non-negotiable.

## Cluster & overlay map

| Service | startrek | aequor | eks-dev02 | eks-prod-east1 | Notes |
|---|---|---|---|---|---|
| intake-api | ✓ | ✓ | ✓ | ✓ | ALB ingress on EKS |
| vitals-classifier | ✓ | ✓ | ✓ | ✓ | pure Go, multi-arch |
| summary-builder | ✗ | ✗ | ✓ | ✓ | needs GPU node pool (ML); EKS only |
| handoff-notifier | ✓ | ✓ | ✓ | ✓ | egress to hospital FHIR |

## Secrets

| Secret | Service | Source | Rotation |
|---|---|---|---|
| `HOSPITAL_FHIR_TOKEN` | handoff-notifier | AWS SM + IRSA | 90d |
| `RABBIT_URL` | all | sealed-secret (on-prem) / SM (EKS) | per policy |
| `ML_MODEL_KEY` | summary-builder | AWS SM + IRSA | 180d |

## Network posture

- **Ingress:** intake-api (mTLS, ambulance client certs); handoff-notifier not exposed (egress only).
- **Internal:** AMQP only.
- **Egress:** handoff-notifier → hospital FHIR endpoints, IP allow-list + mTLS.

## Storage

| Service | Storage class | Size | Backup |
|---|---|---|---|
| summary-builder | EBS gp3 (encrypted) | 50Gi | daily → encrypted S3 (SSE-KMS) |

## Observability sinks

Prometheus + Loki + OTel → CloudWatch (prod) / in-cluster (dev); Alertmanager → PagerDuty; Grafana `deployments/grafana/medstream/`.

## Operational knobs provisioned

| Service | Slow | Stop | Redirect | Inspect |
|---|---|---|---|---|
| intake-api | `settings.yaml intake.rate` | `fulcrum-ctl pause intake` | standby region route | log stream |
| summary-builder | HPA max cap | `fulcrum-ctl pause` | n/a | `dlq-replay summary-builder` |
| handoff-notifier | n/a | drain | backup hospital endpoint (**human**) | replay handoff DLQ |

## Runtime trust enforcement

| Service | Identity | Roles | Data class | Revocation |
|---|---|---|---|---|
| handoff-notifier | IRSA `medstream-handoff` | FHIR egress only | PHI | disable SA + network policy |
| summary-builder | IRSA `medstream-summary` | S3 model bucket RO | PHI | disable SA |

## Deploy procedure (for QA)

```text
1. kubectl apply -k overlays/eks-dev02
2. verify :8080/healthz on all 4 services
3. confirm Prometheus + Loki receiving; check Grafana medstream board
4. hand QA the cluster
```

<!-- ───────────── AI-AGENT CONTEXT BELOW ───────────── -->

## Compliance posture

HIPAA: EBS + S3 encryption (AES-256/KMS), 6y audit retention, PHI segregation per service, immutable-ledger audit for any ML recommendation that influences clinical handoff.

## Notes

summary-builder breaks multi-arch parity (GPU/EKS only) — ADR-MED-04 justifies the deviation.
