---
name: knowledge-build
description: Build (or rebuild an area of) the pair's code-cited knowledge base from pair.yaml — one research agent per area reads the pinned source, an independent reviewer samples every page's claims against the code, and only verified pages are published to Engram, linked in the knowledge graph, logged and committed. Use when someone says "/knowledge-build", "build the knowledge base", "add an area to the knowledge base", or `setup-pair check` says the knowledge base has no pages. Builder workspace only.
---

# /knowledge-build — build the knowledge base

Everything this skill does comes from the `knowledge:` section of `pair.yaml` (areas, page kinds, graph relations,
followed branches, never-read folders, adversary sample size). Do not invent areas or kinds; if the person wants
different ones, change pair.yaml first and re-run `./setup-pair knowledge init`.

Run it in the **builder** workspace. The tester never writes the library (it flags pages instead).
`<kit>` below is the builder-tester-agents folder; `kr` = `<kit>/kit/bin/knowledge-refresh`.

## 1. Plan (read-only)
1. `<kit>/setup-pair knowledge init` — safe to re-run: pins any source not yet pinned at its followed branch,
   regenerates `BRIEF.md` from pair.yaml, makes the area folders and graph file, starts the library history.
   A FAIL line (clone refused, unknown app) stops here: tell the person what to fix.
2. `<kit>/setup-pair knowledge plan` — JSON: each area with its source folders, drafts folder and page kinds; the
   Engram space; the relations; the never-read globs; the adversary sample size. This is the whole job list.
3. If areas were named ("rebuild payments", or `/knowledge-build api billing` from the builder's start or tick
   because `knowledge-refresh unbuilt` listed them), keep only those areas. With no names: every area.
4. Engram: check the space named in the plan exists (list namespaces with your Engram tool). If it does not, ask
   the person once, then create it (`engram_create_namespace` or your install's equivalent). No Engram tools or
   no `engram` name → build drafts only and say the pages are not published.

## 2. Research — one agent per area (or per service batch), in parallel
An app can hold any number of services. The plan lists each area's `services` (detected at `knowledge init`: every
folder that builds — Dockerfile, go.mod, package.json, *.csproj…, each Go `cmd/<name>` program — unless
`repos[].services` lists them) and splits them into `research_batches` (`knowledge.services_per_agent`, default 6).
Dispatch one sub-agent per batch (an area with one batch = one agent; send them all in one message). Each writes a
`service` page for EVERY service in its batch, then the flows / rules / links pages those services take part in.
The area's `deploy_pages` entry (if any) names the apps whose deployment lives in this area and their deploy files:
one more sub-agent writes a `deploy` page per app and environment — image build + registry, manifests / overlays,
cluster + namespaces, the exact deploy and rollback commands, how to verify it landed, who approves — cited to
those files, the deploy rulebook (`rules.deploy_rulebook`) and pair.yaml `environments`; link it DEPLOYS to each
service page it covers. Each prompt contains:
- the full text of `BRIEF.md` and `page-template.md` from the library folder (read them; paste, don't summarise);
- the area name, its focus, its source folders (read-only), its drafts folder, and the services (or deploy files)
  this agent covers;
- the never-read globs, verbatim: opening any of them is a failed task;
- the return contract: files written with line counts; per file the citation count and open-question count;
  the 10 most load-bearing facts with citations; contradictions. RAW lists only — a prose summary is a failed task.

A sub-agent may only write inside its own area's drafts folder.

## 3. Adversary gate — before anything is published
For each area, dispatch an independent reviewer (`rules.reviewer` in pair.yaml, default `adversary`; a fresh
sub-agent if no such agent exists) with: the page files, the source folders, and the instruction to pick
`adversary_sample` claims per page at random, open each cited `file:line`, and return per claim
`CONFIRMED | WRONG | UNCITED` with the line it read. A page with any WRONG claim goes back to research once, then
is re-sampled; a page still failing stays a draft and is listed under "not published". The reviewer never sees
the tester's material.

## 4. Publish — only pages that passed
For each passing page, in this order:
1. it carries `verified-at: <source> <commit>` (the pin from step 1);
2. `engram_write` it to the Engram space: title = the page's `# ` title, kind `knowledge`, content = the page;
3. `kr record --page <area>/<file> --event new --sha <commit>` — logs it to the ledger and commits the library;
4. graph: for each link the page states (service ENFORCES its rules page, flow USES service, CALLS, …; only
   relations listed in the plan) run `kr link --from "<title>" --to "<title>" --relation <REL> --evidence "<file:line>"`
   and `engram_link` the same pair.
Then write one index page per area (`concept--index.md`: every page in the area, one line each) and publish it the
same way.

## 5. Prove it
- `kr status` — pages per area, graph size, pins, last log events. Every area should have pages.
- `kr graph` — list the pages no edge touches; link them or say why they stand alone.
- `kr check` — every source `current` (exit 0).
- `<kit>/setup-pair check` — the knowledge items PASS.

## 6. Report to the person (plain words)
Areas built; pages published per area and kind; pages held back and why; graph edges by relation; the Engram
space; the library commit (`git -C <library> log -1 --oneline`). Then: "From now on it grows by itself:
<list the knowledge.grow_on triggers that are on>, following <source <- branch list>."

Never: secrets (name the key and where it comes from, never a value), the tester's scenarios, pages without
citations, publishing a page the reviewer did not sample.

Engram is the memory store named here. What it is and how to reach it is documented in exactly one place: [Engram](../../../starter-kit/instance/AUTHENTICATION.md#engram)
