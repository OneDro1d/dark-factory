---
title: Data Flow — <Product Name>
stage: 2. Solution Architect
type: data-flow
status: template
consumes: PO test scenarios, Data Model
---

# Data Flow — <Product Name>

## TL;DR

<One paragraph: the headline path — what enters the system, the key transformation, and what the user/consumer gets out.>

## End-to-end overview

```text
<source> --in--> [intake] --AMQP--> [transform] --store--> [<db>]
                                          \--publish--> [read/notify] --out--> <consumer>
```

What comes **in** · how it's **transformed** · where it's **stored** · what comes **out** — one diagram for the whole system, then one path per scenario below.

## Path per PO scenario

One row per PO real-life test scenario. Each must have a path (Adversary checks coverage). Tag each transform `pure` or `effect`; every `effect` carries an idempotency key + compensation; every ingress validates its LOCAL rules before consuming a datum. See [`reference/data-transform-model.md`](../../../reference/data-transform-model.md).

| Scenario | In | Transform (services) | `pure`/`effect` | Idempotency + compensation (effects only) | Store | Out | Sync hops? |
|---|---|---|---|---|---|---|---|
| `<TS-01>` | <input> | `<svc-a>` → `<svc-b>` | effect | key=`<id>` · compensate=`<undo>` | `<db>` | <output> | none (all AMQP) |

## Message sequence (per key scenario)

```text
Client → intake-api: POST (202 + correlationId)        # async-first, Pattern 2
intake-api → [AMQP vitals.raw] → classifier
classifier → [AMQP vitals.classified] → summary-builder
summary-builder → store + [AMQP summary.ready] → notifier → hospital
```

<!-- ───────────── AI-AGENT CONTEXT BELOW ───────────── -->

## Pub/sub vs sync

Default is AMQP pub/sub (Directive 3) and async (Directive 4). List every sync hop with its ADR pointer and failure containment (timeout, circuit breaker, fallback).

| Hop | Sync? | ADR | Containment |
|---|---|---|---|
| `<a>→<b>` | no (AMQP) | — | — |

## Failure & replay paths

Per path: where DLQ catches failures, how replay works, what the operational "inspect" knob shows (feeds the Ops Runbook).

## Coverage check

Confirm: every PO scenario above appears, and every service in the Service Map participates in at least one path.
