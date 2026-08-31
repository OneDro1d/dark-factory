# agent-notepad — persistent, per-objective working memory for coding agents

**Status:** Design (build in progress) · **Origin:** genericized from a Loom-specific design, 2026-07-10 · **DF stage:** companion to `df-context-store` (Stage 0.5). Evolves and subsumes `handoff-auto`.

> ⚠️ **PARTIALLY SUPERSEDED, 2026-07-29 / 2026-08-03.** The **episodic memory index** tier
> described below (U6 adapter, Stop write-mirror, digest builder) is **gone**. The reference
> implementation it named was removed 2026-07-29, and its code — `bin/mp-adapter.py`,
> `hooks/mirror-guarded.sh` and their two tests — was deleted 2026-08-03 rather than left
> disabled, because a neutered call to a missing tool is exactly what a reinstall
> resurrects.
>
> **What survives:** the notepad model (§ scope, NOTES.md, `sessions/*.jsonl` journal,
> `index.json`), the SessionStart/Stop hooks, the commit gate, and git as the sync mechanism.
> **What replaces the episodic tier:** durable memory goes to [Engram](../../starter-kit/instance/AUTHENTICATION.md#engram) by deliberate
> `engram_write`; session continuity lives in `NOTES.md` + `handoffs/`.
>
> This document is kept as the design *record*. Sections describing the index tier are
> history, not instructions — do not implement them.

---

## TL;DR

`agent-notepad` gives a coding agent a **per-objective working-memory notepad** — one standalone git repo per objective ("notepad"), grouped only by a name prefix — that survives context compaction and spans multiple code repos from a single session. Each notepad holds continuous **Notes** (`NOTES.md` + an append-only JSONL journal) auto-loaded on start, deliberate **Handoffs** (structured docs) on demand, and a precomputed cross-scope **digest** built from an episodic memory index. Concurrent objectives never collide (separate folder + cwd + git repo). Code lives in separate repos referenced by a manifest and driven from the notepad without `cd`-ing. Memory-index usage and code-commit governance are enforced by hooks, not left to agent discretion.

Product = **a Claude Code plugin** (hooks + skills + notepad-template + a small Python memory adapter). No binary, no daemon.

## 1. Problem

An agent operator runs several concurrent agent sessions, for days, each on a distinct objective. Naive auto-handoff (e.g. `handoff-auto`) keys by cwd → one rewritten file → **no session identity** (parallel sessions clobber), **no history** (rewrite not append), **single-repo** (no cross-repo context). Needed: a short-term, persistent, auto-loaded **working memory** that complements a curated long-term store (which structurally misses recent detail); survives compaction; keeps history; spans several repos from one session; syncs across machines.

## 2. Goals / Non-goals

**Goals:** concurrent objective-scoped sessions with zero contention (file *and* git level) · append-only history · cross-repo context with no manual `cd` · memory index demonstrably used, enforced · code-commit governance enforced · survive compaction, enable `/clear` instead of `/compact` · cross-device sync · reuse `handoff-auto`, `df-context-store`, an episodic memory index, git.

**Non-goals (YAGNI):** no new DB/service (files are truth) · no live context-% trigger (not exposed to hooks) · no automatic `/clear` (agent/human habit) · no group folder or shared mutable files · no replacement of the curated store · no cross-*group* auto-sharing in v1.

## 3. Pluggable seams (what makes it generic)

- **Episodic memory index** — the cross-scope index. **Reference implementation: MemPalace** (proven CLI, §7). The adapter (U6) is the only component that knows the concrete index; swapping it (e.g. a vector DB, Engram, a local embedding store) touches only U6.
- **Curated long-term store** — optional, pluggable (Engram in the reference deployment).
- **Prefix→git-org routing** — a config map (`org-routing.json`), not hardwired.
- **Per-repo context store** — `df-context-store` in the reference; any code-anchored store with `SERVICE-MAP`/`FINDINGS` works.

## 4. Architecture — four layers

| Layer | Unit | Lives in | Anchored to | Tooling |
|---|---|---|---|---|
| **Working memory (Notes)** | objective | the notepad repo | the *task* | **agent-notepad (this)** |
| **Per-repo context store** | repo | `<code-repo>/.claude/context/` | *code* (`file:line`) | df-context-store |
| **Episodic index** | all scopes (by prefix) | the memory index (MemPalace) | journals | mirror + digest (this) |
| **Curated** | cross-project | the long-term store | distilled | existing |

## 5. Topology — flat, one repo per scope, grouped by prefix

**Each scope = one standalone git repo** ("notepad"), named **`<group>-<objective>`** (e.g. `proj-arbbot`, `proj-bugs`). No group folder, no shared mutable files. The "group" is the **prefix** (substring before the first hyphen; `proj-basket-tokens` → group `proj`).
- **Org routing by prefix:** configured in `org-routing.json`.
- **Memory grouping:** `wing=<prefix>`, `room=<full-repo-name>`.
- **Concurrency-safety all the way down:** separate folder (no `NOTES.md` clobber) + separate cwd (right notepad resolves) + separate git repo (no git-index contention).

**Notepad layout (self-contained):**
```
proj-arbbot/
  CLAUDE.md            # orientation: objective, repos-in-scope, read-first/dispatch rules
  NOTES.md             # compact working memory, auto-loaded (§6.1)
  SCOPE.md             # charter: objective, done-criteria, repo-subset (§6.5)
  DIGEST.md            # was: derived from the memory index, gitignored. SUPERSEDED — see the
                       # banner: the producer is gone, so the file is hand-maintained and COMMITTED
  repos.manifest.json  # the CODE repos this scope drives (§6.4)
  sessions/
    index.json         # session metadata index (§6.3)
    <ISO8601>_<id>.jsonl   # append-only journal, one file per session (§6.2)
  handoffs/            # deliberate structured handoff docs (§6.7)
  .claude/settings.json  # session hooks incl. the commit gate (§7)
```

## 6. File contracts

- **6.1 `NOTES.md`** — compact working memory, rewritten in place, ≤150 lines, secrets/PII redacted. Sections: Current goal · Repos in scope · Last decisions · Next action · Open threads · Key refs (`repo:file:line`) · Blockers. Auto-loaded every start.
- **6.2 Journal `sessions/<ISO8601>_<id>.jsonl`** — append-only, new file per session. Event: `{"ts","kind":"decision|finding|command|file-touch|milestone|note","text","refs":[...],"commit":"<sha|null>","session"}`. Writers: deterministic Stop hook (mechanical traces + commit SHA) + the agent (semantic entries). Retention: prune > 90 days OR > 500 files.
- **6.3 `sessions/index.json`** — `[{sessionId,startedAt,lastInteractionAt,journalFile,turns}]`, upserted by the Stop hook.
- **6.4 `repos.manifest.json`** — `{"repos":[{"path","branch","role"}],"requires_df_context_store":true}`. Every repo should hold a context store; missing = SessionStart warning.
- **6.5 `SCOPE.md`** — Objective · Done-criteria · Repo subset (optional).
- **6.6 `DIGEST.md`** — auto-loaded, ≤60 lines. ⚠️ **SUPERSEDED**: "derived/gitignored" described the removed digest builder. Hand-maintained and **committed** since 2026-07-29 — it carries the standing caveats, and ignoring it leaves them on one machine.
- **6.7 `handoffs/<date>-<topic>.md`** — deliberate structured docs; creating one **forces a `git push`**.

### 6.8 Formats & rationale
Format follows the *consumer* (read-as-context by the model vs parsed-by-code by a hook): **Markdown** for context-loaded files (`NOTES`/`DIGEST`/`SCOPE`/`CLAUDE`/`handoffs`/per-repo store) — the parser is the model, zero-overhead context. **JSONL** for the journal (append + `jq`-filter). **JSON** for config (`manifest`, `index.json`, `org-routing`). **Graph** relationships → the memory index's graph + the curated store's graph, **not a repo format**. **No SQL.** `NOTES.md` stays terse-markdown, never a compressed dialect, never compresses away a caveat.

## 7. Hook set — enforcement (extends `handoff-auto`)

1. **SessionStart — restore + auto-pull (READ end):** best-effort `git pull` (non-blocking) → read `NOTES.md` + `DIGEST.md` + `repos.manifest.json` + per-repo context-store pointers → inject via dual-field JSON. **File reads only** (~1–3 s budget; no live search — digest is precomputed). Degrades to `handoff-auto` behavior outside a notepad.
2. **Stop — journal + mirror + sync (WRITE end):** append deterministic journal entries → upsert `index.json` → **mirror new entries into the memory index** (`mempalace mine <notepad>/sessions/` or the venv-python adapter, `wing=<prefix>`, `room=<repo>`) → best-effort `git push`. Guarantees the index is *written* every cycle.
   ⚠️ **Historical from here on.** The named implementation was removed 2026-07-29 — see the banner at the top of this file. What follows is the DESIGN, and the tool is not the current one. Said again here because a reader arriving at a section does not see a banner nine screens up — the same reason CI names its own limitation in a step title and not only in a job summary.
3. **Digest builder — async, off critical path:** `mempalace search "<objective>" --wing <prefix>` → rewrite `DIGEST.md`. Guarantees the index is *queried* every cycle. Trigger: debounced Stop or scheduled job.
4. **UserPromptSubmit — live Notes refresh:** soft nudge to keep `NOTES.md` current; backed by the Stop floor.
5. **PreCompact — floor (kept):** deterministic snapshot into `NOTES.md` + journal.
6. **PreToolUse(`git commit`) — code-commit gate:** lives in the **notepad**'s `.claude/settings.json`; intercepts each `git -C <code-repo> commit` and applies the df-context-store staleness check. **Boundary:** governs *agent* commits, not manual human commits (for those, arm that repo's native git hook).

**"Actually used" triangle:** write-mirror (2) + async digest (3) + fast read (1). The index is exercised at both ends by hooks; the read path stays a cheap file read.

## 8. Cross-repo, no-`cd` execution (df-context-store bridge)

Every manifest repo is `df-context-store`-bootstrapped (per-repo consent). A session reads each repo's `SERVICE-MAP`/`FINDINGS` first instead of re-scanning, and dispatches that repo's agents. The agent works across repos via **absolute paths** and commits via **`git -C /path/to/code-repo commit`** (gated by §7.6), recording the SHA in the journal. Two commit streams: **code → code repos** (governed) and **Notes → the notepad** (best-effort sync). No manual `cd`.

## 9. `/handoff` — retargeted
Reserved for the big structured doc. Publishes into `<notepad>/handoffs/<date>-<topic>.md` and **forces a `git push`**. The continuous tier is **Notes** (`NOTES.md` + journal), which `/handoff` summarizes but does not replace.

## 10. Routing table
Ephemeral/task-progress → `NOTES.md`. Durable/code-anchored/one-repo → that repo's `FINDINGS`/`DECISIONS` (via context-management). Cross-scope episodic (same prefix) → memory index (mirror + digest). Deliberate handoff → `handoffs/` + remote. Distilled/canonical → curated store.

## 11. Enforcement gates
1. **Memory-index usage** (§7.2/7.3): hooks guarantee write + query every cycle.
2. **Code/context lockstep** (§7.6): the notepad's PreToolUse gate blocks agent code-commits that drift from the code repo's store.

## 12. Relationship to `handoff-auto` + `/clear`
Evolution: `handoff-auto` machinery becomes the **Notes** tier (`NOTES.md` + journal); its hooks are extended; the PreToolUse commit gate is added. Outside a notepad, behavior degrades to today's. `/clear` instead of `/compact`: `NOTES.md` + journal + digest fully re-hydrate → lossless-by-design (human habit; no ctx-% trigger). Recency gap closed: the digest is built from the recent journal index.

## 13. Design units (for isolation & independent build)

| Unit | Purpose | Depends on |
|---|---|---|
| **U1 Notepad model** | repo layout + file schemas (§5–§6) | — |
| **U2 SessionStart restore + pull** | inject Notes+digest+manifest; best-effort pull | U1 |
| **U3 Stop write + mirror + push** | append journal/index, memory mirror, best-effort push | U1, U6 |
| **U4 Digest builder** | build `DIGEST.md` from `wing=<prefix>` | U1, U6 |
| **U5 Code-repo bridge** | df-context-store files + manifest load | U1, df-context-store |
| **U6 Memory adapter** | shell-callable mirror + search over the index (MemPalace ref impl) + stub mode | memory index |
| **U7 `/scope-init`** | gh-create (consent), interview, bootstrap code repos (consent), warm-start `NOTES.md`, derive prefix wing, wire sync | U1, U5, gh |
| **U8 Commit gate** | PreToolUse staleness check on `git -C … commit` | U5 |
| **U9 `/handoff` retarget** | publish to `handoffs/` + force push | U1 |
| **U10 Packaging** | plugin manifest + installer + `notepad-template/`; supersedes/uninstalls `handoff-auto` | all |

## 14. U6 feasibility — RESOLVED GREEN + mirror mechanism verified (2026-07-10)
MemPalace ships a CLI (`a local venv CLI`) with `mine <dir>` (ingest → WRITE) and `search "q" --wing X` (→ READ). Shell → memory-index is a first-class supported path (MemPalace ships a production Stop hook). No network, no MCP dependency in the hook, no build toolchain. The adapter (U6) wraps this behind a stub-able interface so the rest is testable without a live palace.

**Mirror mechanism (verified live, isolated `--palace`):** two facts drive the design —
1. `mine` **skips raw `.jsonl`** (`init` reports "0 files" on a journal dir); it ingests text/Markdown docs ≥ a min size.
2. `mine` sets **`wing` = the mined dir's basename**, not an explicit flag.

So `op_mirror` renders the journal into a **Markdown digest** under a staging dir **named as the `<prefix>`** (`<notepad>/.anp-mirror/<prefix>/<notepad>.md`), then `init --yes` + `mine` that dir → the entry is filed under **`wing=<prefix>`**, `source=<notepad>.md` (the scope). Verified end-to-end: `mirror` then `search --wing <prefix> --query <sentinel>` returns the mirrored content (`test_live_roundtrip.sh`, isolated temp palace, real CLI). The naive `mine <notepad>/sessions` (wing=`sessions`, 0 files) would have silently no-op'd — caught by the live round-trip, not the stub. Palace targetable via `AGENT_NOTEPAD_MEMPALACE_PALACE` (test isolation).

## 15. Build notes (from prior handoff-auto build)
- **Install to a STABLE runtime path** (`~/.claude/hooks/agent-notepad/{hooks,lib}`), copied by the installer — NOT the repo path (branch-fragile).
- Generic Notes hooks live **user-level** (cwd-detect + degrade like `handoff-auto`); the **commit gate ships in the notepad template's `.claude/settings.json`** (arms only in notepad sessions). Claude Code merges user + project hooks.
- Hook recipe: read JSON from stdin (`jq`/python), output `{}` (allow) or `{"decision":"block","reason":...}`, **exit 0 always**, `chmod +x`, pipe-test each hook.
- **Redaction tests trip GitHub push-protection** on secret literals → split token prefixes at runtime in test fixtures.
- SessionStart hooks inject only non-discoverable + stable info; read a precomputed file, never compute.

## 16. Acceptance criteria (testable)
1. Two concurrent sessions in `proj-arbbot` and `proj-bugs` each read/write their own `NOTES.md`; independent git commit streams; no overwrite.
2. A new session → a **new** `sessions/*.jsonl`; prior journals untouched.
3. SessionStart injects `NOTES.md`+`DIGEST.md` < 3 s incl. non-blocking pull.
4. After a Stop, just-written journal entries are retrievable via `mempalace search` (write-mirror proof).
5. Regenerating a digest issues ≥1 `mempalace search --wing <prefix>` and reflects a sibling's recent activity (query proof).
6. *(Moved to §17 — df-context-store's responsibility, not an agent-notepad criterion.)* A finding recorded via `knowledge-keeper` appears in the target code repo's `FINDINGS.md`, visible to a *different* scope without a search.
7. An agent `git -C <code-repo> commit` that drifts from the store is **blocked** by §7.6; a compliant commit passes.
8. `/handoff` writes `handoffs/<date>-<topic>.md` **and** pushes to remote.
9. In a non-notepad cwd, behavior matches `handoff-auto` (regression).
10. `/clear` then a fresh session restores goal + next-action from `NOTES.md` alone (lossless rehydrate).
11. U6 adapter passes in **stub mode** (no live palace) and in **live mode** (real `mempalace`).

## 17. Out of scope (v1)
Cross-group auto-sharing; automatic `/clear`; a GUI; governing manual human code-commits (agent commits only); signed/provenance journals (v2, via a signed-provenance substrate); conflict-free multi-machine concurrent editing of the *same* scope (v1 = append-only + last-writer-wins on `NOTES.md`).
