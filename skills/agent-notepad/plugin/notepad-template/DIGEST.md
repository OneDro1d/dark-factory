# DIGEST — the standing caveats

Empty on a fresh notepad, and that is the correct starting state: a seeded caveat is
somebody else's, and one invented to fill the file is worse than none.

## What goes here

Caveats that are **durable** — true next cycle and the cycle after — and that must never be
compressed away. Anything that reads "⚠️ this looks like X and is actually Y", any measured
correction of a claim someone would otherwise repeat, any trap in the tools this objective
drives.

## What does NOT go here

Per-cycle working memory. That is `NOTES.md`: current goal, last decisions, next action,
blockers. If it will be untrue next week, it belongs there.

## Why the split exists

The SessionStart hook injects **three** files at boot — `NOTES.md`, this one, and
`repos.manifest.json` (`plugin/hooks/session-start.sh`). So a caveat here reaches a cold
session exactly as reliably as one in `NOTES.md`, and `NOTES.md` has a ≤150-line cap that
durable caveats outgrow. A long-running objective generates them faster than a capped file
can hold, and the cap then pushes against the one thing the notepad's rules say must never be
compressed.

⚠️ **This file is COMMITTED. Never add it to `.gitignore`.** It was ignored once, as
"derived (precomputed cross-scope digest from the memory index)". That producer was removed
2026-07-29 and nothing has regenerated the file since. An ignored `DIGEST.md` exists on one
machine, and every other clone — another laptop, a fresh checkout, a cold session — loads
nothing where the caveats used to be. `plugin/tests/test_notepad_model.sh` asserts the
template does not ignore it, so re-adding the rule is a test failure rather than a discovery.
