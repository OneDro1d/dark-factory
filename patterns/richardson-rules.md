# PWW / Trilix — Rules of the Road (for Humans + Bots)

Generated: 2026-01-05


This repo distills Chris Richardson’s *Microservices Patterns* into an agent-friendly rule set, with **minimal** PWW/Trilix additions.
Richardson remains the baseline; PWW additions are guardrails and enhancements.


## Canonical Axioms

See `_meta/PWW_AXIOMS.md` (source of truth) and `_meta/AXIOM_INDEX.md` (generated index).

## High-Impact Axioms (curated)

- **22. Public APIs are protocol-adaptive at the edge, wire-native inside.**
- **28. Nothing unwatched turns itself on.**
- **32. If customers report it first, we have already failed.**
- **34. No blame during incident response.**
- **36. Observability over performance.**
- **37. If you cannot see it, you cannot trust it.**
- **38. Siloing / bulkheading is mandatory.**
- **39. Trust must be explicit, scoped, and observable.**
- **41. Trust is contextual, not absolute.**
- **42. Loss of trust is an incident signal.**
- **44. Trust decisions belong near the resource.**
- **45. Trust is defined by promises.**
- **46. Trust decays and revokes for many drivers.**
- **47. Trust is a first-class participant.**
- **48. Jurisdiction/context is part of identity and must be evaluated per object/workflow.**
- **49. Critical workflows require immutable audit trails.**
- **50. Deterministic provenance is a trust primitive.**
- **52. All execution occurs under an explicit Runtime Trust Profile (RTP).**
- **53. RTPs are time-bound, observable, and revocable.**
- **54. Policy and security changes are applied by updating RTPs, not patching code.**

## Where rules come from (map)

- **Ch 9**: operational testing, “knobs”, control paths, and operator-first design.
- **Ch 10**: deployment under partial knowledge; scoped responsibility; Systems Intelligence (advisory).
- **Ch 11**: production readiness; no blind spots; bulkheading; know before customers.
- **Ch 12**: security & trust; explicit trust; promises; decay/revocation; RTP.
- **Ch 13**: refactoring; strangler fig; incremental change; refactor steps emit insight events.


## Runtime Trust Profile (RTP)

See:
- `chapters/richardson/ch12/patterns/runtime-trust-profile.md`
- `_meta/RTP_MINIMAL_SCHEMA_SKETCH.md` (informative, not binding)



## Prime Directives (Non‑negotiables)

Ranked (Ryan): 2026-01-05


These are the rules the team and coding agents must follow by default. Exceptions must be explicit and justified.

1. **Nothing unwatched exists.** — If you ship a workflow, you ship the insight/observability to understand it before customers see issues.
2. **If you produce it — publish it. If you consume it — consume all of it.** — Client-side filtering; treat the wire as a consistent, schema’d data space.
3. **Pub/sub by default.** — Prefer event-driven conversations; route through wireline formats quickly after protocol handlers.
4. **Async by default; sync only when unavoidable — and isolate it.** — Pub/sub default; sync only for true ACID/idempotency needs or unavoidable sync dependencies; tight interfaces + feature flags.
5. **Trust must be explicit, scoped, and observable.** — Authenticate everything; authorize narrowly; trust failures emit insight signals.
6. **If customers report it first, we have already failed.** — Breaks happen; surprise is the failure. Know before customers, or immediately as impact occurs.
7. **Observability over performance.** — Willingly pay ~20–30% overhead to eliminate blind spots (painted windshield unacceptable).
8. **Siloing/bulkheading must be possible by design.** — Not using bulkheads is a deployment choice; not supporting them is an architectural failure.
9. **All execution occurs under an explicit Runtime Trust Profile (RTP).** — RTP is time-bound, observable, revocable; policy changes update RTPs rather than emergency patching.
10. **Operational knobs must be exposed.** — Expose the knob, inputs, and twist (control paths). Operating matters more than building.
