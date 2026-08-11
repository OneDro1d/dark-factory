# The three-tier layout

Content lives in exactly one place. Instances **compose**; they do not copy.

```
  Tier 1  OneDro1d/dark-factory                 PUBLIC (private during review)
          the generic method — skills, hooks, boot-kit, reference
                    │  consumed by, pinned by commit
        ┌───────────┼───────────────┐
        ▼           ▼               ▼
  Tier 2  dark-factory-<org-a>   dark-factory-<org-b>   dark-factory-<org-c>   PRIVATE
          bindings/ skills/ workers/ hooks/ patterns/ doctrine.md
                    │  selected by, pinned by commit
        ┌───────────┼───────────┬──────────────┐
        ▼           ▼           ▼              ▼
  Tier 3  loom-laptop   loom-eso-laptop   loom-eso-coder   loom-onedroid-coder   PRIVATE
          loom.lock.json · machine/ · notepad/ · vendor/ (generated)
```

## Why this shape

**The problem it solves:** ~40 repos held ~6 distinct bodies of content, distributed by
copy. Every copy is a divergence waiting to happen, and several happened silently — a hook
suite that was 4 days stale on a working laptop while every gate reported green.

**The fix:** an instance repo holds **no skills**. It holds a lockfile naming which upstream
repos at which commits, plus machine-specific config and its own notepad. Rehydration is
`read lock → fetch pinned → materialize`.

## Tier 2 — identical shape across orgs

```
dark-factory-<org>/
  bindings/      the <org>-dark-factory skill: tracker, hubs, clusters, deploy model
  skills/        org-specific skills only
  workers/       dispatch.sh + profiles.json
  hooks/         org-specific hooks only
  patterns/      org non-negotiables
  doctrine.md    org session-start content, injected into the Tier-1 hook template
  UPSTREAM.lock  the canonical commit this org is tested against
```

Same shape everywhere means one mental model and one set of tooling — a parity check becomes
a folder-for-folder comparison instead of bespoke per-lane logic.

## Tier 3 — the lockfile is the only authority

```
loom-<instance>/
  loom.lock.json   which repos, which commits, which git identity per remote
  machine/         paths, MCP config, env
  notepad/         NOTES.md, sessions/, handoffs/   ← the one genuinely local content
  vendor/          GENERATED. Never hand-edited. Hash-verified against the lock.
```

| Instance | Composes |
|---|---|
| primary laptop | canonical + org-a + org-b + org-c |
| org-c laptop | canonical + org-c |
| org-c cloud workspace | canonical + org-c |
| org-a cloud workspace | canonical + org-a + org-b |

### The boundary becomes structural

An instance scoped to one organisation does not *reference* another organisation's Tier-2
repo. That organisation's content therefore **cannot appear** in it — not "is scrubbed from
it". Previously the separation was held by name allowlists and a content scan, both of which
failed at least once each. Those remain as backstops; they stop being the only thing in the
way.

### Why `vendor/` still exists

On a Coder workspace, `~/.claude` is on local disk and is wiped by a reset; the network
mount survives. Rehydrate must therefore work *before* credentials are available — a pure
pointer model has a bootstrap problem.

So `vendor/` is an offline cache. The change from the previous design is that it is
**generated and provably derived**: a `lock-verify` step hash-checks `vendor/` against the
pinned commits. Previously the vendored copy was hand-maintained and current only by hope,
and the drift-detection loop iterated the *cache* rather than the *source* — so it could
never discover something the cache did not already know about. A lockfile inverts that: the
lock asks the question, `vendor/` answers, and they either match or the gate fails.

## Two git identities

Composition tooling must switch identity per remote — one account cannot resolve the other
org's repos at all (404, not 403). This rules out naive recursive submodule updates as the
composition primitive, and is why the lockfile records an account per entry.
