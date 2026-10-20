# The knowledge base, requirements and local tests

The pair keeps one shared, code-cited **knowledge base** for the project. The builder writes it from the deployed
code; the tester reads it to find the rules worth testing and flags any page a test contradicts. It grows with
every merge and every fixed bug, and it never holds secrets or the tester's scenarios.

## What it is

| Piece | Where (pair.yaml key) | What it holds |
|---|---|---|
| Pages | `paths.knowledge_drafts` → `<area>/<kind>--<slug>.md` | One page per service, flow, rules table, links map, concept or fixed bug; every fact cites `file:line` |
| Source pins | `paths.knowledge_src` → `<app>/` | A read-only clone of each app, checked out at the commit the pages were verified against |
| Flags | `<library>/flags.jsonl` (library = parent of the drafts folder) | Pages a test contradicted, until the builder re-verifies them |
| Graph | `<library>/graph/edges.jsonl` | Requirement → page links (`REQUIRES`) and page → page links (`ENFORCES`, `USES`, `CALLS`) |
| Engram | `engram.knowledge` | The published copy of every verified page, searchable by both agents and the team |
| Brief + templates | `templates/knowledge/BRIEF.md`, `page-template.md` | The evidence standard and the page shapes |

## Engram spaces to create

The setup wizard (`/pair-setup`) creates these from the `engram:` section of pair.yaml; create them by hand with
your Engram tools if you set up without the wizard.

| pair.yaml key | Written by | Read by | Holds |
|---|---|---|---|
| `engram.knowledge` | builder (after the adversary sample) | both, the team | The verified pages |
| `engram.builder_memory` | builder | builder | Facts and decisions about the project |
| `engram.builder_behaviors` | builder | builder | Lessons about how to work (Why + How to apply) |
| `engram.tester_memory` | tester | tester | Facts about testing the project |
| `engram.tester_behaviors` | tester | tester | Testing lessons; overturned verdicts and why |
| `engram.sessions_builder` / `engram.sessions_tester` | each agent | each agent | One summary per significant piece of work |

The tester's memory spaces must never hold scenario bodies or expected values; records carry run ids, counts,
scenario ids and rule ids only.

## Set it up — three steps

1. **Describe it in `pair.yaml`** (or answer the questions in `./setup-pair init` / `/pair-setup`). Everything is
   optional; an empty `knowledge:` section gives one area per app plus `cross`, the six default page kinds, the five
   default graph relations, every growth trigger on, and the library following each repo's deployed branch.

   ```yaml
   knowledge:
     branch: main                          # grow from main only (or: deployed | base | {default: deployed, web: main})
     areas:
       - {name: payments, apps: [api], focus: "payment intake, limits, refunds"}
       - {name: cross, apps: [api, web]}
     grow_on: {bug_fix: true, test_flag: true}
   ```
2. **`./setup-pair knowledge init`** (builder workspace, or the owner before the agents start). It clones each repo
   read-only at the branch the library follows and pins it, writes `BRIEF.md` with the source / area / kind /
   relation tables filled in from pair.yaml, creates one drafts folder per area and the graph file, makes the
   library folder a git repo (`knowledge.git_history`) and logs the set-up to the ledger. Safe to re-run; change
   pair.yaml and run it again.
3. **`/knowledge-build`** in the builder's Claude session. One research agent per area (in parallel) → an
   independent reviewer samples `adversary_sample` claims per page against the code → only passing pages are
   written to Engram (`engram.knowledge`), recorded (ledger + library commit) and linked in the graph → `status`,
   `graph` and `check` prove it. `/knowledge-build <area>` rebuilds one area.

After that it grows by itself (next section). `./setup-pair knowledge status` (or `knowledge-refresh status`) shows
pages per area and kind, the graph, the pins and the last log events; `./setup-pair check` warns if the library
is not set up or has no pages.

## Every setting

| `knowledge.` key | Default | What it changes |
|---|---|---|
| `branch` | `deployed` | Which branch the library grows from: `deployed` (`repos[].deployed`, else `base`), `base`, or a branch name such as `main`. A map sets it per app: `{default: deployed, web: main}`. `repos[].knowledge_branch` overrides it for one repo. Commits on other branches never touch the library. |
| `lines` | none | Another deployed branch of the same app to track as well (`{app, name, branch}`), pinned as `src/<app>-<name>`; pages carry `applies-to:` and a "differs" section. |
| `areas` | one per app + `cross` | One research agent each: `{name, apps, focus}`. |
| `kinds` | service, flow, rules, links, concept, bug | Page kinds; a default by name or your own `{name, about}`. `record` refuses a page whose kind is not listed. |
| `relations` | REQUIRES, ENFORCES, USES, CALLS, FIXES | Graph edge types; `link` refuses any other. Your own: `{name: DEPLOYS_TO, from: service, to: concept, about: …}`. |
| `grow_on` | all `true` | `merge`, `new_behaviour`, `bug_fix`, `test_flag`, `requirement` — each switches that growth path on or off in the agents' instructions and in the tools. |
| `adversary_sample` | 5 | Claims per page the reviewer checks before a page is published. |
| `git_history` | `true` | The library folder is a git repo; `record`, `link`, `advance` and `close-flag` each commit. |
| `ignore` | vendor/, node_modules/, lock files | Changed files that never make a page stale. |
| `common_files` | go.mod, Dockerfile, package.json, … | Extra file names too common to match a page by name alone. |
| `never_read` | the tester's folders | Extra folders research agents must never open. |

A mistake (an area naming an app not in `repos`, an unknown trigger, a bad name) is refused with every problem
listed, by every command — never half-applied.

## The graph, the log and the history

- **Graph** — `graph/edges.jsonl`, one edge per line, added only through
  `knowledge-refresh link --from "<title>" --to "<title>" --relation <REL> --evidence "<file:line>"` (same edge twice
  = no-op; relation must be in `knowledge.relations`). The same pair is `engram_link`ed in Engram.
  `knowledge-refresh graph` counts nodes and edges per relation and lists pages no edge touches.
- **Log** — `<ledger>/knowledge-log.jsonl`: every set-up, published page (`record`), link, flag, closed flag and pin
  move, with who and when. `knowledge-refresh status` shows the last events.
- **History** — with `git_history`, the library folder's git log is the knowledge's history: one commit per
  recorded change (`git -C <library> log --oneline`).
- **Memory** — project facts go to the pages; lessons about *how to work* go to each agent's `*_behaviors` Engram
  space (Why + How to apply), as the generated instructions say.

## How it grows (every day, on every change)

Each path below is on unless switched off in `knowledge.grow_on`; the agents' listener instructions are generated
from those switches by `./setup-pair render`, so changing pair.yaml and re-rendering changes what the agents do.
Every page published on any path goes through the same rule: adversary sample → Engram → `record` → `link`.

- **Every merge.** Each tick the builder runs `knowledge-refresh check`. An app whose followed branch moved lists
  the pages citing a changed file (STALE) and the changed files no page cites. The builder re-verifies each stale
  page at the new commit (same evidence rule, same adversary sample), writes new pages for new behaviour, updates
  `verified-at`, publishes to Engram, then runs `knowledge-refresh advance <app>` to move the pin.
- **Every fixed bug.** A fix PR merged, or a bug ticket moved to Done, gets a page of kind `bug`: symptom, root
  cause (`file:line`), the fix (PR + commit), the behaviour that changed, the guarding test, how to spot it
  coming back. Linked `FIXES` to the ticket.
- **A test contradicts a page.** The tester runs `knowledge-refresh flag --page "<title>" --reason "<plain words>"`.
  `check` then reports the flag until the builder re-verifies the page and runs `knowledge-refresh close-flag <id>`.
- **What to re-test after a change.** `knowledge-refresh impact <app> <from> <to>` follows changed files → pages →
  requirements, so the tester re-runs those requirements' checks first.

## Requirements and the scorecard

- `kit/bin/reqstatus` — one row per requirement. The tester (product owner) registers it with the number of
  acceptance checks when it writes the spec, records whether the builder's reading of the spec agrees, how many
  checks have at least one scenario, and the verdict. A PASS is refused (and later drops back to UNVERIFIED)
  unless every check is covered and the readings agree. Anyone records a `miss` when a bug got past testing.
- `kit/bin/verdict` — the tester's scorecard: one verdict per run, the independent reviewer's review of it
  (recorded on the builder's side; reviewer name `rules.reviewer`, default `adversary`), mutation runs and rule
  coverage. Text is checked so scenario content and secrets cannot be written.
- `kit/bin/testrun` — the raw run log. The builder may only post a test result through `testrun release`, which
  works only after the tester has rechecked that run through the independent checker, and leads with the
  tester's verdict.

All three write under `paths.ledger` and refuse writes from any machine that is not `builder.host` or `tester.host`.

## Local verify (the tester's local test, no deploy)

`kit/scripts/local-verify.sh <app> <commit>` clones the app at that exact commit, finds what changed against
`origin/<base>`, and per changed top-level folder runs build + unit tests: Go (`go.mod`: build, vet, test), .NET
(`*.csproj`: build, then every test project that references it), npm (`package.json`: ci, build, test), and a
repo-root `package.json` for changes outside any sub-project. Changed files no step covered, and build-only
services, keep the verdict at UNVERIFIED. Exit code = verdict (0 PASS, 1 FAIL, 2 UNVERIFIED); `result.json` sits
beside the log in `~/.cache/local-verify/<app>-<sha12>/`. `--selftest` runs it against a throw-away repo.

Anything specific to one app goes in an optional `local_verify:` block under that app in pair.yaml — never in the
script:

```yaml
repos:
  - app: api
    github: my-org/payments-api
    base: main
    local_verify:                       # all keys optional
      go_min: "1.25"                    # oldest cached Go toolchain to use
      dotnet_sdk: "10.0"                # .NET SDK major the app needs (~/.dotnet)
      go_replace:                       # a module the proxy can't fetch: clone at a pinned sha and replace it
        - {module: github.com/my-org/messaging-lib, git: "https://github.com/my-org/messaging-lib.git", sha: "<40-char sha>"}
      dotnet_prepack: [Shared.Models/Shared.Models.csproj]   # pack these into ./nupkg first, as the Dockerfiles do
      npm_test_args: "--watch=false"
      root_npm_test_args: "--watch=false --browsers=ChromeHeadless"
      setup_signatures: "MY_TEST_DB|MY_OTHER_FIXTURE"        # output that means "could not set up here", not a code failure
      full_stack:                       # enables --full-stack
        postgres: {user: app_test, port: 55432, migrations: "migrations/*.sql", connection_env: [APP_TEST_PG]}
        azurite: {port: 10000, endpoint_env: APP_BLOB_TEST_ENDPOINT}
        integration_tests: "tests/integration/*/"
```

`--full-stack` starts a local Postgres (all migrations applied) and Azurite, hands the connection string to the
listed environment variables, then runs the integration test projects. No docker, no cloud. It is refused for an
app with no `full_stack` block.

Engram is the memory store named here. What it is and how to reach it is documented in exactly one place: [Engram](../../starter-kit/instance/AUTHENTICATION.md#engram)
