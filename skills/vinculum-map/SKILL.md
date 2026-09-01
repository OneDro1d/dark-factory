---
name: vinculum-map
description: Chart and work a Mission Map — a tracker-hosted index of decisions and tickets that carries a multi-session build across context resets. Use to start a long mission, claim the next ticket, record a decision, or resume after a handoff. Triggers on "chart the map", "mission map", "next ticket", "resume the mission", "what's the frontier".
---

# Mission Map — durable state for a multi-session build

A mission larger than one context window cannot live in the conversation. It lives on the **Mission Map**: one item on the project's tracker that indexes every decision made and points at the tickets holding the detail.

**The map is an index, not a store.** A decision lives in exactly one place — its own ticket. The map gists it in one line and links. This is what makes resume cheap: a cold session reads the map (small), then zooms only into what it needs.

> Ported from the wayfinding pattern in `mattpocock/skills`, adapted to the Dark Factory stage pipeline and a pluggable tracker.

## The tracker is chosen per mission

Declare it when the loop is invoked — "run the loop on X, tracker: jira, project ABC". Record the choice in the map's **Tracker** field so every later session inherits it.

| Tracker | Status | Map is | Tickets are | Blocking |
|---|---|---|---|---|
| **Notion** | wired where a hub exposes a Notion upstream | a `Mission` value grouping rows | rows in the `Tasks` database | `Blocks` / `Blocked By` dual relations |
| **Jira** | wired (`jira_*`) where a hub exposes Atlassian | an Epic, label `vinculum:map` | child issues in the epic | native `blocks` / `is blocked by` link |
| **Monday** | wired where a hub exposes a Monday upstream | a board | items | `Blocked by` column |
| **local-markdown** | always available, the fallback | `MAP.md` in the notepad repo | `tickets/<NN>-<slug>.md` | `Blocked by:` line in the body |

**Board ids, data sources, frontier queries, dispatch scripts and deploy gates are
organisation bindings** — they live in that organisation's Tier-2 repo, never here. Do not
re-derive them.

**Rate limits are part of the tracker contract.** Notion's `query_data_sources` is
`available_with_limit` on some plans: read the frontier **once per dispatch batch**,
never once per worker. A tracker that throttles under a fleet is a tracker that will
silently starve the frontier.

**Verify the blocking write.** Monday's dependency column with `dependencyNewInfra: true`
**silently discards** writes made through `change_item_column_values` — the mutation returns
success and the column reads back `null`. Always read the column back after setting it. If it
did not take, carry blocking in the status field instead and record the edges on the map.

If the declared tracker has no working tools, **say so and fall back to local-markdown** — never silently skip tracking. A mission with no map is a mission that cannot survive a context reset.

## Map body

Loaded once per session. Open tickets are **not** listed here — they are found by querying the tracker for open, unblocked children.

```markdown
## Mission
<what "done" looks like. One or two lines. Every session orients to this before choosing work.>

## Tracker
<jira | monday | notion | local-markdown> · project/board: <id> · map: <link>

## Notes
<domain; skills every session must consult; standing constraints and hard-stops for this mission>

## Decisions so far
<!-- the index — one line per closed ticket, enough to judge relevance, then zoom the link -->
- [<ticket title>](link) — <one-line gist of the answer>

## Not yet specified
<!-- in-scope, but not yet sharp enough to ticket. Graduates as the frontier advances. -->

## Out of scope
<!-- consciously ruled beyond the mission. Never graduates. -->

## What actually ran
<!-- Written at the END of a working session, from what happened, never from the plan. -->
Skills loaded: <the ones you actually invoked>
Not loaded: <named by the binding and skipped — and why>
Delegated: <role/tier per task> · Inline: <what you kept, and why it was irreducible>
```

## ⚠️ "What actually ran" — a missing line is visible, a skipped instruction is not

This block exists because two directives were found to fail **silently and identically**,
one week apart, and neither had any signature a reviewer could see.

**Skills.** A binding NAMES the skills a mission must invoke. Naming is not loading — skills
lazy-load on invocation, and nothing forces one. Measured live on 2026-09-01: a binding named
six, the orchestrator invoked two, and the four it skipped left **no trace whatsoever**. Green
tests, green preflight, the right file on disk, and a mission that ran without its stance.

**Delegation.** The same session dispatched **zero** sub-agents and **zero** headless workers,
and did every task inline at the top tier — including a pure enumeration that the judgment
ladder puts at the cheapest tier. It never chose wrong; **it never chose**, because
`df-dispatch-subagents` was one of the four skills it did not load. The two failures were the
same failure.

⚠️ **Do NOT solve this by auto-loading.** Measured: those six skills total ~936 lines, so
loading them unconditionally spends 12–15k tokens on *every* mission, including the ones that
need none. Lazy loading is correct. **The fix is not compliance, it is EVIDENCE of
compliance** — record what ran, and an omission becomes a line a reviewer can see.

⚠️ **Write it from what happened, not from the plan.** A block copied from the binding's list
records intent and re-creates the exact bug it exists to catch. If you skipped one, say which
and why — *"skipped `df-adversary-gate`, nothing was delegated so there was no return to
verify"* is a good entry. **An honest skip is information; a tidy list is noise.**

⚠️ **This is a declaration, not a gate.** It cannot prove a skill changed how the work was
done — only that it was loaded. Same class as a doc-move check: it catches the mechanical
case, and a reader catches the rest.

## Working the map

**Never resolve more than one ticket per session** (research tickets excepted — they are cheap and parallel). This is the primary defence against context exhaustion; the 85% context gate is only the backstop.

1. **Load the map.** Low-res only — do not fetch every ticket body.
2. **Choose a ticket.** The user's, if named. Otherwise the first **frontier** ticket: open, unblocked, unclaimed.
3. **Claim it first** — assign it to yourself *before* any work, so a concurrent session skips it. An open unassigned ticket is unclaimed.
4. **Resolve it.** Zoom as needed: fetch related ticket bodies on demand, invoke the skills the Notes name. For a DF stage ticket, that means calling the stage's `df-*` skill (the stage gate enforces this).
5. **Record.** Post the answer as a resolution comment, close the ticket, append one line to **Decisions so far**. Link artifacts; never paste them in.
6. **Advance the frontier.** Create newly-surfaced tickets, then wire blocking edges in a **second pass** (items need ids before they can reference each other). Graduate any fog the answer sharpened, clearing it from **Not yet specified**.

## Fog of war

The map is deliberately incomplete. Beyond the live tickets is the fog: work you can tell is coming but cannot yet state precisely.

**The test is whether you can phrase the question sharply now — not whether you can answer it.**

- **Ticket it** when the question is sharp, even if blocked.
- **Leave it in Not yet specified** when it is not. Do not pre-slice fog into ticket-sized pieces; one patch may graduate into several tickets, or none.

## Out of scope — and the autonomy this grants

Fog only gathers *toward* the mission. Work past it is **out of scope** — a scoping judgment, not a sharpness one.

**You may rule work out of scope on your own.** This is a B-class reversible decision under the A/B/C policy: close the ticket, add one line to **Out of scope** with the gist and the why, and carry on. Do not stop to ask. The operator reviews the map, not each ticket — that review is where a wrong call gets caught, and closing a ticket is trivially reversible.

Escalate (A-class) only if the scope cut would change what **Mission** means. Shrinking the mission is the operator's call; pruning a branch within it is yours.

## Naming

Refer to a map or ticket by its **title**, never a bare id. A wall of `PROJ-4412, PROJ-4413` is illegible; names read at a glance. The id rides inside the link.

## The notepad is a cache, not a second store

The tracker is canonical. The notepad repo holds a mirror so a session can orient without a network call and so the map survives a tracker outage.

- On claim and on resolve, write the map's current low-res body to `MAP.md` in the notepad and commit.
- **On conflict the tracker wins.** If they disagree, re-read the tracker and overwrite the cache.
- `NOTES.md` stays what it is — scratch continuity for the *current* session. It is not the map, and decisions recorded only there are lost at the next reset.

## Handoff and resume

When the context gate fires at 85% (or you finish a ticket):

1. Update the map — Decisions so far, new tickets, current frontier.
2. Call `Skill(handoff)` — the handoff points *at* the map, it does not restate it.
3. Tell the operator the session is safe to `/clear`.

**Resume order, always: Mission Map → the claimed ticket → the handoff.** Map first, because it is the index; the handoff is only the last-mile delta. Native compaction is not needed and should not be relied on — a compaction summary is lossy and unversioned, and the map exists precisely to replace it.

## Related

`vinculum-loop` (the loop that runs missions) · `dark-factory-build` (turns DF stages into the map's first tickets) · `handoff` · `df-adversary-gate` (verify a ticket's evidence before closing it).
