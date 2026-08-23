---
name: df-infrastructure
description: 'Dark Factory Infrastructure stage: produce the Deployment and Infrastructure Spec — DTAP placement, where data lives, trust boundaries mapped to enforcement mechanisms, secrets, and a verified observability surface. Triggers on "infrastructure", "deployment", "trust boundary", "where data lives", "deploy across environments".'
---

# Dark Factory — Infrastructure Architect (where data lives + the boundaries)

## Overview
Infra decides **where** the architecture runs and makes it deployable across all environments. It produces one must-have output: the **Deployment & Infrastructure Spec**. Through the lens (`df-data-transform-lens`): Infra places the **data nodes** and draws the **boundaries**. Runs in parallel with the Developer lane.

## When to use
Deploying across DTAP, provisioning clusters/secrets/network/storage, wiring observability sinks + operational knobs, or enforcing runtime trust.

## What Infra does
- **`location` per data node** → storage class, region, residency. The `governance` tag (PHI/PII, residency) is enforced by **where** you put the data.
- **Every unit edge is a trust boundary.** "Inside the cluster is trusted" is the sticky-trust anti-pattern. Secrets/IAM enforce the boundary, not network position. Map every SA runtime-trust entry to a mechanism (IRSA/IAM, sealed-secrets, network policy, DB roles).
- **Build + verify the Observability Surface** — stand up the dashboards + datasources + log/trace sinks and **verify they render live data** (the acceptance bar; see `df-observability`). Ship dashboards **as code** (`deployments/grafana/…`), not hand-clicked.
- **Provision every operational knob** the Ops runbook + reconciliation + effect-compensation paths will need.

## Reversibility (the autonomy gate)
Building manifests is reversible and high-autonomy; **applying them to production is irreversible** → a **human gate** regardless of how green the evidence is (see `df-adversary-gate` / the two-axis autonomy model). A production change requires a ticket + announcement.

## Instructions
1. Start from the platform's standard environment progression (Dev → Test → Acceptance → Production), base + overlays. Record per-product **deltas** only.
2. Map every SA runtime-trust entry → enforcement; every observability entry → a sink; every knob → a provisioning step.
3. Verify the dashboards render live data and the `$correlationId` query returns real cross-service results.
4. Write the deploy procedure QA follows to stand the system up.

## Exit gate
Every service has an overlay per target cluster; every secret a source + rotation; every alert a sink; every knob a provisioning step; no implicit trust; ≥3 replicas on data-path services; the Observability Surface verified rendering live data. Independent of the Developer lane.
