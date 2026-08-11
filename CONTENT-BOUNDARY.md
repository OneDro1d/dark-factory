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

## Two rules that are not obvious

### 1. Build by SELECTION, never by subtraction

This repo was created with a fresh `git init` and generic content copied *in*.

**Never** clone a private repo and delete the private parts. Deletion does not remove git
history — a `git log` on the published result would hand out everything you thought you had
removed. If this repo ever needs rebuilding, rebuild it the same way: empty, then add.

`publish-gate.sh --history` scans every blob ever committed for exactly this failure.

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

1. `bash boot-kit/scripts/publish-gate.sh --history` → must print **CLEAN**
2. Re-read `README.md` and `docs/` by eye — a gate catches strings, not implications
3. Confirm no skill references a path outside this repo
4. Confirm the org repos exist and carry everything that was split out, so nothing is lost

The gate is necessary, not sufficient. It has no opinion about a paragraph that describes a
client's architecture without naming them.
