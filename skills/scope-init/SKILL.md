---
name: scope-init
description: 'Create or refresh an agent-notepad — a per-objective working-memory git repo (one notepad per objective, grouped by name prefix) that survives context compaction and drives several code repos from one session. Runs a short interview (objective, code-repo paths, done-criteria), optionally `gh repo create`s the notepad under the prefix→org map (consent required), writes SCOPE.md + repos.manifest.json, validates each code repo, offers per-repo df-context-store bootstrap (consent), warm-starts NOTES.md from the repo stores, lays down the notepad template, and wires best-effort pull/push. Idempotent: re-running refreshes without clobbering NOTES.md or the journal. Use to start a new objective, spin up a notepad, "init a scope", or onboard an existing directory as a notepad. Triggers on "scope-init", "new notepad", "start a scope", "init working memory".'
---

# scope-init — stand up (or refresh) an agent-notepad

A **notepad** is one standalone git repo per objective, named `<group>-<objective>`
(e.g. `proj-arbbot`). The **group is the prefix** — the substring before the first
hyphen (`proj-basket-tokens` → group `proj`). Code lives in *separate* repos referenced
by `repos.manifest.json` and driven via absolute paths, never by `cd`-ing. This skill
creates that notepad or refreshes an existing one. See the design in
`../../DESIGN.md` (§5 topology, §6 file contracts, §7 hooks, §8 cross-repo bridge).

**Consent is load-bearing.** Two actions in this procedure touch the outside world and
MUST NOT run without an explicit yes from the operator, each time:
1. Creating a GitHub repo (`gh repo create`).
2. Bootstrapping a df-context-store into a code repo you don't own the substrate of.
Everything else is local file writes and read-only repo validation.

**Idempotent.** On a re-run in an existing notepad: refresh SCOPE.md / manifest /
CLAUDE.md and re-validate repos, but **never** clobber `NOTES.md` or any journal file —
merge/append only. A second `scope-init` is a safe no-harm refresh.

---

## Procedure

### 1. Resolve the group prefix and notepad name

- If the operator names the notepad (`proj-arbbot`), take it. Otherwise ask for the
  **objective** in a few words and the **group prefix**, then propose
  `<group>-<slug>` (kebab-case slug of the objective).
- Derive the **group = prefix before the first hyphen**. This is the memory `wing` and
  the org-routing key. Confirm it with the operator before proceeding.
- Read `../../plugin/notepad-template/org-routing.example.json` (or the operator's own
  `org-routing.json` if present) to map prefix → GitHub org. If the prefix isn't in the
  map, ask which org (or fall back to `default_org`) — do not guess silently.

### 2. Offer to create the GitHub repo (CONSENT)

- If the notepad has no remote and the operator wants one, OFFER:
  `gh repo create <org>/<group>-<objective> --private` (org from the prefix→org map).
- **Do not run it until the operator explicitly says yes.** State the exact org, name,
  and visibility you'll use, and wait. If they decline, continue local-only (best-effort
  push simply no-ops with no remote — the SessionStart/Stop hooks tolerate that).

### 3. Micro-interview

Ask three things (accept short answers; don't over-interrogate):
1. **Objective** — what this notepad exists to accomplish (1–3 sentences).
2. **Code-repo paths** — the absolute paths of the repos this objective drives, each
   with its working branch and a role (`primary` / `support` / …).
3. **Done-criteria** — 1–N testable conditions that mean the objective is complete.

### 4. Write SCOPE.md + repos.manifest.json

- **SCOPE.md** (the stable charter, §6.5): fill Objective, Done-criteria (as a `[ ]`
  checklist), and the optional repo subset from the interview. Rewrite freely on re-run —
  SCOPE is the part that *doesn't* change per cycle, but it's safe to revise here.
- **repos.manifest.json** (§6.4): one entry per code repo
  `{"path","branch","role"}`, plus `"requires_df_context_store": true` unless the
  operator opts a repo out. This is the authoritative repo list; NOTES.md only mirrors it.

### 5. Validate each code repo

For every manifest entry, confirm the path (a) exists, (b) is a git repo
(`git -C <path> rev-parse --is-inside-work-tree`), and (c) capture its current branch
(`git -C <path> rev-parse --abbrev-ref HEAD`) — record that branch back into the
manifest entry. If a path is missing or not a git repo, surface it to the operator and
either fix the path or drop the entry; don't silently keep a broken repo in scope.

### 6. Offer df-context-store bootstrap per repo (CONSENT, per repo)

For each code repo, check for `<repo>/.claude/context/`. If absent and
`requires_df_context_store` is true, OFFER to bootstrap it with the `df-context-store`
skill (that plants SERVICE-MAP / DATA-FLOW / FINDINGS / DECISIONS + the commit gate).
**Ask per repo; wait for a yes before writing into a repo you didn't create.** If the
operator declines, note it — a missing store just yields a SessionStart warning, not a hard
failure.

### 7. Warm-start NOTES.md from the repo stores

Build the initial `NOTES.md` (§6.1, ≤150 lines, secrets/PII redacted) from what's already
known: pull the one-line summaries from each repo's `.claude/context/SERVICE-MAP.md` and
recent `FINDINGS.md`, plus the interview answers. Fill Current goal, Repos in scope, Next
action; leave Open threads / Blockers empty if none.
**On re-run: do NOT overwrite an existing NOTES.md** — leave the operator's working memory
intact (append a short "refreshed <date>" note at most).

### 8. Lay down the notepad template

Copy any missing scaffold from `../../plugin/notepad-template/` into the notepad:
`CLAUDE.md` (orientation), `DIGEST.md` placeholder (gitignored/derived),
`sessions/index.json`, `handoffs/`, and `.claude/settings.json` (which arms the
PreToolUse commit gate — §7.6). Fill the bracketed placeholders in CLAUDE.md from the
interview. Copy only what's missing; never overwrite live files.

### 9. Wire best-effort pull/push

Confirm the notepad is a git repo (`git -C <notepad> init` if brand-new) and, if a remote
exists, that the SessionStart pull / Stop push hooks will find it. These are **best-effort**
by design — no remote is a valid, silent state. Do an initial commit of the scaffold
(SCOPE, manifest, CLAUDE, settings) so the first Stop cycle has a base; **do not** commit
`DIGEST.md` (derived) or anything the `.gitignore` excludes.

---

## Done when

SCOPE.md + repos.manifest.json exist and validate, every in-scope repo is confirmed
git + branch-captured, NOTES.md is warm-started (or preserved on re-run), the template
scaffold is present, and the notepad is a git repo wired for best-effort sync. Report to
the operator: the notepad path, the group/wing, the repos in scope (with branches), which
consent actions ran vs were declined, and the single next action.

## Guardrails

- Consent gates (§2 gh-create, §6 df-context-store) never fire without an explicit yes.
- Re-runs refresh; they never clobber NOTES.md or the journal.
- Repo validation is read-only. Never `cd` into a code repo — reason via absolute paths.
- Keep NOTES.md ≤150 lines and redacted; never compress away a caveat.
