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
[DESIGN.md](../agent-notepad/DESIGN.md) (§5 topology, §6 file contracts, §7 hooks, §8 cross-repo bridge).

**Consent is load-bearing.** Two actions in this procedure touch the outside world and
MUST NOT run without an explicit yes from the operator, each time:
1. Creating a GitHub repo (`gh repo create`).
2. Bootstrapping a df-context-store into a code repo you don't own the substrate of.
Everything else is local file writes and read-only repo validation.

**Idempotent.** On a re-run in an existing notepad: refresh SCOPE.md / manifest /
CLAUDE.md and re-validate repos, but **never** clobber `NOTES.md` or any journal file —
merge/append only. A second `scope-init` is a safe no-harm refresh.

**A re-run is not a shorter run.** Steps 6 and 6a are per-REPO offers, and the repo set
moves: a repo added to the manifest last month was never offered anything, because it did
not exist when the offers were made. So a re-run walks **every** repo in the manifest, not
only the ones this run created.
⚠️ **First init is the one moment the repo set is complete by accident.** After that, "it was
offered" is a fact about the repos that existed then, and a step that runs only at init
quietly stops covering the estate it claims to — the gap widening in exactly the direction
nobody looks, because the notepad reports success either way.

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

### 6a. Offer a docs-map per repo (CONSENT, per repo)

The push gate (§7.7) blocks an agent `git -C <repo> push` when the push changes a declared
area and no declared doc moved with it. It reads its rules from **`<repo>/.claude/docs-map.json`
— in the CODE REPO, not from this notepad.** For each code repo without one, OFFER to write a
starter map. Ask per repo; wait for a yes.

⚠️ **WHY THE RULES LIVE WITH THE REPO AND NOT IN `repos.manifest.json`.** The manifest is
*objective-scoped*: one notepad per objective, and the same code repo can be driven by two
notepads or by none. Put a repo's doc policy there and the repo acquires two definitions of
done, or zero — which is the one-artifact-two-homes failure this whole model exists to remove,
reappearing one level up. **The notepad answers "which repos am I working on"; the repo answers
"what does this repo require".** Keep those separate.

⚠️ **NO FILE MEANS ABSTAIN, never a default set.** A gate that invents rules for a repo nobody
configured fires wrong on its first run, and a gate that fires wrong is one people learn to
`--no-verify` past. This is the same abstain-by-default the commit gate already uses when a
repo has no `.claude/context/` store.

Shape — globs against the push range `@{u}..HEAD`, each rule `block` or `warn`:

```json
{
  "$comment": "Read by the agent-notepad push gate. Paths are repo-relative globs.",
  "rules": [
    { "when": "skills/*/**",   "requires": ["skills/$1/SKILL.md"], "level": "block" },
    { "when": "services/**",   "requires": ["docs/index.md"],      "level": "block" },
    { "when": "**/migrations/**", "requires": ["docs/*schema*.md"], "level": "block" },
    { "when": "scripts/**",    "requires": ["docs/admin-scripts.md"], "level": "warn" }
  ]
}
```

Propose the starter set from what the repo actually has — do not paste a template. A rule
naming a doc the repo does not contain is a rule that blocks every push on day one.

**Where to draw `block` vs `warn`:** block where a missing doc makes something
**undiscoverable** (a service nobody indexed) or lets **two repos disagree** (a cross-repo
message contract). Warn everywhere else. ⚠️ Do NOT block on files that carry sensitive detail
— a rule forcing a doc edit whenever a strategy or a credential path changes pushes exactly
that content into documentation.

⚠️ **A hook can only prove a doc MOVED, never that it is right.** One whitespace character
passes. This gate catches the mechanical class; a reader catches the semantic one. **Never let
a green push be read as "the docs are current".**

**On a re-run over an existing notepad.** Walk every repo in `repos.manifest.json` — not only
the ones added this run — and offer a starter map for each that has no
`.claude/docs-map.json`. Record each outcome in the manifest under `$docsMapOffers`:

```json
{
  "$docsMapOffers": {
    "$comment": "OFFER HISTORY for this notepad. Not policy — see the caveat in scope-init §6a.",
    "<repo-a>": "written 2026-01-30",
    "<repo-b>": "declined 2026-01-30"
  }
}
```

Skip anything already recorded unless the operator asks to revisit it.

⚠️ **That record is OFFER HISTORY, not policy.** The policy lives in the repo, in its own
`.claude/docs-map.json`. This line exists so the distinction survives the next reader: the
manifest may say *"this notepad asked and was told no"*; it may never say what the repo
requires. The moment it does, the repo has two definitions of done again — the failure §6a
opens by naming, walking back in through the door left ajar for its own bookkeeping.

⚠️ **Ask once, then stop asking.** A prompt that returns on every re-run is trained past within
two sessions, and an operator's "no" is a decision rather than a state to re-litigate. The
decline is recorded for exactly that reason: so it does not have to be given twice.

⚠️ **The gate governs AGENT pushes only** — it is a `PreToolUse(Bash)` hook, so a human's
`git push` in a terminal is untouched. Say so when you offer it; an operator who thinks it
covers their own pushes is worse off than one who knows it does not.

### 7. Warm-start NOTES.md from the repo stores

Build the initial `NOTES.md` (§6.1, ≤150 lines, secrets/PII redacted) from what's already
known: pull the one-line summaries from each repo's `.claude/context/SERVICE-MAP.md` and
recent `FINDINGS.md`, plus the interview answers. Fill Current goal, Repos in scope, Next
action; leave Open threads / Blockers empty if none.
**On re-run: do NOT overwrite an existing NOTES.md** — leave the operator's working memory
intact (append a short "refreshed <date>" note at most).

### 8. Lay down the notepad template

Copy any missing scaffold from `../../plugin/notepad-template/` into the notepad:
`CLAUDE.md` (orientation), `DIGEST.md`, `sessions/index.json`, `handoffs/`,
and `.claude/settings.json` (which arms the PreToolUse commit and push gates).
⚠️ **`DIGEST.md` must NOT be gitignored, and the template no longer ignores it.** That rule
called the file "derived (precomputed cross-scope digest from the memory index)"; the
producer was removed 2026-07-29 and nothing has regenerated it since. It is
hand-maintained now, holds the notepad's standing caveats, and the SessionStart hook
injects it alongside `NOTES.md`. Ignoring it puts those caveats on ONE machine while
every other clone loads nothing where they used to be — strictly worse than the overlong
`NOTES.md` the split exists to relieve. **On an OLDER notepad the rule is still there**:
`git -C <notepad> check-ignore -q DIGEST.md` succeeding means this notepad predates the
fix, and the repair is to delete that line and `git add -f DIGEST.md`. Fill the bracketed
placeholders in CLAUDE.md from the interview. Copy only what's missing; never overwrite
live files.

### 9. Wire best-effort pull/push

Confirm the notepad is a git repo (`git -C <notepad> init` if brand-new) and, if a remote
exists, that the SessionStart pull / Stop push hooks will find it. These are **best-effort**
by design — no remote is a valid, silent state. Do an initial commit of the scaffold
(SCOPE, manifest, CLAUDE, settings, **and `DIGEST.md`**) so the first Stop cycle has a base;
do not commit anything the `.gitignore` excludes.
⚠️ **This line used to say "do not commit `DIGEST.md` (derived)" — fifteen lines below the
warning in step 8 saying it must not be gitignored.** One file, two opposite answers, and
whichever a reader hit first was the one they acted on. A caveat added in one place does not
retire the instruction it contradicts somewhere else.

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
