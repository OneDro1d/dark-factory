---
name: df-tdd-developer
description: Dark Factory Developer stage: build a service test-first (RED-GREEN-REFACTOR) where the test list is the PO validation rules and scenarios, not invented. Go and Python examples. Triggers on "TDD", "write tests", "test-first", "implement the service", "RED GREEN REFACTOR".
---

# Dark Factory — TDD Developer

## Overview
Build every service **test-first**: RED → GREEN → REFACTOR, one case at a time. Each test is an executable validation rule. The Developer owns **unit + integration** tests (green before handoff); QA owns E2E + holdout.

## The loop
| Step | Do | Done when |
|---|---|---|
| **RED** | Pick one case. Write the smallest test that encodes it. Run it — it fails. | Fails for the *right reason* (missing behaviour, not a typo). |
| **GREEN** | Write the **minimal** code to pass. Honour the contract; no extra features. | New test passes, all existing tests still green. |
| **REFACTOR** | Improve *structure* (names, duplication, size) without changing *behaviour*. Re-run after each change. | Still green, cleaner. A red test = you changed behaviour → undo. |

## Where the test list comes from (don't invent it)
- **LOCAL validation rule** → unit test: feed bad input at the edge, assert it is **rejected**.
- **GLOBAL validation rule** → integration/reconciliation test: assert the invariant + the `authority` tie-break.
- **PO Test Scenario** (`State 0 → Trigger → State 1`) → unit/integration test asserting the end state (happy/edge/failure).
- **effect** transform → **idempotency test** (replay → one action) + **compensation test** (failure → clean rollback).
- **pure** transform → plain input → output unit test.

## Blind synthesis (anti-Goodhart)
Your own tests drive your build loop, but the **acceptance evidence (PO Test Scenarios, the QA/Argus holdout) is withheld from you** — you're verified against cases you never saw, which proves you built the *spec*, not your own test. Don't build to the holdout: `if known_input: return known_answer` is the lookup-degeneration failure.

## GREEN discipline
Minimal code only; honour the exact Avro contracts (no invented schemas); `Log.Warn` not `Log.Error` (panics in TwistyGo); decimal for money; config over code.

## Worked example — a LOCAL validation rule (Go + Python)
Rule: a vitals reading with no `correlationId`, or heart rate outside 0–300, is rejected.

```go
// RED — failing test first (table-driven)
func TestIngestVitals_Validation(t *testing.T) {
    cases := []struct{ name string; in VitalsReading; wantErr error }{
        {"missing id", VitalsReading{HeartRate: 80}, ErrNoCorrelationID},
        {"hr too high", VitalsReading{CorrelationID: "abc", HeartRate: 350}, ErrHeartRateRange},
        {"valid", VitalsReading{CorrelationID: "abc", HeartRate: 80}, nil},
    }
    for _, c := range cases {
        t.Run(c.name, func(t *testing.T) {
            if _, err := IngestVitals(c.in); !errors.Is(err, c.wantErr) {
                t.Fatalf("got %v, want %v", err, c.wantErr)
            }
        })
    }
}
// GREEN — smallest code that passes
func IngestVitals(v VitalsReading) (Accepted, error) {
    if v.CorrelationID == "" { return Accepted{}, ErrNoCorrelationID }
    if v.HeartRate < 0 || v.HeartRate > 300 { return Accepted{}, ErrHeartRateRange }
    return Accepted{ID: v.CorrelationID}, nil
}
```
```python
import pytest
from vitals import ingest_vitals, NoCorrelationID, HeartRateRange

@pytest.mark.parametrize("reading, expected", [
    ({"heart_rate": 80}, NoCorrelationID),
    ({"correlation_id": "abc", "heart_rate": 350}, HeartRateRange),
    ({"correlation_id": "abc", "heart_rate": 80}, None),
])
def test_ingest_vitals(reading, expected):
    if expected is None:
        assert ingest_vitals(reading)["id"] == "abc"
    else:
        with pytest.raises(expected):
            ingest_vitals(reading)
```

## Exit gate
Every validation rule + scenario touching this service has a green test; every effect has idempotency + compensation tests; `go test ./... -race` / `pytest` all green.

## Anti-patterns
Assertion-free tests · testing the framework/bus instead of your transform · code-before-test · tests bound to internals instead of the rule · skipping `-race`.
