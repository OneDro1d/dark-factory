---
title: Observability Standard — the agents' eyes
type: reference
status: living
honours: Prime Directives 1, 6, 7
---

# Reference: Observability Standard — the agents' eyes

## TL;DR

Observability is not platform garnish. It is the **sensory apparatus the agents use to build,
deploy and test**. Without a working dashboard and a queryable log/trace surface, QA cannot
prove a scenario ran, Operations cannot watch a saga propagate, and a developer debugs blind.

**Emitting telemetry is necessary and not sufficient.** A `/metrics` endpoint nobody can
*see* is not observability. This standard makes the **consumable surface** — dashboards,
queryable logs, correlation traces, and the proof they render live data — a named, verified
deliverable across SA, Infrastructure and QA, rather than an assumed boilerplate "delta".

> **Rule of thumb:** if an agent cannot answer *"did scenario TS-0x actually run, and where
> did it succeed or fail?"* by looking at one dashboard or running one query, the system is
> not observable yet — however many metrics it emits.

## The three legs — Emit → Surface → Act

| Leg | Question it answers | Owner stage | Required artifact |
|---|---|---|---|
| **Emit** | Is telemetry produced? | Developer, per [`service-anatomy.md`](service-anatomy.md) | metrics endpoint, structured JSON logs with `correlationId`, health endpoint, DLQ depth |
| **Surface** | Can a human or agent *see and query* it? | **SA designs · Infra builds · QA verifies** | **Dashboards + queryable log/trace views that render live data** — the historically missing leg |
| **Act** | Does it fire before customers notice? | SA names · Infra wires | Alerts → sink (Directive 6) |

*Emit* is reasonably reduced to a referenced platform default with deltas only. **Surface is
product-specific** and must be explicitly delivered and verified. That is the gap this
standard closes, and it is the leg that goes missing precisely because it is the only one
without a natural home in a single service's repo.

## Required baseline dashboard set — the floor, not the ceiling

Every product ships at minimum these views before QA can sign off. Panels are keyed to PO
test scenarios wherever a scenario maps to a flow.

| View | Must show | Why an agent needs it |
|---|---|---|
| **Flow / saga** | End-to-end path of each PO scenario: which stages propagated, completed, deferred or failed, with counts per state | Proves a scenario ran end to end — the primary eye for QA evidence and Ops |
| **Throughput** | Messages/requests per second per service and per queue | Confirms the system is doing work; the baseline for load tests |
| **Tiered failure log** | Errors and warnings filtered by the **log level field**, never by substring | Surfaces real failures without name-collision false positives |
| **Correlation / trace lookup** | A `$correlationId` variable pulling every log line and span for one request across all services | Lets QA capture per-scenario evidence by id, and a developer debug one failing path |
| **DLQ + queue depth** | Per-service dead-letter depth and live queue depth over time | Bulkhead health (Directive 8); a rising DLQ is the earliest failure signal |
| **Latency** | p50 / p95 / p99 per service, plus end-to-end for sync edges | SLO evidence and the QA quality-gate source |
| **System health** | Instance up/down, restarts, resource pressure, scrape target up | "Nothing unwatched" (Directive 1) — catches a service that never started |

A product with sagas or long-running workflows **must** have the Flow/saga view. A pure
request/response product may fold it into Throughput + Correlation — but must say so in an
ADR-style note rather than silently omitting it.

## The queryable surface

Dashboards answer "what is the system doing". The query surface answers "what happened to
**this one** request". Required:

- **Log query** — a backend reachable with `{service=...} | correlationId="..."` style
  queries, returning structured records across every service the request touched.
- **Trace lookup** — spans joinable by `correlationId`, injected and extracted at every
  message hop. Sample at 100% while the system is young; you cannot debug what you discarded.
- Both reachable **programmatically by the QA and developer agents in dev/test**, not only by
  a human logging into a production console.

## The acceptance bar — "verified rendering live data"

A dashboard whose JSON posts cleanly but shows "No data" is **not delivered**. The bar,
enforced at the Infrastructure exit gate and re-checked at the QA pre-test gate:

1. Every required view exists and is reachable at a known URL.
2. Every panel **renders live data** from the running system — verified against the
   datasource, not merely schema-validated.
3. The `$correlationId` query returns real cross-service results for at least one exercised
   request.
4. Every alert rule **evaluates**. A state of inactive/healthy is fine; "error" or "no data"
   is not.

> Verification is by **observation, not assertion**. The discipline QA applies to scenarios
> applies to the eyes themselves: "dashboards exist" without a rendered check is an
> unverified claim, and an unverified claim about the instrument invalidates every
> measurement taken through it.

<!-- ───────────── AI-AGENT CONTEXT BELOW ───────────── -->

## Per-stage ownership

| Stage | Observability obligation |
|---|---|
| **SA (2)** | Design the Observability Surface: name the required dashboards/panels, map each to a PO scenario, name the product-specific alerts and SLOs. Records this in the Service Map, not only as per-service metric deltas. |
| **Developer (3)** | Emit the telemetry the Surface consumes — Service Anatomy defaults plus the SA's named custom metrics and labels. |
| **Infra (4)** | Build and stand up dashboards, datasources and log/trace sinks, then **verify they render live data**. Ship dashboards **as code**, never hand-clicked. |
| **QA (5)** | **Pre-test gate:** confirm the eyes work before running scenarios. Broken eyes block the verdict, because evidence capture becomes impossible. Then use the surface as the evidence source. |
| **Ops (6)** | Consume the same surface at run time; alerts route to on-call. |

## Two lessons worth inheriting

**Filter failure panels by the log level field, not a substring.** A naive case-insensitive
`error` regex matches queue names, directory names and routing keys. One real build produced
**86 false positives an hour** that way, which is indistinguishable from having no failure
panel at all — worse, because it looks like one.

**Build the eyes before you need them, and they find bugs on day one.** A saga-flow +
correlation-trace dashboard built to this standard surfaced three real defects — a degraded
database falling back silently, validation schema gaps, and a warn-level log that should have
dead-lettered — none of which the emitted metrics alone would have shown.

## Anti-patterns — each forces a Fail at the owning gate

- **Emit-only** — the metrics endpoint exists, no dashboard renders it. QA cannot capture
  evidence. This is the gap the standard closes.
- **Schema-valid, no data** — the dashboard imports cleanly and every panel is empty.
- **Substring failure filters** — see above; the flood drowns the real errors.
- **Hand-clicked dashboards** — not in the repo as code, so not reproducible across
  environments and lost on the next cluster rebuild.
- **Human-only access** — a human can log into the console, but the QA and developer agents
  have no programmatic path in dev/test.

## See also

- [`service-anatomy.md`](service-anatomy.md) — the *Emit* leg, per-service telemetry surfaces.
- [`10-prime-directives.md`](10-prime-directives.md) — Directives 1, 6 and 7.
- [`8-implementation-patterns.md`](8-implementation-patterns.md) — Pattern 5.
- Your organisation layer — the concrete dashboard, log and trace stack, and its
  dashboards-as-code reference implementation.
