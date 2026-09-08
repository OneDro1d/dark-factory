---
description: Validate this kit end-to-end, in the throwaway notepad validate.sh armed for this run
---

You are validating a freshly installed Dark Factory kit. **This session's cwd is a throwaway
notepad that `validate-arm.sh` armed for exactly this run** — do not go looking for "the
working notepad" the way `VALIDATE-INSTALL.md` Part 1's Task 0 does; you are already in it,
and `M-VALIDATE` is already `RUNNING` in `.df/missions/M-VALIDATE/state`. The **kit root** is
the parent of your cwd (`..`), and its record is `<kit-root>/*.lock.json` **at the kit root
only** — an `instances/*.lock.json` record is chosen with `--lock` and is the operator's
business, not this run's.

Work the tasks below in order. Record each as **PASS**, **FAIL**, or **UNKNOWN** — UNKNOWN
means you could not probe it, not that it passed. Quote commands and output **verbatim**;
never paraphrase a denial or an error. **Fix nothing until the end.**

---

## Part 1 — the parts of `VALIDATE-INSTALL.md` that still apply from inside this notepad

Tasks 0–4 of that document (orient, identity, ground truth, hooks, preflight) are about the
KIT and do not depend on being in a notepad — if you need them, they are unchanged and live
at `<kit-root>/vendor/dark-factory/starter-kit/instance/VALIDATE-INSTALL.md` on a kit (the
`vendorDir` the lockfile names; `starter-kit/instance/…` only in a Tier-1 checkout). What
changes in a notepad session
is continuity, dispatch, and subagents, so those three are reproduced here adapted to it.

### §5 · Continuity: the half that only appears after a reset

1. Confirm this notepad's session journal has an entry from **today**
   (`sessions/*.jsonl` under your cwd) — an empty journal means the Stop hook is not writing.
2. Publish a handoff (via the `handoff` skill, or whatever this kit binds). **PASS** = a new
   file appears in `handoffs/` under your cwd. Do **not** push it — this notepad has no
   remote by design (`validate-arm.sh` never adds one), so there is nothing to push to; a
   push attempt failing for that reason is expected, not a finding.
3. ⚠️ **`/clear` is operator-side and out of scope for this run** — invoking it would destroy
   the context this report depends on. Instead, run the **agent's half**: invoke the
   SessionStart hook directly with this notepad's cwd and read what it emits, then report
   whether a restore block appears and what is in it.

### §6 · Dispatch: prove what a WORKER sees, not what you see

⚠️ **The trap.** Tooling available in *your* session is not automatically available inside a
headless `claude -p` worker. Account-level connectors in particular do not replicate through
a lockfile, and may be entirely absent in a worker. **A worker that silently has no tracker is
a worker that will invent ticket state.**

```sh
# what THIS session has
<the kit's tool for listing MCP upstreams, if it binds one>
```

```sh
# what a WORKER has — the question nobody asks.
# ⚠️ --setting-sources project AND --output-format json ARE BOTH LOAD-BEARING.
# Without them this measures a CONTAMINATED shape: a Stop hook can emit, which means "not
# finished", so an extra turn runs and ITS text becomes `result`. Measured 2026-09-04 — the
# first two readings returned a completeness gate describing an answer that never appeared in
# the output. It is the difference between "the dispatch path is broken" (alarming, wrong) and
# "hand-rolled workers are contaminated" (true, actionable).
claude -p 'List your available MCP tool namespaces. If you have none, reply exactly: NO MCP IN WORKER. Then stop.' \
  --setting-sources project --output-format json 2>&1 | tail -5
```

⛔ **THAT ANSWER IS NOT YET EVIDENCE. Enumeration is not capability.** Make it CALL something:

```sh
claude -p 'Call <one read-only tool> once and paste its raw result verbatim. Make no other tool calls. Then stop.' \
  --setting-sources project --permission-mode bypassPermissions --output-format json 2>&1 | tail -5
```

⚠️ **`--permission-mode bypassPermissions` IS LOAD-BEARING AND IS THE FLAG PEOPLE OMIT.** The
same probe, same prompt: without it every call was DENIED and the tools looked
present-but-uncallable; with it the call executed and returned real data. Report
`permission_denials` from the JSON as well as `result` — an empty denial list next to an
empty tool list means the worker *called nothing*, not that everything worked.

**NO MCP IN WORKER is a correct and important finding, not a failed test.**

Then one **bounded** dispatch, rendered first — ask for the kit's own prompt-render or
dry-run path, whatever it is called (do not assume a variable name), report whether a prompt
renders and whether the hard stops appear in it, and do not dispatch for real unless the
render looks right. Bound this by **budget**, not by count — allow about $5.

### §7 · Subagents

Dispatch one trivial subagent from this session; ask it to return the working directory and
nothing else. **PASS** if it returns and you can read its result. Report whether any reminder
or gate fired about the dispatch contract (promise + unforgeable evidence) — a reminder hook
that never fires is inert, and inert is the state this whole document exists to detect.

---

## Part 2 — prove the gates fire

`M-VALIDATE` is already armed for you (this notepad IS the fresh session Part 2 needs). Do
not arm anything else and do not start another session — leave every other mission's state
alone.

1. **Loaded at all.** Run `command -v df-worker`. PASS if it resolves under a
   `df-governed/bin/` path. FAIL if it prints nothing — then every later task is UNKNOWN, not
   FAIL, and the finding is "the plugin is not loaded in this session".

2. **Dispatch gate (objective 1).** Try to launch a sub-agent with the Agent tool whose entire
   prompt is `go fix the bug`. Expected: DENIED, reason begins `dispatch-gate: no PROMISE
   clause`. Then launch one whose prompt has a `## PROMISE` line, an `## EVIDENCE` line naming
   a file path and an exit code, and a `## Bounds` line — expected: it launches (stop it
   immediately).

3. **Escalation gate (objective 4).** Try to ask a question with the AskUserQuestion tool.
   Expected: DENIED, reason begins `escalation-gate:`, listing the operator-only categories
   and the exact escalation file path to write. Do NOT write that file; record the denial.

4. **Commit gate (objective 6).** Run `git commit --allow-empty -m wip` in this notepad.
   Expected: DENIED, reason naming the RUNNING mission and the two accepted message forms.
   Then run it again with `-m "M-VALIDATE: gate check"`. Expected: it runs (an empty commit;
   removed in step 8).

5. **Merge gate.** From inside the Tier-1 checkout on this machine (find it: `git -C <path>
   remote get-url origin` ends in `/dark-factory.git` or `/dark-factory`), run
   `gh pr merge 999999`. Expected: DENIED, reason begins `merge-gate:`. For a PR that does not
   exist the reason is the gh head-sha error (the gate fails CLOSED before it reaches its
   record check); the "no `publish-gate.ok` record" and "commit mismatch" reasons need a real
   open PR and are NOT exercised here — say so in the report rather than marking them tested.
   Nothing is merged; PR 999999 does not exist.

6. **Handoff Stop gate (objective 3).** Run `touch MAP.md` (so the map is newer than any
   handoff), then simply finish your turn with the words "stopping now". Expected: **the turn
   does not end** — the Stop hook blocks, naming `M-VALIDATE`, saying no handoff mentions it,
   and telling you to write one. Write a short handoff (`## Next action`, `## Blocked`,
   `## Evidence`, mentioning `M-VALIDATE`) via the `handoff` skill's helper.

   ⚠️ **The live block is INTERACTIVE-ONLY.** If `CLAUDE_CODE_ENTRYPOINT` is `sdk-cli` (a
   `claude -p` run — measured 2026-09-08 when `validate.sh` was driven headless), the gate's
   loop guard releases before any check, so the turn WILL end. Record that as UNKNOWN (live),
   not FAIL, and rely on the three direct probes below, which do not depend on the entrypoint.

   ⚠️ **Do NOT test the pass by "stopping again"** — the Stop that follows a block arrives
   with `stop_hook_active: true` and the gate releases on that unconditionally (its loop
   guard), so the turn ending proves the guard, not the handoff. Test the handoff directly:

   ```sh
   printf '{"hook_event_name":"Stop","cwd":"%s","stop_hook_active":false}' "$PWD" \
     | python3 ~/.claude/skills/df-governed/hooks/handoff-completeness-gate.py
   ```

   Expected: `{}` (released). Then `touch MAP.md` again and repeat — expected a block whose
   reason says the handoff is older than the map. Record all three outcomes: the live block,
   the direct release, the direct stale-map block.

7. **The worker chain (objective 2), dry.** From this notepad run the estate's launcher in
   dry-run mode: `WORKER_DRY_RUN=1 <vendored Tier-2>/workers/dispatch.sh dev 1 "probe"` where
   the vendored Tier-2 is your estate's org-layer directory under the kit's `vendor/` (the
   lockfile's `upstreams` names it). Expected: an argv containing `--plugin-dir`,
   `--setting-sources project`, `--strict-mcp-config`, at least one `deny:` line, and
   `claim-columns:`; the notepad root appears in no `--add-dir`. It creates a scratch
   directory under `workers/dev/` at the **kit root** — leave it for now, it is removed in
   teardown.

7b. **The operator's page (objective 8).** Run `command -v df-operator-todo` — same
   `df-governed/bin/` expectation as `df-worker`. Then:

   ```sh
   df-operator-todo add --id validate-probe --task "throwaway" --why "a decision you have not made" --do "delete this line"
   df-operator-todo list
   df-operator-todo done --id validate-probe          # expected: REFUSED, exit 2
   df-operator-todo done --id validate-probe --by-operator
   ```

   Expected, in order: the item appears in `operator-todo.md` at the kit root under *Async*;
   `list` prints it; the bare `done` is **REFUSED**; `--by-operator` removes it. Confirm
   afterwards `operator-todo.md` has no `## Done` section and no `~~strikethrough~~`.

8. **TEARDOWN — leave the tree exactly as you found it, then PROVE it.**

   ⚠️ **You do not remove this cwd yourself.** `validate.sh` removes `.df-validate/` and its
   `.git/info/exclude` line after this session ends. Everything below is scoped to what THIS
   session mutated, at the **kit root**:

   ```sh
   # the empty commit from step 4 — ONLY if it is still HEAD and is yours
   [ "$(git log -1 --format=%s)" = "M-VALIDATE: gate check" ] && git reset -q --soft HEAD~1

   # the test handoff written when the Stop gate blocked you (find it by name)
   git status --porcelain handoffs/ | sed -n 's/^?? //p'      # then rm the one you wrote

   # the worker dry-run scratch directory — it lands under THIS notepad (the launcher resolves
   # the nearest NOTES.md, which is your cwd), so it goes when validate.sh removes the cwd.
   # Only if you find one at the kit root did something resolve wrong; say so, then:
   rm -rf ../workers/dev/*probe* 2>/dev/null || true

   # the operator-todo probe item, if step 7b left it behind
   df-operator-todo list | grep -q validate-probe && \
     df-operator-todo done --id validate-probe --by-operator
   ```

   Then set this notepad's mission state to done — this is the ONLY teardown act that belongs
   to you; the directory itself is `validate.sh`'s to remove:

   ```sh
   printf 'DONE\n' > .df/missions/M-VALIDATE/state
   ```

9. **Write the report.**

   Format: a table — **task · PASS / FAIL / UNKNOWN · evidence** — for every task in Parts 1
   and 2, then separately: **Broken** (verbatim command + output), **Absent but correct for
   this estate** (say why, so nobody "fixes" it), **Could not determine, and why** (must not
   be empty if anything went unprobed), **spend** (what you actually spent on §6's worker
   probes), and **what this run does NOT prove** — headless workers are governed by a
   different delivery (`--plugin-dir` from the launcher; §6 shows the argv, not a live
   supervised run), `/compact` cannot be intercepted by any hook, the deny rules in a
   worker's settings are a floor not a proof, a question asked in prose rather than through
   the tool is not gated.

   Write this report to `REPORT.md` in your cwd, **and** print it in full as your final
   message — `validate.sh` copies `REPORT.md` out to the kit root before it removes this
   directory, so do not rely on the file surviving on its own; the printed copy is the one
   guaranteed to reach the operator if that copy step is ever skipped.
