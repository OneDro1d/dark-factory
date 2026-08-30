# kits — installable bundles

A **kit** is a named set of this repo's skills plus the hooks that make them work: the unit
somebody installs to get a working agent for a particular kind of work.

```
kits/<name>/kit.json     name · description · skills[] · hooks[] · harnesses[]
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
| `kits/distributed-systems` | 5 | many-service design and mapping |
| `kits/frontend` | 3 | web interfaces |

`kits/method-core` is the floor. The others assume it is installed alongside.

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

`kit-check.py` reports skills that no kit names. Today it reports four, and each is a
decision rather than an oversight:

- **`develop-and-test`** and **`requirements-discovery`** — they ship here but are hardwired
  to one estate's stack (Supabase, RabbitMQ, DigitalOcean, pnpm, Zod, Fastify; and a
  requirements template naming one estate's services). They are bindings wearing the
  method's name, and are scheduled to move to an org layer. Naming them in a kit would put
  an estate's stack into every install.
- **`handoff-auto`** — superseded by `agent-notepad`, which says so in its own description
  and whose installer unwires it. Still shipped so existing installs do not break.
- **`coder-file-transfer`** — genuinely uncategorised. It is a real skill with no kit that
  fits, and inventing a one-skill `devops` kit to house it would be padding.

An unbundled skill is **reported, never failed**. It may be standalone, or new.

## Harnesses

Each kit declares which agent harnesses it targets.

**Skills are portable as-is** — Codex CLI reads the same `SKILL.md` format, so one skill set
serves both. **Hook wiring is not**: Claude Code uses `settings.json`, Codex uses
`hooks.json` / `[hooks]` in `config.toml`, and Codex implements a superset of the lifecycle
events (11 against Claude Code's 5). The hook **scripts** are shared; the **wiring** is
rendered per harness by the consuming instance.

⚠️ **Unverified:** that these hook scripts run unchanged under Codex is inferred from its
documentation, not measured. Do not claim Codex support on the strength of this file.

## Checking

```sh
python3 boot-kit/scripts/kit-check.py            # every kit resolves
python3 boot-kit/scripts/kit-check.py --self-test # prove the checker can fail
```

The self-test plants a kit naming a skill that does not exist and asserts it is caught. This
repo has shipped a gate that could not fail before — `publish-gate.sh` once reported CLEAN
on a planted canary with three bugs behind it — and the lesson recorded then was that a gate
which cannot fail is worse than none, because it suppresses the caution its absence would
prompt.
