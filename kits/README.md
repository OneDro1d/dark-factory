# kits — installable bundles

A **kit** is a named set of this repo's skills plus the hooks that make them work: the unit
somebody installs to get a working agent for a particular kind of work.

```
kits/<name>/kit.json     name · description · skills[] · hooks[] · harnesses[] · extends[]
```

A kit is a **manifest, not a copy**. It names skills that live in `skills/`; nothing is
duplicated to assemble one. `boot-kit/scripts/kit-check.py` fails if a kit names anything
this repo does not ship.

## Why directories and not one repo per kit

Because pin count is the cost that actually bites. A repo per kit adds a pin, a gate and a
drift surface each; a directory adds neither. Consumers already clone this repo once, so a
kit costs a directory and a JSON file, and selecting one at install time is a filter over a
list they already have.

If a kit ever needs its own release cadence it can be split out later. The reverse — merging
five drifted repos back — is the expensive direction, so the cheap one was chosen first.

## The kits

| kit | skills | for |
|---|---|---|
| `kits/method-core` | 12 | the method itself — the stage pipeline, the evidence gate, the operating stance |
| `kits/agent-ops` | 9 | running a governed agent over long horizons: working memory, handoffs, dispatch |
| `kits/code-review` | 9 | reviewing and auditing across dimensions that need different lenses |
| `kits/knowledge-worker` | 6 | output is understanding rather than code — docs, walkthroughs, intake |
| `kits/dev` | 5 | writing and shipping code — your own diff, your own tests, your own deps |
| `kits/distributed-systems` | 5 | many-service design and mapping |
| `kits/frontend` | 3 | web interfaces |

`kits/method-core` is the floor.

⚠️ **That sentence used to be the whole enforcement, and it enforced nothing.** "The others
assume it is installed alongside" was a dependency recorded in prose: an instance bootstrapped
from `kits/frontend` alone got three skills and none of the method they sit on, silently, and no
check asked. A kit now DECLARES what it builds on —

```json
"extends": ["method-core", "agent-ops"]
```

— and `boot-kit/scripts/kit-resolve.py` walks it, floor first, de-duplicated, cycle-safe.

**A kit with no `extends` key is left exactly as it is.** The resolver never injects the floor on
its own: doing so would make `extends` unfalsifiable and would silently overrule a kit that
deliberately stands alone. `kits/method-core` and the three older kits still carry no `extends`,
which is why they are unchanged and why adding one to them is a decision somebody has to make
per kit rather than a migration.

## How a kit reaches a machine

⛔ **Until 2026-09-03 it could not.** `kit-check.py` proved every kit RESOLVED and always passed;
nothing asked whether a kit could be INSTALLED. Measured: no path under `starter-kit/` mentioned
`kits/`, `bootstrap.sh` had no skill selection, and every bootstrapped instance shipped
`"skills": []` beside a `skillSources` map holding only a comment. Two correct halves of one
feature, joined by nothing — this repo's own signature defect, one level up from where it usually
appears: **declared, shipped, correct, and wired to nothing.** Every check that looks at the
artefact passes; only a check that looks at the *join* sees it. That check is
`boot-kit/scripts/tests/test-kit-bootstrap.sh`.

```sh
bash starter-kit/instance/bootstrap.sh --kit list          # what is available
bash starter-kit/instance/bootstrap.sh my-box --kit dev    # mint an instance carrying it
python3 boot-kit/scripts/kit-resolve.py dev                # just the resolution, as JSON
```

`--kit` may be repeated to compose. It writes `install.skills`, `install.hooks` and both source
maps into the minted lockfile, **unioned onto** what the template already declares rather than
replacing it — the template knows something about its own hook that a generic kit does not — and
records `install.$kitResolution` so a later reader can tell a curated set from a hand-edited one.

⚠️ **`--kit` is optional and stays optional.** Without it the instance ships an empty skill list.
That is honest; a default set nobody chose is the thing this repo refuses to ship everywhere
else, and it would arrive in every install.

### ⚠️ Write a kit name as `kits/<name>`, never bare

Kit names and skill names share one namespace in prose, and a backticked token cannot be
told apart — by a reader or by a checker. This is not hypothetical: the first draft of this
file wrote `` `agent-ops` `` and **`tier-check.py` correctly failed the repo**, reading it as
a reference to a skill that does not exist.

`.tiercheckignore` would have suppressed it. Suppression is the wrong fix for an ambiguity
that recurs with every future kit — the `kits/` prefix removes it permanently, and it is the
real path besides.

## ⚠️ Overlap between kits is normal, and is not a "one artifact, one home" violation

`agent-notepad` is named by both `kits/agent-ops` and `kits/knowledge-worker`. That is fine.

**One home** governs which **repo owns the directory** — exactly one does. A kit only
**references** a skill by name. Two kits naming one skill create no second copy and nothing
that can drift; two *repos* shipping one skill create both. The checker therefore does not
flag overlap. What it flags is a name with no skill behind it.

This is worth stating because the two rules read as contradictory at a glance, and a rule
somebody believes is contradictory is a rule they stop applying.

## ⚠️ What is deliberately NOT in any kit, and why

`kit-check.py` reports skills that no kit names. **It is the oracle; this list is commentary
and can fall behind it** — ⚠️ and it has, twice. First it said "four" while the checker reported
**six**, because three skills promoted in #53 and `5653f5d` landed after the sentence was
written. Then `kits/dev` took two of the six and the true number became four again, for an
entirely different reason.

**Run the checker.** A count in prose beside a tool that computes the same count is a second
answer to a settled question, and it will drift a third time.

Each remaining entry is a decision rather than an oversight:

- **`requirements-discovery`** — it ships here but its `REQUIREMENTS-TEMPLATE.md` is one
  estate's services and pipeline. The four-round interview is generic; the template is not.
  Naming it in a kit would put an estate's stack into every install.
  ⚠️ **Its sibling develop-and-test was REMOVED rather than fixed, 2026-09-01** — unbackticked
  on purpose, because this repo no longer provides it and a backticked name here reads to
  `tier-check.py` as a reference to a component that is missing. Measured
  first: no kit named it, `dark-factory-build`, `vinculum-loop` and `df-tdd-developer` never
  referenced it, and no loop had invoked it — the method's build stage is `df-tdd-developer`.
  A skill that is coupled to one estate AND that nothing in the method calls is not a
  promotion waiting to happen, it is a fork living in the wrong repo, and all three estates
  already carry their own. **Deleting it was cheaper than genericising it, and the test was
  whether anything would notice.**
- **`handoff-auto`** — superseded by `agent-notepad`, which says so in its own description
  and whose installer unwires it. Still shipped so existing installs do not break.
- ~~**`df-ui-verify`**~~ and ~~**`coder-file-transfer`**~~ — **both now live in `kits/dev`, and
  the checker says so: the unbundled count went 6 to 4 when that kit landed.** They are struck
  through rather than deleted because the reasoning above is the useful part: each was "a real
  skill whose kit does not exist yet", and the note on `coder-file-transfer` said inventing a
  one-skill devops kit to house it would be padding. It would have been. What resolved them was
  not a smaller kit but a **larger and more honest** one — a generic developer kit that several
  skills legitimately belong to. ⚠️ The lesson is worth more than the two entries: *an
  uncategorised artefact is often evidence of a missing category, not of a useless artefact.*
- **`sc-audit`** and **`sc-dev`** — promoted in `5653f5d`. ⚠️ **The DeFi kit they were meant
  for does not exist, because its other ten members are somebody else's.** Those ten are
  `Uniswap/uniswap-ai`'s, MIT, and Tier 1's own doctrine is fetch-at-a-pin rather than vendor
  — so that kit here would name two skills and point at ten it does not ship. A kit is a
  manifest over `skills/`, and it has no way to say "and these ten from upstream".
  ⚠️ **Naming it in backticks is what the section above forbids, and the gate caught exactly
  that on this bullet's first draft** — a kit that does not exist, backticked, beside skills
  that do. The rule earns its keep on the writer who just read it.

An unbundled skill is **reported, never failed**. It may be standalone, or new.

## Harnesses

Each kit declares which agent harnesses it targets.

**Skills are portable as-is** — Codex CLI reads the same `SKILL.md` format, so one skill set
serves both. **Hook wiring is not**: Claude Code uses `settings.json`, Codex uses
`hooks.json` / `[hooks]` in `config.toml`, and Codex implements a superset of the lifecycle
events (11 against Claude Code's 5). The hook **scripts** are shared; the **wiring** is
rendered per harness by the consuming instance.

### What is measured, and what is still inferred

Probed against an installed Codex CLI 0.139.0, rather than read from a changelog:

| claim | status |
|---|---|
| Codex supports lifecycle hooks | ✅ **measured** — the CLI ships `--dangerously-bypass-hook-trust` and speaks of *"enabled hooks"* and *"persisted hook trust"* |
| Codex requires a hook to be **TRUSTED**, not merely wired | ✅ **measured** — same flag. Claude Code has no analogue |
| the event set is a superset of Claude Code's | ⚠️ from documentation only |
| our hook **scripts** run unchanged | ⚠️ **still unverified** — needs a live session, not a flag |

⚠️ **The trust model is the constraint a renderer must carry.** Under Claude Code a hook is
live once `settings.json` names it. Under Codex it must *also* be trusted — so "rendered the
wiring" is not the same as "the hook runs". That is the same gap, one layer over, that
`lock-verify` L9 exists to catch for Claude Code.

⚠️ **A prior port exists on one reference machine and is NOT prior art.** Its `hooks.json`
(April 2026) is Claude Code's `settings.json` hooks block copied verbatim under a Codex
filename, and its own first line says so: *"Codex CLI does not currently expose Claude
Code-style event hooks; these are archived for reference, not automatically executed."*
Honest, inert, and a **copy rather than a translation**. Codex gained hook support at some
point after it was written — which is exactly the kind of gap not to assume across.

## Checking

```sh
python3 boot-kit/scripts/kit-check.py             # every kit resolves
python3 boot-kit/scripts/kit-check.py --self-test # prove the checker can fail
python3 boot-kit/scripts/kit-resolve.py --self-test   # prove the resolver can fail
bash boot-kit/scripts/tests/test-kit-bootstrap.sh     # prove a kit reaches an instance
```

The self-test plants a kit naming a skill that does not exist and asserts it is caught. This
repo has shipped a gate that could not fail before — `publish-gate.sh` once reported CLEAN
on a planted canary with three bugs behind it — and the lesson recorded then was that a gate
which cannot fail is worse than none, because it suppresses the caution its absence would
prompt.
