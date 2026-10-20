# Provenance

`SKILL.md` in this directory is an **unmodified verbatim copy** of:

- Repo: https://github.com/mattpocock/skills
- Path: `skills/productivity/grilling/SKILL.md`
- Fetched: 2026-09-03 from `raw.githubusercontent.com/mattpocock/skills/main/…` (1987 bytes, HTTP 200)
- Licence: **MIT**, Copyright (c) 2026 Matt Pocock

Do not edit `SKILL.md` in place. If project-specific behaviour is needed, add it here or
in a separate wrapper skill — an edited copy silently diverges from upstream and
nobody can tell which version they are running.

## Why it was installed here

Its central rule is the exact failure mode that cost a prior team days:

> "Finding *facts* is your job, never the user's… don't ask the user for anything
> you could look up yourself."

A consolidated list of a dozen questions was once put to a stakeholder, and on
audit most were already answered and discoverable without asking — decisions already
made and recorded on tickets, infra facts a single read-only command would have
settled, and a constraint that turned out to be the wrong one entirely.

Grilling's frontier discipline also fixes the *other* half of that failure: some
questions depended on answers to other questions in the same list, so they belonged
to a later round and could not have been usefully answered.

Related skills already installed, and how this differs:
- `critical-thinking` — challenges a plan that already exists; grilling *builds*
  the plan by interrogation.
- `requirements-discovery` — a fixed-round discovery script; grilling computes
  its rounds from a design tree, so it adapts.
- `df-dispatch-subagents` — pairs with grilling's "dispatch a sub-agent for facts".

Also in that repo and worth a look: `skills/engineering/grill-with-docs`,
`to-tickets`, `triage`, `wayfinder`.
