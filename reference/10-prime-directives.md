# Reference: The 10 Prime Directives

Ten non-negotiable governing principles. They apply to humans and AI agents equally, and they
are ranked: when two of them pull in opposite directions, the lower number wins. Derived from
Richardson's *Microservices Patterns* and refined through production operation of a
message-driven estate.

The Solution Architect applies every directive to the architecture being designed. A
deviation is legitimate — an *undocumented* deviation is not. Deviations need an ADR naming
the alternative posture.

| # | Directive | What it means in practice |
|---|---|---|
| 1 | **Nothing unwatched exists** | Ship telemetry with every workflow. See it before customers report it. |
| 2 | **Produce it — publish it. Consume it — consume all of it** | No private side agreements. Filter client-side. |
| 3 | **Pub/sub by default** | Event-driven communication. Durable messages over tight coupling. |
| 4 | **Async by default; sync only when unavoidable** | Sync only when truly needed, with contained failure modes. |
| 5 | **Trust must be explicit, scoped, and observable** | Never assume access. Implicit trust is a vulnerability. |
| 6 | **If customers report it first, we have already failed** | Surprise is the failure. Monitoring tells us first. |
| 7 | **Observability over performance** | Accept the overhead to remove blind spots. |
| 8 | **Siloing/bulkheading by design** | Failure domains must be separable. No bulkheads is an architectural failure. |
| 9 | **All execution under an explicit trust profile** | Inspectable, limitable, revocable trust envelopes. Policy updates the profile, not code. |
| 10 | **Operational knobs must be exposed** | Slow, stop, redirect, inspect — without editing code in a panic. |

## How to apply at the Solution Architect stage

For each directive, answer three questions:

- **Where in the architecture is this honoured?** Point at a service, a message flow, a
  deployment artifact, an observability entry. "Everywhere" is not an answer.
- **Where might it be violated?** Any sync call, any unobserved background task, any shared
  trust boundary.
- **If deviated, is the deviation ADR-justified?**

### Directive 1 — Nothing unwatched exists

Every service in the Service Catalogue has a metrics endpoint with documented names and
labels, structured logs carrying `correlationId`, a health endpoint, and a documented set of
alerts with named conditions.

And the **system** has an **Observability Surface** — the dashboards and queryable log/trace
views an agent actually *looks at* — built as code and **verified rendering live data**.
Emitting metrics no dashboard renders is *emission*, not observability. See
[`observability-standard.md`](observability-standard.md).

A workflow with no observability fingerprint — telemetry **and** an eye to see it — violates
Directive 1 even if every service has a `/metrics` route.

### Directive 2 — Produce/publish, consume all

Publish every event; let consumers filter. Do not pre-filter at the producer based on the
consumers you happen to know about — that is a private side agreement, and it silently
becomes a coupling the next consumer cannot see.

Two services with a side channel others cannot subscribe to is a Directive 2 violation.

### Directive 3 — Pub/sub by default

Inter-service communication is durable topic-based messaging with a schema. A new service
subscribes to existing exchanges and publishes to existing exchanges rather than opening a
new point-to-point path.

The Service Map shows which paths are sync. Sync paths are the exceptions, and they should
look like exceptions on the page.

### Directive 4 — Async by default; sync only when unavoidable

For each synchronous inter-service call, an ADR stating:

- why async is not acceptable — a latency requirement, an atomicity constraint;
- how the failure is contained — timeout, circuit breaker, fallback.

"Synchronous service-to-service call" with no containment is the canonical anti-pattern here:
it converts a neighbour's outage into your own.

### Directive 5 — Trust must be explicit, scoped, and observable

Every service declares who can call it, what credentials it carries, what data
classifications it touches, and who can revoke its trust.

"The cluster is trusted, so anything inside it can call anything" is a Directive 5 violation.
It is also the assumption that turns one compromised service into an estate-wide incident.

### Directive 6 — If customers report it first, we have already failed

The Observability Specification names alert conditions that fire **before** symptoms reach a
customer. The Test Strategy includes synthetic checks that run continuously rather than
gating once at release.

### Directive 7 — Observability over performance

Accept the telemetry overhead explicitly. If a service "needs" to skip metrics or logging for
performance, that is an ADR — and the ADR must name the alternative observability path
(sampling, aggregation, async export), not merely the saving.

A service fast enough to be unobservable is a service nobody can operate.

### Directive 8 — Siloing/bulkheading by design

Design the failure domains rather than discovering them:

- by service — one crash does not take neighbours with it;
- by data path — a dead-letter backlog does not stall the live queue;
- by tenant, where applicable — one customer's bad data does not poison a shared queue.

If a single service failure cascades, the architecture violates Directive 8 regardless of how
well each individual service is written.

### Directive 9 — All execution under an explicit trust profile

Every service carries a trust profile covering identity (the principal, and where it runs),
granted scopes (what it can read, write, call), data classifications it touches, the
revocation path (how to disable its trust **without a code change**), and the audit path
(where its actions are logged).

Policy updates the profile. Policy that can only be changed by editing and redeploying code
is not policy, it is implementation.

### Directive 10 — Operational knobs must be exposed

Name, per service, which knobs exist:

- **Slow** — rate limit, throttle.
- **Stop** — drain the queue, pause the consumer.
- **Redirect** — failover routing, alternative consumer.
- **Inspect** — debug queue, log streaming, message replay.

Knobs are exposed through ops tooling, broker management, config reload or feature flags —
never through a code edit during an incident. The test is simple: can an on-call engineer who
did not write this service slow it down at 3am without opening an editor?

## Auditing

The adversary pass reviews the architecture against this list and produces a Prime Directive
Audit table — one row per directive, each row citing where it is honoured or why it is
deviated. See `Skill(df-adversary-gate)`.

## The name, and the test for a real audit

"Prime Directives" names **this** list — the ten above. The name travels further than the
list does, and an organisation layer that writes its own ten under the same heading produces
a document that resolves for every reader and means something different to each of them.
Nothing dangles, so nothing warns you. Two rules keep that from happening.

**A layer's own ten are not Prime Directives.** An organisation layer that codifies its own
build constraints — its transport, its deployment target, where its secrets live — should
name them for what they are (*build rules*, *platform constraints*) and link up to this file
for the directives. Qualifying the name with the layer is not enough:
`"<Layer> Prime Directives"` reads as **this list, applied there**, which is precisely
what it is not.

**A Prime Directive Audit is an audit of THIS list.** Before trusting a table headed
*Prime Directive Audit* — or *applied vs skipped*, or *compliance* — check its rows against
the ten above **by content, not by count**. Ten rows is the shape of a real audit and also
the shape of any other list that happens to have ten entries. A table whose rows name
implementation patterns (a gateway, a saga, an idempotent handler) rather than governing
principles is a **patterns audit** wearing this file's name — and the directive audit it
appears to be has never been performed.

Both failures are silent by construction: the reader sees a completed audit and stops
looking. A citation from outside this file must say **which** ten it means:
`Prime Directives 5, 9, 10` resolves, a bare `#5` resolves against whichever ten the reader
has to hand, and a number past ten resolves against nothing at all.

## See also

- [`service-anatomy.md`](service-anatomy.md) — the per-service components Directives 1, 8 and
  10 depend on.
- [`observability-standard.md`](observability-standard.md) — Directive 1's acceptance bar.
- [`8-implementation-patterns.md`](8-implementation-patterns.md) — the build defaults that
  make Directives 3 and 4 the path of least resistance.
- Your organisation layer — the concrete ops tooling, broker and trust mechanism these bind to.
