---
title: Operating AI Agents — A Promise-Theory Model
type: reference
status: living
source: Promise Theory — Principles and Applications 2nd ed. (Bergstra & Burgess 2019) + PWW "First Principles for AI Agent Fleets" (Bacia 2026)
applies-to: the whole pipeline; owned operationally by the Operations stage
---

# Operating AI Agents — A Promise-Theory Model

## TL;DR

Running AI agents is **operating a promise network**, not commanding a workforce. An AI agent is an *autonomous agent* in the Promise-Theory sense: it lives in its own private world (its context window), acts on its own information, and **cannot be coerced** — you can only create the conditions under which it *promises* the behaviour you want, then **assess** whether the promise was kept. The operating discipline in one line:

> **Assume no agent can be trusted. Verify unforgeable evidence. Safe autonomy = (unforgeable, independent evidence) × (reversible / compensable action). Humans legislate the safe space, judge the residual, and anchor the trust — and only they can widen it.**

This model stands on **two pillars**: **Promise Theory** (trust, assessment, autonomy) and the **PWW fleet first-principles** (software-as-data-transform, blind verification, cryptographic identity). Promise Theory supplies the *why*; the fleet first-principles supply the *mechanisms*.

## Five axioms that govern operating agents

| Axiom (Promise Theory) | Operational consequence |
|---|---|
| **Autonomous agents make promises** | You cannot *impose* behaviour. A command is an imposition with **no force** unless the agent promised to honour it. Every "the agent didn't do what I told it" confuses an imposition with a promise. You cultivate promises; you don't issue orders. |
| **The observer assesses — not the promiser** | An agent's "done / tests pass / it's autonomous" is a **claim**, never an assessment. The verdict belongs to an observer (a gate, a human, a mechanism). Self-report is not evidence. |
| **A promise is best-effort, not a guarantee** | LLM agents promise; they do not guarantee. Operate them with **assessment + compensation**, never assumed determinism. |
| **Trust = accumulated kept promises, conferred from outside** | Autonomy is *earned* and *granted*, never self-declared. No agent can promise on its own behalf to be more trustworthy. |
| **No special status for humans** | Humans and agents are one promise network. A stage handoff, a Jira ticket, a passing test — all are promises in the same graph. |

## The verification primitive

An agent takes a task, does the work, **declares the promise kept, and presents evidence.** The verifier — human or agent — validates **only** that the evidence proves the promise. It does **not** redo the work. That asymmetry is what makes a fleet scale: **verifying is cheap; doing is expensive**, so one observer can police many workers — "nothing unwatched" becomes affordable.

**The trap — self-produced evidence is just a second promise from the same agent.** If the worker both does the task and manufactures the evidence, "verify the evidence" is gameable: an assertion-free test, a stale green screenshot, a fabricated log line, a self-printed "PASSED". So the rule is sharper:

> **Trust the evidence *less* than the promise. Evidence the promiser fully controls is weak evidence.** The architecture's job is to make evidence **independent and unforgeable** — produced by the *environment* or by *another agent*, never solely by the promiser.

**Blind synthesis — the worker must not see the acceptance cases.** Independence of the *verifier* is necessary but not sufficient. If the agent that does the work also holds the exact cases it will be judged against, the cheapest "correct" solution is the lookup `if input == known_case: return known_answer` — it optimises for the eval, not the spec (Goodhart's law at the spec level).

> **The synthesizer must be blind to the verifier's cases.** The acceptance evidence — the PO Test Scenarios, the QA holdout set — is **withheld** from the agent doing the build; it is verified against cases it never saw.

This means **two test sets, not one**: the worker's *own* tests drive its inner build loop (transparent — they help it construct the solution; this is the Developer TDD loop), while the **held-back acceptance / holdout set is the firewall** that proves it implemented the *spec*, not the *test*. The holdout is not redundancy; it is the anti-Goodhart control.

### Qualifying the verifier — never trust a green you've never seen red

A verifier's promise — "I will catch X" — is itself just a promise, and it is assessable only one way: **feed it X and watch it catch.** A detector is qualified by detection, never by inspection. This is one principle applied at three points in the lifecycle:

| Lifecycle point | Mechanism | What it proves |
|---|---|---|
| **Creation** (Developer) | **TDD RED step** — write the test, watch it fail before writing the code | The test *can* detect the failure it claims to detect; green is now evidence, not vacuity |
| **Gate** (Adversary) | Holdout run + "tests meaningful, not assertion-free" check | The worker's detectors weren't gamed into vacuity |
| **Run time** (Operations) | **Decoy probes** — synthetic known-bad inputs fed into live flows, blind and continuous | The gatekeeper *still* pays attention |

TDD's RED step and a decoy are the same act — deliberately presenting a failure to prove the detector fires. Without the red run, exit code 0 is ambiguous between "code correct" and "test vacuous"; without decoys, a gate's clean record is ambiguous between "working gate" and "gate that passes everything, fed only good inputs so far" — its false-negative rate is simply unmeasured.

**Why RED is one-shot but decoys are continuous:** a *test* is a deterministic mechanism — qualified once at creation, it stays qualified until changed. A *gatekeeper* is an agent — it can drift, get lazy, be substrate-swapped, or behave well only when it knows it is being evaluated. So: **deterministic verifiers are qualified once; agentic verifiers are re-qualified continuously and unannounced.** Decoys are blind synthesis applied along the time axis — the operating agent must not be able to identify the assessment moments, or it can sandbag every one of them.

Decoy probes also serve as: the **production oracle** (live behavioural promises — triage quality, bias, drift — have no per-task ground truth; decoys manufacture it, converting an unassessable T3 question into a T2 deviation-rate measure against a pre-registered expectation); the **requalification battery** after a substrate change (see *The substrate is also a promiser*); and the closing step of **legislation** — a T3→T1 conversion is complete only when the new trusted mechanism has been shown to *reject*, otherwise the safe space was widened with a vacuous rule and the vacuity is discovered by incident instead of by a cheap deliberate failure.

## The two-axis autonomy model

Safe autonomy needs **both** factors green; drop either and a human or adversarial panel gates the action.

### Axis 1 — evidence (the forgeability ladder)

| Tier | What it is | Examples | Verifier |
|---|---|---|---|
| **T1 — mechanical, unforgeable** | The environment produces it; the agent can't fake it | compile/type-check exit code · `go test -race` / `pytest` exit *(with asserting tests)* · lint/vet · schema (Avro/XSD) validation · hash/signature · **reconciliation vs an external `authority`** · idempotency replay · health probes (`kubectl get pods`) · **dashboard rendering live data** · immutable audit ledger | a **mechanism** — the human/agent just reads its output |
| **T2 — mechanical measure, judged standard** | The number is mechanical; the threshold/mapping was a judgment | coverage (rule→test) · p95 < X · "scenario ran" via correlationId trace · invariant-holds *(but which invariant?)* | mechanism **+ a pre-registered standard** |
| **T3 — irreducible judgment** | Subjective; the evidence is the promiser's own framing → forgeable | right target? · requirements complete? · architecture sound? · code maintainable? · incident handled well? · novel security reasoning · stakeholder-comms quality | a **human**, or an **adversarial panel** (diverse, independent) |

Caveat that bites at T1: a test's exit code is unforgeable evidence **only if the test asserts something.** An assertion-free test is forgeable evidence dressed as mechanical — so the forgery just moves one level down, and you verify one level down (the adversary gate checks "tests meaningful, not assertion-free").

### Axis 2 — reversibility

Even with perfect T1 evidence, an **irreversible effect** keeps a human gate — best-effort ≠ guarantee, and you can't un-ring the bell. Mechanical proof a prod deploy *succeeded* does not make the *decision* to deploy safe to automate. `pure`/reversible + T1 → unattended; `effect`/irreversible → human gate regardless of evidence quality. (This is the `pure | effect` axis from [`data-transform-model.md`](data-transform-model.md).)

**Both axes are engineerable.** TDD converts judgment into mechanical evidence (Axis 1 ↑). Idempotency + compensation make an effect safely replayable — moving an action from irreversible toward reversible (Axis 2 ↑). So "increasing autonomy" is concrete work, not hope.

### Per-stage autonomy map

| Stage | Dominant evidence | Action reversibility | Safe autonomy |
|---|---|---|---|
| **Product Owner** (define semantics) | **T3** (right target? complete? correct logic?); only *testability* is T1 | n/a (docs) | **Low** — human + SME led |
| **Solution Architect** (formalize) | Mixed: schema/contract/coverage/directive = T1; "architecture sound" = T3 | reversible (docs) | **Medium** — agent drafts, adversary + human judge |
| **Developer** (build code) | Mostly **T1** — compiles, asserting tests green, lint, schema match, idempotency replay, `-race` | reversible (pre-merge) | **High** — the most automatable stage |
| **Infrastructure** (deploy) | Mostly **T1** — overlays apply, pods healthy, dashboards render live data, alerts evaluate | **irreversible (prod)** | **High evidence, gated by Axis 2** → human at the prod boundary |
| **QA** (test) | Mostly **T1** — scenario → test → trace evidence by correlationId | reversible | **High** — residual = HIPAA promotion gate (human) |
| **Operations** (run) | Mixed — monitoring/reconciliation/alerts = T1; incident triage = T3 | routine knobs reversible; failover/delete/comms irreversible | **Split** — unattended for routine+reversible; human for novel **or** irreversible |

## Identity — what trust attaches to

Promise Theory says trust accrues to kept promises, but never says *to whom*. For an agent the answer cannot be a name: an agent has no body to put in a room and no hand to sign a page, so a name is forgeable. Two distinct identity problems, **never crossed**:

- **Routing (a capability problem)** — *which* agent can do this task. Solved by role + tool surface, not cryptography.
- **Attribution (a cryptographic problem)** — *who actually did* the work. The only unforgeable proof an agent can give of authorship is a **cryptographic signature** (a Merkle root per session, anchored in an immutable ledger).

> **Don't solve routing with wallets, or attribution with prompts.** Trust ("accumulated kept promises") accumulates against a **signing key**, not a persona name — earned autonomy is a track record bound to an unforgeable identity. A self-asserted name is not an identity.

## The substrate is also a promiser

An agent does not bottom out in its prompt. Under every agent sits a stack of promisers the operator did not build and cannot inspect — and **no layer of it can be trusted by inspection, only by behavioural evidence**:

| Layer | Its promise | Why inspection can't establish trust |
|---|---|---|
| **Model weights** | "I behave as trained/aligned" | Weights are opaque; **training is not specification**. Even a *self-trained* model can only be assessed behaviourally — the trainer knows the data, not what was learned. Self-training removes the adversarial-supplier risk, never the opacity risk. |
| **Inference provider** | "You are getting model X at version Y, faithfully served, confidentially handled" | A claim, not an assessment. Providers can quantize, swap, silently update, or wrap with hidden system prompts. Confidentiality is contractual (T3), not mechanical. |
| **Harness / runtime** | "Tools, context-loader, and sampling are wired as declared" | Third-party software that version-drifts underneath you. |

Two separable problems, mirroring routing-vs-attribution — never crossed:

- **Substrate identity (integrity)** — *am I running what I think I'm running?* Engineerable toward T1: pinned model versions, behavioural fingerprint probes (known prompt→response signatures), TEE-attested inference where available.
- **Substrate behaviour (trustworthiness)** — *does this stack keep the promises my pipeline depends on?* Never provable by provenance — only by accumulated behavioural evidence: **qualification evals (the substrate's holdout set)**, canary tasks, track record.

> **Trust attaches to a pinned configuration — (model-version × harness × tool surface × context-loader) — never to a brand.** "Claude" is a routing name; `model-id@config-hash` is what a track record can bind to. (This generalises "pin the runtime, not just the prompt" downward to the model layer, and is the promise-theory reading of PWW axioms 50–54: deterministic provenance, Runtime Trust Profile.)

**A substrate change voids the track record.** A silent provider model update is evidence-standard drift at the substrate level: the accumulated kept-promise history belonged to the *previous* configuration. Operationally: pin versions; treat any model/harness bump like requalifying a supplier — re-run the qualification evals before the fleet's earned autonomy carries over.

**Why this strengthens rather than weakens the model:** the verification architecture was already built for untrusted promisers. A gate checking unforgeable evidence does not care whether a failure originates in a bad prompt, a bad model, or bad luck — **output verification absorbs substrate untrust unchanged**. What the substrate layer adds is trust *accounting*: attest what's running, condition earned autonomy on the pinned config, requalify on change.

## The fleet coordination surface

Promise Theory is pairwise (agent → agent). A *fleet* also needs one **canonical, queryable shared surface** for coordination, and it must keep **discussion separate from state**: ephemeral chatter (a channel) is not durable state (the assessable record). State lives where promises and their evidence are recorded — tickets, the audit ledger, [Engram](../starter-kit/instance/AUTHENTICATION.md#engram); discussion *references* state, never replaces it. An agent that changes state silently, or treats a chat message as a state change, breaks the assessment model.

## The human role — legislator, judge, trust-anchor

The human is **not in the execution loop, nor in the routine-verification loop.** The human:

1. **Legislates the safe space (a priori).** The human fixes, before the fleet runs:
   - **The mission** (the flexible target) — the invariant *goal*, while the *path may flex*; the agent re-plans locally toward it. Mission + a small set of next-action heuristics is the sweet spot.
   - **The non-negotiable axioms** (the rigid invariants) — hard-stops that hold across *all* inputs and **override the mission on conflict** (e.g. "no prod DB write without operator confirmation"). Operator-reviewed, never agent-generated.
   - **What counts as proof** — trusted evidence mechanisms + acceptance criteria (held back from the worker — see *Blind synthesis*).
   - **What's safe to let run** — the reversibility classification of each action.
2. **Judges the residual** — the irreducible T3 judgment and the irreversible effects that fall outside the codified safe space.
3. **Anchors the trust** — the human is where the verification regress bottoms out: the one promise in the system not verified by another agent, only by reality (incidents).

Three properties make this role permanent and high-leverage:

- **Leverage, not labour.** Human judgment is O(1) per *rule*, not per *task*. Decide once that "exit-code-0 from an asserting test = trusted" or "prod deploy = irreversible → gated," and it governs unboundedly many runs. The fleet's health metric: *human judgment-events per unit of output trending to zero while the codified safe space grows.*
- **The a priori is fallible, so it has its own feedback loop.** A "trusted" test with an assertion gap, an action mis-classed "reversible" — when something **inside** the safe space causes an incident, that's evidence the constitution was mis-drawn, and it routes back to the *legislator*, not just the worker. The safe-space map is a **living artifact, revised by incidents.**
- **The fleet cannot widen its own safe space.** Trust is conferred from outside; self-granted trust is invalid by construction (an agent declaring itself more autonomous is the overclaim failure mode). Converting a T3 judgment into a trusted T1 criterion is an act **only the human trust-anchor** can legitimately perform. The human role migrates *upward* (worker → legislator/judge/anchor); it does not disappear.

<!-- ───────────── AI-AGENT CONTEXT BELOW ───────────── -->

## How to apply this operationally

- **Every stage handoff is a promise; every gate is an observer.** A gate checks **unforgeable evidence against a pre-declared promise** — nothing more, nothing less. The "cold-X test" is literally *"can the next agent keep its promise given only the upstream promises?"*
- **Never accept a self-report as assessment.** "I'm done / tests pass / it works" is a claim. Demand the independent, unforgeable evidence (exit code, rendered dashboard, reconciliation, audit entry).
- **Fix the evidence standard with the task, not at verify time** — it is part of the promise's body (the acceptance criteria / Test Scenarios). Otherwise the agent supplies evidence for the promise it found easy to keep.
- **Prefer a mechanism over an opinion.** Where the promise allows it, verify with a deterministic mechanism (exit code, hash, reconciliation), not another agent's judgment — because the verifier is *also* an untrusted agent. Reserve agentic verification for irreducible judgment, and there use **independence + diversity** (an adversarial panel), never one agent vouching for another.
- **Two distinct checks, never conflated:** `evidence ⊢ promise P` (was the declared promise kept) *and* `P = the needed promise` (was it the right promise — guaranteed upstream by correct specification, not derivable from the evidence).
- **Effects and irreversible actions stay human-gated** until idempotency + compensation move them toward reversible. Routine, reversible, T1-verified actions run unattended.
- **Widen autonomy by codifying judgment, not by trusting harder.** Each T3→T1 conversion is a human act of legislation; surface candidates to the human, never self-grant.
- **Withhold the acceptance cases from the worker (blind synthesis).** The building agent gets the spec, not the acceptance/holdout cases — otherwise it games the test instead of implementing the spec.
- **Pin the runtime, not just the prompt — all the way down to the model.** An agent is *context + tools realised by a runtime on a model*; the same memory on a different runtime/tool surface/model version gives divergent behaviour. A promise is reproducibly assessable only if the full pinned configuration is fixed — the context-loader that decides what materialises into the window is part of the agent, and so is the model version underneath (see *The substrate is also a promiser*).

## Anti-patterns (each erodes the trust model)

- **Trusting self-reports** — accepting "done / passing" without independent evidence.
- **Self-produced evidence** — assertion-free tests, screenshots the agent controls, self-printed "PASSED". Forgeable evidence dressed as proof.
- **Self-granted autonomy** — an agent claiming it is "running without you" / more trustworthy than its track record warrants. Trust comes from outside, always.
- **Evidence-standard drift** — negotiating what counts as proof at verification time instead of fixing it with the task.
- **Static reversibility** — treating the "reversible" classification as permanent; it must be revised when an "inside-the-safe-space" incident proves it wrong.
- **Single-agent vouching** — one agent certifying another with no independent mechanism or adversarial diversity.
- **Leaking the acceptance cases to the worker** — hand the synthesizer the eval and it learns to pass the eval, not implement the spec (Goodhart lookup degeneration).
- **Name-as-identity** — trusting a self-asserted persona name instead of a signing key; routing identity mistaken for attribution.
- **Brand-as-identity at the substrate** — trusting "it runs Claude / GPT" instead of a pinned, attested configuration; letting a track record survive a silent model or harness swap.
- **Trust-by-provenance** — treating a self-trained or open-weights model as trusted because you know where it came from. Provenance proves supply chain, never behaviour; only qualification evals and track record do.

## Relationship to the rest of `reference/`

- [`data-transform-model.md`](data-transform-model.md) — `pure | effect` is **Axis 2**; `authority` is *whose promise about a fact is trusted* (Promise-Theory webs of trust); validation rules are the promises made executable.
- [`observability-standard.md`](observability-standard.md) — the **assessment surface**: you cannot verify a promise you cannot observe. "Verified rendering live data" is unforgeable T1 evidence produced by the running system.
- [`10-prime-directives.md`](10-prime-directives.md) · [`8-implementation-patterns.md`](8-implementation-patterns.md) — the platform promises every service keeps by default.
- Developer-stage [`02-tdd-implementation-guide.md`](../stages/3-Developer/02-tdd-implementation-guide.md) — TDD is the primary T3→T1 lever: it turns "is the code correct?" (judgment) into "does this asserting test pass?" (mechanism) by fixing the evidence standard before the work. The RED step is the qualification act for the new mechanism (see *Qualifying the verifier*).
