# `bindings/` — where an estate says what it is, and nothing else

A **binding** is the entry point a person actually types: `/acme-dark-factory`. It is one
`SKILL.md` per estate, and its whole job is to answer *"what is different here?"* — the
tracker, the repos, the clusters, the hub, the deploy gate, the identities.

Everything that is **not** different lives in Tier 1 and is **invoked by name**.

---

## ⚠️ Why this directory exists at all

It did not, until 2026-09-01, and the absence had a measurable cost. Three estates each
hand-rolled a binding with no template to start from, and they drifted to **301, 294 and 124
lines**. The 124-line one was missing the preflight and Promise Theory outright.

Worse, and the reason this file leads with it: **not one of the three invoked
`work-autonomously`** — the skill carrying the escalation gate, the rule that says *decide it
yourself before spending the operator's attention*. That skill shipped in Tier 1, was open
source, was fetchable by every kit, and **never reached a single session**, because nothing
named it.

⚠️ **This is the estate's own doctrine one link further down.** *"Content on disk that no
lockfile declares is installed by nothing"* is well understood. The sibling failure —
**declared, installed, and never invoked** — has the same shape and none of the visibility: the
file is right there on disk, so every check that looks for it passes.

---

## The six a binding MUST invoke

Copy `SKILL.md.template`, fill the estate slots, and keep every one of these. They are asserted
by `starter-kit/tests/test-binding-invokes-generics.sh`, so dropping one fails CI rather than
failing quietly in six months.

| invoke | why it cannot be estate-specific |
|---|---|
| `work-autonomously` | the escalation gate. An estate MAY bind a **stricter** stance on top; it may not go without one. |
| `critical-thinking` | the pass that decides whether a question is really the operator's before you spend their attention. |
| `vinculum-loop` | the loop contract — the notify triggers, the evidence gate, the A/B/C decision policy. |
| `vinculum-map` | durable state across context resets. Without it a long mission restarts from nothing. |
| `df-dispatch-subagents` | Promise Theory: the promise plus the unforgeable evidence, and the judgment ladder for right-sizing. |
| `df-adversary-gate` | a self-report is not an assessment. The seam where a worker returns is a trust boundary. |

**Reference them by NAME, never by path.** A path resolves on the machine that wrote it. Two
bindings in this estate's history pointed into `Dark-Factory-Process`, which was archived
2026-08-06 — both links resolved to nothing, so the contract was never loaded and nothing said
so.

---

## What belongs in YOUR binding and nowhere else

- **The tracker** — Jira, Monday, Notion, Linear: board id, the frontier query, the column ids.
  Column ids are opaque and not derivable from titles; resolve by id.
- **The repos and lanes** — by *name*, resolved through the lockfile. Never a hardcoded path.
- **The deploy gate** — and this is the one that does not carry between estates. Where a push
  auto-deploys, the branch is the boundary. Where a rollout is an explicit act, the **cluster**
  is. Copying the wrong model gives you a false safety story in both directions.
- **The hub, the identities, the memory namespaces.**
- **Today's model names**, if you want them. Tier 1's ladder in `df-dispatch-subagents` ranks
  tiers by *irreducible judgment × verifiability* and says explicitly that a lane binding MAY
  name today's models and override it. ⚠️ **That is the ONLY correct home for a model name.** A
  model line-up changes on a far shorter timescale than a doctrine file, so a name committed to
  Tier 1 is a decaying fact that reads like a constant.
- **The hard stops your estate treats as real-world.**

---

## What does NOT belong here

⚠️ **Do not restate a generic contract.** Every sentence you copy from Tier 1 into a binding is
a sentence that will be fixed upstream and stay broken here — and a reader has no way to tell
which copy is current. If you find yourself explaining *how* Promise Theory works, stop: invoke
`df-dispatch-subagents` and describe only what your estate does differently.

⚠️ **Do not invent a second autonomy stance.** Bind a stricter one on top of
`work-autonomously` by naming it. Two stances with no stated precedence is how an agent picks
the more permissive one.
