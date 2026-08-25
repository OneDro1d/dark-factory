# DF Substrate Template — the in-repo agent inner-loop

This is the **reference template** for a repo's Dark Factory *inner-loop substrate*:
the in-repo, git-tracked agent toolkit that makes repeated work cheap and keeps an
AI partner honest. The `df-context-store` stage of `dark-factory-build` — and any
organisation layer's own cold-start generator — emits a populated copy of this into a
target repo.

## What it is (and why)

A repo with this substrate gives every agent (not just one) a **read-first shared
memory** + a **single-responsibility agent pipeline** + **checkable hand-off
contracts** + a **commit gate** — so analysis is done once and reused, hand-offs
can't silently degrade, and nothing ships unverified. It is the inner-loop
complement to the heavy DF build stages: the build injects rigor at the seams;
this substrate is what *persists in the repo* and binds every future session.

## Layout

```
substrate-template/
├── README.md            ← this file
├── CLAUDE-stanza.md     ← read-first/routing block to MERGE into the target repo's CLAUDE.md
├── verify-substrate.sh  ← VR1–VR8 acceptance check (run after emitting/editing)
└── dotclaude/           ← payload; the generator emits this as the target repo's `.claude/`
    ├── settings.json    ← SessionStart hook that self-arms the gate (→ hooks/ensure-gate.sh)
    ├── agents/          ← 6 single-responsibility agents + README routing table
    ├── context/         ← shared memory: SERVICE-MAP, DATA-FLOW, FINDINGS, DECISIONS, AGENT-CONTRACTS, README
    ├── hooks/           ← pre-commit staleness gate + ensure-gate.sh (self-arm) + README
    └── skills/          ← contract-check (runnable), commit-sync, + read-first/planning skills
```

`dotclaude/` is named without the leading dot so it is a normal, reviewable
directory in this kit; the generator renames it to `.claude/` on emit.

## How it's used

- **Cold start / bootstrap a repo** → a cold-start generator emits this
  payload, then **populates** `context/SERVICE-MAP.md` from the real codebase
  (via `service-mapper`) and merges `CLAUDE-stanza.md` into the repo's `CLAUDE.md`.
  FINDINGS/DECISIONS start as clean skeletons and accumulate as the repo is worked.
- **During a DF build** → the `df-context-store` stage (Stage 0.5 of
  `dark-factory-build`) scaffolds/refreshes the substrate so the build's verified
  facts land in FINDINGS/DECISIONS instead of being discarded.

## Acceptance (VR1–VR8) — run `verify-substrate.sh`

| VR | Rule |
|----|------|
| VR1 | the required file set is present (agents, context store incl. DATA-FLOW + AGENT-CONTRACTS, hooks, contract-check, commit-sync) |
| VR2 | the template is **generic** — no source-project leakage. The denylist of source-project nouns is **supplied locally**, never listed here: see `substrate-denylist.example.conf`. Unconfigured, VR2 reports FAIL rather than passing, because a denylist that matches nothing would pass on every substrate forever |
| VR3 | the `contract-check` tool's own test suite runs **green** (the checker travels intact and runnable) |
| VR4 | `CLAUDE-stanza.md` contains the read-first protocol and points at the context store |
| VR5 | `AGENT-CONTRACTS.md` defines the hand-off contracts + pure/effect + the verification rule |
| VR6 | FINDINGS/DECISIONS/SERVICE-MAP/DATA-FLOW are clean skeletons (one placeholder example, ready to fill) |
| VR7 | the `df-context-store` skill is bundled with + references the substrate template |
| VR8 | the gate **self-arms** (`ensure-gate.sh` sets `core.hooksPath` with no manual step) AND actually **enforces** — blocks an undocumented structural change, passes a documented one (adversarial git-sandbox test) |

```bash
# VR2 needs the source project's own identifiers, and those are exactly the strings that
# must not sit in a public repo — so they are configured locally, once:
cp skills/df-context-store/substrate-template/substrate-denylist.example.conf \
   skills/df-context-store/substrate-template/substrate-denylist.conf
# ...edit the placeholders, then:
bash skills/df-context-store/substrate-template/verify-substrate.sh
```

Without that file VR2 fails with an instruction instead of passing quietly. That is
deliberate: this README used to name the source project's real service prefixes and column
names in the VR2 row above, and `verify-substrate.sh` carried the same list inline — a leak
detector that spells out the nouns it hunts publishes them itself. The shape lives in the
committed `.example`; the nouns live in the gitignored `.conf`, exactly as `landmarks.conf`
and `landmarks.example.conf` split the publish gate's own patterns.

