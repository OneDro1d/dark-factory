# The content boundary — what may and may not live here

This repo is **public**. Everything committed here is world-readable, permanently, from the
moment it is pushed.

> **This repo was rebuilt on 2026-08-04 for exactly the reason rule 1 below describes.**
> The previous history carried client landmarks in files that had since been cleaned in the
> working tree. `publish-gate.sh --history` caught it — the tree passed and the history did
> not. Because a deletion cannot remove git history, the repo was rebuilt by selection into
> a fresh `git init` rather than patched. If it happens again, do the same thing.

## The rule

| Belongs here | Belongs in an org repo |
|---|---|
| The method, stated generically | Any client, product, or estate name |
| Skills with no client nouns | Tracker ids, board ids, ticket prefixes |
| Hooks that enforce generic contracts | Cluster names, registries, ARNs, account ids |
| Public standards cited as examples | Hostnames, project ids, credentials of any kind |
| Lessons stated as principles | Personal names, home paths, machine-local paths |

Consumers: one private Tier-2 repo per organisation you serve (`dark-factory-<org>`).

## The direction rule — generic method moves up

The table above sorts content by **what it contains**. On its own that is not enough, because
most real files are mixed: generic method wearing a few landmarks. Sorting such a file by its
landmarks files the whole method privately — and then every org repo grows its own copy, and
the copies drift.

So there is a second question, and it is asked first:

> **Is this method, or is this specifics?** Method belongs here, stated generically.
> Specifics — names, ids, paths, endpoints, tracker and cluster configuration — belong in the
> org repo. A file that is both is **split**, not filed.

When the method later changes it changes once, here, and each org repo picks the change up at
its next pin bump. That is `docs/architecture.md`'s "instances compose; they do not copy",
applied one tier up: many consumers **pull** the method instead of each carrying a copy.

Three things this rule does **not** license.

1. **It does not outrank the landmark rule.** Where the two disagree the landmark rule wins
   and the content stays private. "It would be useful publicly" is not a boundary argument.
   Publishing is irreversible; keeping something private is not.
2. **It does not authorise extraction by deletion.** Moving method up is still a move, and
   moves are made by selection — rule 1 below. Clone the org file, delete the names, and you
   have published the names.
3. **It does not treat "looks generic" as "is generic".** A method exercised on exactly one
   lane carries a *hypothesis* of generality, not a demonstration. The test is whether a
   second lane can consume it unchanged. Where it cannot, what moves up is the part that can,
   and what stays behind is a binding.

⚠️ **This is not the rule `boot-kit/scripts/tier-check.py` enforces**, and the two are easy to
confuse. That one governs *dependency* direction — a repo may not reference a skill it does
not ship. This one governs *placement* — where a thing should live at all. They are
complements, and neither implies the other: on 2026-08-25 this repo referenced an
operating-stance skill it did not ship, four times across two files, while `tier-check`
printed `PASS`. The references were bare backticked names in prose, and it detects only
`Skill(<name>)` and the legacy path form — rewriting one of those four into `Skill(...)` made
the same gate fail on the same line. So a placement mistake is not guaranteed to surface as a
dependency failure, and a passing `tier-check` is not evidence that placement is right.

Both halves of that example were resolved the same day, and the second half is the one worth
remembering. The operating stance moved **up**: it is generic method, so it now ships here as
[`work-autonomously`](skills/work-autonomously/SKILL.md) and the four references resolve. But
fixing it exposed a **fifth** reference nobody had looked at, on the line directly *above* it
in the same two lists — step 1 of the engine's own pipeline, naming a memory-recall skill that
only one org repo ships. (It is not named here, for the same reason it had to come out of the
lists.) It had been just as invisible, for just as long, and for the same reason: attention
had been spent on the reference someone happened to notice. **When you find a misplaced
reference, audit what sits beside it** — enumerate every skill name the repo cites and
subtract the ones it ships, rather than fixing only the one you were told about.

## Two rules that are not obvious

### 1. Build by SELECTION, never by subtraction

This repo was created with a fresh `git init` and generic content copied *in*.

**Never** clone a private repo and delete the private parts. Deletion does not remove git
history — a `git log` on the published result would hand out everything you thought you had
removed. If this repo ever needs rebuilding, rebuild it the same way: empty, then add.

`publish-gate.sh --history` scans every blob ever committed for exactly this failure.

It scans them by **reachability**, because "every blob in this clone" and "everything the
world can fetch" are not the same set — and treating them as one made the gate unfixable:

| class | what it means | verdict |
|---|---|---|
| **published** | reachable from a remote-tracking ref — already fetchable by anyone | FAIL, and a force-push will not undo it; rebuild |
| **pending** | reachable from `HEAD`, from no remote — the next push would publish it | FAIL, but still fixable: drop the commit first |
| **local-only** | in this clone and nowhere else (a stale branch whose remote ref was pruned) | WARN — a fact about this working copy, not a publish blocker |

A stale local branch used to read as a published leak, and the gate then prescribed
"rebuild from a fresh git init" for a condition that did not exist upstream. A gate that
fires on something the maintainer cannot fix is one people learn to override, which is how
the next real finding gets waved through. Where a clone has **no** remote-tracking refs the
distinction cannot be drawn, so P8 falls back to scanning everything and failing hard: an
unknown must never be recorded as an ok.

`boot-kit/scripts/tests/test-p8-reachability.sh` plants a committed canary in each class,
in a scratch repo, and asserts the verdict — the classes are only safe to separate if each
is proven to fire on its own input.

### 2. Landmarks, not vocabulary

Name-based exclusion is not a boundary. The 2026-07-12 leak came through a *generically
named* skill (`df-ui-verify`) whose contents were entirely client-specific. Conversely, the
first run of `publish-gate.sh` flagged `reference/data-transform-model.md` for the word
`NEMSIS` — a **public** EMS data standard, cited in a list of schema-standard examples
alongside Schematron. That is teaching material, not a leak.

So the gate matches **landmarks** — nouns that can only have come from one estate — and not
**vocabulary**:

| Landmark (blocked) | Vocabulary (allowed) |
|---|---|
| an internal programme code, a ticket prefix like `AH-1234` | `HIPAA`, `NEMSIS`, `Schematron` |
| a registry name, `arn:aws:…`, a cluster hostname | "a container registry", "a managed cluster" |
| "`<named exchange>` is SoR" | "the upstream provider is SoR" |

The examples above are deliberately abstract, for the reason given at the top of this
section: **a document that lists your landmarks is itself a list of your landmarks.** The
concrete patterns live in `boot-kit/scripts/landmarks.conf`, which is gitignored.

A gate that cries wolf gets ignored, and an ignored gate is worse than no gate — it supplies
false assurance. Tune it toward precision, and keep the recall in the *history* scan.

## Before every push, and before any re-publication

1. `bash boot-kit/scripts/publish-gate.sh --history` → must print **CLEAN** (a `WARN`
   about local-only history does not block; prune the branch or leave it)
2. Re-read `README.md` and `docs/` by eye — a gate catches strings, not implications
3. Confirm no skill references a path outside this repo
4. Confirm the org repos exist and carry everything that was split out, so nothing is lost

The gate is necessary, not sufficient. It has no opinion about a paragraph that describes a
client's architecture without naming them.
