# Rules of the Road (for Humans + Bots)

Generated: 2026-01-05


This file distills Chris Richardson’s *Microservices Patterns* into an agent-friendly rule set, with **minimal** house additions.
Richardson remains the baseline; the house additions are guardrails and enhancements.


## Canonical Axioms

The canonical set is [AXIOMS.md](../skills/microservices-architect/AXIOMS.md) — 37 axioms,
numbered **1–37**, grouped by section. Its section headings are the index; there is no
separately generated one.

⚠️ **Numbering.** Older material cites these axioms in a longer internal numbering where
this set sat at **18–54**. To resolve such a citation, **subtract 17**; a citation below 18
has no counterpart here. The curated list below uses the canonical 1–37.

## High-Impact Axioms (curated)

- **5. Public APIs are protocol-adaptive at the edge, wire-native inside.**
- **11. Nothing unwatched turns itself on.**
- **15. If customers report it first, we have already failed.**
- **17. No blame during incident response.**
- **19. Observability over performance.**
- **20. If you cannot see it, you cannot trust it.**
- **21. Siloing / bulkheading is mandatory.**
- **22. Trust must be explicit, scoped, and observable.**
- **24. Trust is contextual, not absolute.**
- **25. Loss of trust is an incident signal.**
- **27. Trust decisions belong near the resource.**
- **28. Trust is defined by promises.**
- **29. Trust decays and revokes for many drivers.**
- **30. Trust is a first-class participant.**
- **31. Jurisdiction/context is part of identity and must be evaluated per object/workflow.**
- **32. Critical workflows require immutable audit trails.**
- **33. Deterministic provenance is a trust primitive.**
- **35. All execution occurs under an explicit Runtime Trust Profile (RTP).**
- **36. RTPs are time-bound, observable, and revocable.**
- **37. Policy and security changes are applied by updating RTPs, not patching code.**

## Where rules come from (map)

- **Ch 9**: operational testing, “knobs”, control paths, and operator-first design.
- **Ch 10**: deployment under partial knowledge; scoped responsibility; Systems Intelligence (advisory).
- **Ch 11**: production readiness; no blind spots; bulkheading; know before customers.
- **Ch 12**: security & trust; explicit trust; promises; decay/revocation; RTP.
- **Ch 13**: refactoring; strangler fig; incremental change; refactor steps emit insight events.


## Runtime Trust Profile (RTP)

Axioms **35–37** and the RTP component sketch (informative, not binding) live in one place:
[AXIOMS.md § Runtime Trust Profile](../skills/microservices-architect/AXIOMS.md#runtime-trust-profile-rtp).



## Prime Directives (Non‑negotiables)

Ranked: 2026-01-05


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
