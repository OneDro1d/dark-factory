# Dark Factory

**Autonomous, governed, evidence-gated software delivery — the method, the skills, and the hooks.**

A Dark Factory is a build system that runs without a human in the inner loop, and is
*trustworthy* anyway. Not because the agents are reliable — they are not — but because
every claim they make is gated on evidence a human or another agent can independently
re-check.

> The core bet: an agent's confident summary is indistinguishable from a correct one.
> So summaries are never accepted. Only **raw, unforgeable evidence** is — `file:line`,
> diffs, exit codes, verbatim command output.

This repo is the **canonical, generic** method. Organisation-specific bindings — trackers,
clusters, deploy pipelines, domain rules — live in separate private repos that consume this
one. Nothing here should name a client, a cluster, or a ticket.

---

## What's in here

| Path | What |
|---|---|
| `skills/` | The method as executable [Agent Skills](https://docs.claude.com/en/docs/claude-code/skills) — one per stage, plus the control loop |
| `hooks/` | Enforcement that does not depend on the model choosing to comply |
| `starter-kit/` | The on-ramp: [`START-HERE.md`](starter-kit/instance/START-HERE.md) takes one machine from clone to a working session; `new-org-layer.sh` does a whole organisation |
| `boot-kit/` | Machine setup: templates and the publish gate |
| `reference/` | The thinking — data-transform model, Promise Theory, the orchestrator |
| `docs/` | Setup guides, plus [`DARK-FACTORY-PRIMING.md`](docs/DARK-FACTORY-PRIMING.md) — the whole method inlined into one page for an agent with **no skill system** |

### The stages

A build runs **PO → SA → Infrastructure → Observability → TDD → adversary → QA**, each a skill:

| Skill | Stage |
|---|---|
| `df-product-owner` | Vision, requirements as data contracts + validation rules, test scenarios |
| `df-solution-architect` | Data model, data flow (pure/effect), service map |
| `df-infrastructure` | DTAP placement, trust boundaries, where data lives |
| `df-observability` | The consumable surface — a `/metrics` endpoint nobody can see is not observability |
| `df-tdd-developer` | RED-GREEN-REFACTOR, where the test list *is* the PO's validation rules |
| `df-qa` | Executes the validation rules, captures evidence per scenario, returns a verdict |
| `df-adversary-gate` | Assesses whether the evidence proves the promise — **without redoing the work** |

### The control loop

| Skill | Role |
|---|---|
| `vinculum-loop` | The autonomous contract: 2-trigger notify (objective met \| blocked on all fronts), A/B/C decisions, evidence-gated |
| `vinculum-map` | Durable mission state that survives a context reset — map as index, claim before work |
| `dark-factory-build` | End-to-end orchestrator across the stages |
| `df-dispatch-subagents` | Promise-Theory dispatch: state the promise **and** the exact evidence required |
| `df-context-store` | In-repo substrate so agents read a map instead of re-scanning the codebase |

### Two ideas worth reading first

- **[`reference/data-transform-model.md`](reference/data-transform-model.md)** — software as data
  nodes and transforms tagged `pure|effect`, governed by validation rules, with an *authority*
  that resolves conflicts. The boundary is the data; trust is non-transitive and re-earned at
  every crossing.
- **[`reference/operating-agents-promise-theory.md`](reference/operating-agents-promise-theory.md)**
  — why an agent is an autonomous, untrusted promiser, and what follows from that.

---

## The delegability test

A task may be delegated to a sub-agent **iff**:

1. the promise can be stated crisply, **and**
2. it returns evidence you can verify **without redoing the work**

Cannot name both? Then it is not delegable, and you do it inline. This is self-limiting by
design — it is what stops "autonomous" from meaning "unsupervised".

Corollaries the skills enforce:

- **A blocked or skipped check is not a pass.** A scan that was denied, a test that did not
  run, a command that failed → the result is **UNVERIFIED**, not "fine".
- **Never hide a signal that should cost attention.** A false "done" burying a failed test
  defers a larger cost to a worse moment. Compress noise; never compress a caveat.

## Hooks — enforcement the model cannot talk itself out of

| Hook | Event | Does |
|---|---|---|
| `df-stage-gate.py` | PreToolUse | Blocks writing a stage document unless that stage's skill actually ran |
| `context-budget.py` | Stop | Forces a handoff before the context window is spent, deriving the window from observed evidence rather than a model lookup table |
| `df-dispatch-subagents-reminder.py` | PreToolUse | Injects the dispatch contract whenever sub-agents fan out |
| `check-compound-bash.sh` | PreToolUse | Rejects compound/substituted shell — explicit over implicit |

A skill is advice; a hook is a control. Anything that must not depend on the model's judgment
belongs in a hook.

---

## Using it

**Start at [`starter-kit/instance/START-HERE.md`](starter-kit/instance/START-HERE.md)** —
clone to a first working session in about ten minutes. Steps 1–3 need no account and no
network beyond the clone, which matters: a broken install and a misconfigured hub produce
similar-looking silence, and doing the offline steps first separates them.

Setting up a whole organisation rather than one machine? `starter-kit/new-org-layer.sh` is
the sibling; `starter-kit/instance/README.md` explains which question each answers.

If you only want the skills, they are portable across Claude Code, the Agent SDK, and any
harness that reads `SKILL.md` frontmatter: copy or symlink `skills/` into your agent's skill
directory and wire `hooks/` into your settings. You will not get the lockfile, the pin, or
the preflight that way — which is fine if you know that is the trade.

See [`docs/`](docs/) for setup, and [`boot-kit/`](boot-kit/) for machine templates.

## Contributing

The method is opinionated and earned — most rules here exist because something failed. If
you propose a change, say what failure it prevents. "Cleaner" is not a reason.

Read [`CONTRIBUTING.md`](CONTRIBUTING.md) before your first PR — in particular the content
boundary and the requirement that a new gate pattern be proven to *fire*, not merely to pass.
Participation is governed by the [Code of Conduct](CODE_OF_CONDUCT.md).

Found something published that should not have been, or a gate that reports success without
doing anything? That is a security issue — see [`SECURITY.md`](SECURITY.md) and report it
privately.

## Provenance

Extracted from production use at [Providentia Worldwide](https://providentiaworldwide.com)
and [OneDroid](https://onedroid.ai) across enterprise health-data and financial-trading
estates. Organisation-specific content is deliberately absent — the split is enforced by
`boot-kit/scripts/publish-gate.sh`, which scans for client landmarks and must pass before
any release.

This repository was **rebuilt by selection into a fresh `git init` on 2026-08-04**, and its
history begins there deliberately. An earlier history contained client landmarks; because a
deletion does not remove git history, the only correct fix was to rebuild rather than patch.
That is the rule stated in [`CONTENT-BOUNDARY.md`](CONTENT-BOUNDARY.md), applied to this repo
itself. The pre-rebuild history is retained privately.

## License

[Apache-2.0](LICENSE) — see [`NOTICE`](NOTICE) for attribution and third-party credits.

Copyright 2026 Providentia Worldwide / OneDroid.
