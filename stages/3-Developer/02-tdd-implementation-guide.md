---
title: TDD Implementation Guide — How to Write the Tests and the Code
stage: 3. Developer
type: implementation-guide
status: living
consumes: SA Data Flow (transforms, `pure`/`effect`) + PO validation rules + Test Scenarios
produces: failing-first tests + the minimal code that passes them (green before handoff)
---

# TDD Implementation Guide — How to Write the Tests and the Code

## TL;DR

Build every service **test-first**: **RED → GREEN → REFACTOR**, one case at a time. You do **not** invent the test list — it is the PO's **validation rules + Test Scenarios**, read through [the data-transform lens](../../reference/data-transform-model.md). Write the test that fails, write the smallest code that makes it pass, then tidy the code while the tests stay green. The Developer lane owns **unit + integration** tests (green before handoff); QA owns E2E + holdout.

New to test-first, or not a developer? Read [`03-why-we-test-first.md`](03-why-we-test-first.md) first — it explains the *why* and what REFACTOR means in plain language.

## The loop

| Step | What you do | Done when |
|---|---|---|
| **RED** | Pick one case. Write the smallest test that encodes it. Run it. It **fails** (the behaviour doesn't exist yet). | The test fails *for the right reason* — not a typo, the missing behaviour. |
| **GREEN** | Write the **minimal** code to make that test pass. Honour the Avro contract exactly; no extra features. | The new test passes and **every** existing test is still green. |
| **REFACTOR** | Improve the code's *structure* (names, duplication, size) **without changing behaviour**. Re-run tests after each change. | Tests still green; the code is cleaner. A red test means you changed behaviour — undo. |

You may not move to the next case until the suite is green.

## Where the test list comes from (you don't invent it)

Every test traces to something the PO and SA already produced. That mapping is the backlog:

| Source (from upstream) | Becomes this test |
|---|---|
| A **`LOCAL` validation rule** | **Unit test**: feed bad input at the edge, assert it is **rejected**. |
| A **`GLOBAL` validation rule** | **Integration / reconciliation test**: assert the invariant holds across services, and that the named `authority` wins on conflict. |
| A **PO Test Scenario** (`State 0 → Trigger → State 1`) | **Unit or integration test** asserting the end state, with happy / edge / failure variants. |
| An **`effect`** transform (send / charge / publish / notify) | An **idempotency test** (replay the same input → the effect happens once) **+** a **compensation test** (failure → clean rollback). |
| A **`pure`** transform | A plain **input → output** unit test. |

If a case isn't covered by an upstream rule or scenario, that's a gap — loop back to PO/SA, don't invent the requirement here.

## What you test vs what QA tests

Stay in your lane — no duplication:

- **Developer (this stage):** **unit** tests (single transform) + **integration** tests (a couple of services across the AMQP bus). All green before handoff.
- **QA (stage 5):** **E2E** (JMeter against the deployed cluster) + **the held-back acceptance suite**. Do not rebuild E2E here.

> **Blind synthesis (anti-Goodhart).** Your own tests drive your build loop — but the **acceptance evidence (the PO Test Scenarios and the QA held-back acceptance suite) is withheld from you.** You are verified against cases you never saw, which is what proves you implemented the *spec* and not just *your own test*. Don't ask for the holdout: building to it is the lookup-degeneration failure (`if known_input: return known_answer`). See [`reference/operating-agents-promise-theory.md`](../../reference/operating-agents-promise-theory.md).

## Exit gate

> **Test-first coverage:** Does every `LOCAL`/`GLOBAL` validation rule and every PO Test Scenario that touches this service have a green test? Does every `effect` have an idempotency test **and** a compensation test?
>
> **Green + race:** `go test ./... -race` (Go) / `pytest` (Python) all green, and the Per-Service Build Spec's test status is current.
>
> **Adversary Developer Pass** — including the "tests green and meaningful (not assertion-free)" check, which writing tests first makes pass by construction.

<!-- ───────────── AI-AGENT CONTEXT BELOW ───────────── -->

## The workflow, step by step

1. **Fork the skeleton** (Pattern 7). The standard service template brings the shared messaging library's init, the metrics server, AMQP connect, and the DLQ for free. You write only the business logic — and its tests.
2. **Build the case list.** For this service, pull: its transforms from the SA **Data Flow** (each tagged `pure`/`effect`), its `LOCAL` validation rules, the `GLOBAL` rules it participates in, and the PO **Test Scenarios** that route through it. That list is your test backlog.
3. **RED.** Take one case. Write the smallest test that encodes it. Run it. Confirm it fails *because the behaviour is missing*, not because of a compile error or typo.
4. **GREEN.** Write the minimal code to pass. Consume/publish **exactly** the Avro schemas in the SA Data Model — no private side channels (Directive 2), no invented contracts. Resist adding anything the test didn't ask for.
5. **REFACTOR.** With the suite green, improve structure: rename for clarity, remove duplication, split a function that grew too big. Re-run tests after each change. Never add behaviour here — new behaviour needs a new RED test.
6. **Repeat** until the case list is exhausted.
7. **Effects get extra tests.** For any `effect` transform, the idempotency test (replay → one action) and the compensation test (failure → rollback) must be green before the effect code is trusted. This is where double-charge / double-send bugs are caught.
8. **Run the full suite with the race detector** and keep the Build Spec's quick-commands + test status true — it is validated by booting a fresh agent against it.

## Worked example — MedStream "ingest a vitals reading"

### Case A — a `LOCAL` validation rule
PO rule: *"A vitals reading with no `correlationId`, or a heart rate outside 0–300, is rejected at ingestion."*

**Go — RED (write the test first, table-driven):**
```go
// vitals_test.go
func TestIngestVitals_Validation(t *testing.T) {
    cases := []struct {
        name    string
        in      VitalsReading
        wantErr error
    }{
        {"missing correlationId", VitalsReading{HeartRate: 80}, ErrNoCorrelationID},
        {"heart rate too high", VitalsReading{CorrelationID: "abc", HeartRate: 350}, ErrHeartRateRange},
        {"valid", VitalsReading{CorrelationID: "abc", HeartRate: 80}, nil},
    }
    for _, c := range cases {
        t.Run(c.name, func(t *testing.T) {
            _, err := IngestVitals(c.in)
            if !errors.Is(err, c.wantErr) {
                t.Fatalf("got %v, want %v", err, c.wantErr)
            }
        })
    }
}
```

**Go — GREEN (smallest code that passes):**
```go
func IngestVitals(v VitalsReading) (Accepted, error) {
    if v.CorrelationID == "" {
        return Accepted{}, ErrNoCorrelationID
    }
    if v.HeartRate < 0 || v.HeartRate > 300 {
        return Accepted{}, ErrHeartRateRange
    }
    return Accepted{ID: v.CorrelationID}, nil
}
```

**Python — RED then GREEN (pytest, parametrized):**
```python
# test_vitals.py
import pytest
from vitals import ingest_vitals, NoCorrelationID, HeartRateRange

@pytest.mark.parametrize("reading, expected", [
    ({"heart_rate": 80}, NoCorrelationID),                 # missing correlation_id
    ({"correlation_id": "abc", "heart_rate": 350}, HeartRateRange),
    ({"correlation_id": "abc", "heart_rate": 80}, None),   # valid
])
def test_ingest_vitals_validation(reading, expected):
    if expected is None:
        assert ingest_vitals(reading)["id"] == "abc"
    else:
        with pytest.raises(expected):
            ingest_vitals(reading)
```
```python
# vitals.py
class NoCorrelationID(Exception): ...
class HeartRateRange(Exception): ...

def ingest_vitals(reading):
    if not reading.get("correlation_id"):
        raise NoCorrelationID
    hr = reading.get("heart_rate", 0)
    if hr < 0 or hr > 300:
        raise HeartRateRange
    return {"id": reading["correlation_id"]}
```

**REFACTOR:** with these green, you might extract `validateRange(field, lo, hi)` so the next range rule reuses it — re-run the suite, confirm still green. Behaviour identical, code cleaner.

### Case B — an `effect` (idempotency)
PO/SA fact: *"Publishing `vitals.classified` is an `effect`; at-least-once delivery means the same `(id, seq)` may arrive twice and must not double-publish."*

**Go — the test that locks idempotency:**
```go
func TestPublishClassified_Idempotent(t *testing.T) {
    bus := &fakeBus{}
    seen := newSeenStore()
    msg := Classified{ID: "abc", Seq: 7}

    PublishClassified(bus, seen, msg) // first delivery
    PublishClassified(bus, seen, msg) // replay (at-least-once)

    if bus.publishCount != 1 {
        t.Fatalf("published %d times, want 1 (dedupe on (id,seq))", bus.publishCount)
    }
}
```
GREEN = check `seen` for `(id, seq)` before publishing; record it after. The **compensation** test would assert that a downstream failure triggers the documented rollback rather than leaving a half-applied effect.

## How to write the code *for* the test (the GREEN discipline)

- **Minimal.** Only what the failing test demands. Gold-plating is unrequested, untested code.
- **Honour contracts.** Exactly the Avro schemas the SA defined. A contract you wish existed is an SA loop-back, not a local invention.
- **`Log.Warn`, never `Log.Error`** — `Log.Error` panics in this stack's shared messaging library. Whatever yours is, learn its failure semantics before you write an error path.
- **Decimal for money** — never floating-point, where the service touches value.
- **Config over code** — no hard-coded knobs.

## Anti-patterns

- **Assertion-free tests** — a test that runs code but asserts nothing protects nothing (the Adversary fails these).
- **Testing the framework/bus** instead of your transform — assume the shared messaging library works; test *your* logic.
- **Mock-everything** — if the test only exercises mocks, it tests your mocks. Test the transform.
- **Code-before-test** — you lose the proof the test has teeth, and you'll shape the code to your own assumptions.
- **Tests bound to internals** — assert on the *validation rule's outcome*, not on private implementation details, or every refactor breaks the tests (the same RCT/OST entanglement the model warns against).
- **Skipping `-race`** — concurrency bugs in AMQP consumers hide without it.

## References

- [`03-why-we-test-first.md`](03-why-we-test-first.md) — the rationale and a plain-language RED/GREEN/REFACTOR primer
- `superpowers:test-driven-development` skill — the canonical RED-GREEN-REFACTOR discipline (this guide applies it to a dark-factory service)
- [`reference/data-transform-model.md`](../../reference/data-transform-model.md) — where the test list comes from (validation rules, scenarios, `pure`/`effect`)
- [`5-QA/00-qa-guide.md`](../5-QA/00-qa-guide.md) — the pyramid handoff: Developer owns unit+integration, QA owns E2E+holdout
- [`reference/8-implementation-patterns.md`](../../reference/8-implementation-patterns.md) · [`reference/service-anatomy.md`](../../reference/service-anatomy.md) — build defaults the GREEN code follows
- [`01-adversary-developer.md`](01-adversary-developer.md) — the gate this guide makes passable by construction
