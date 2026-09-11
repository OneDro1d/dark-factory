# VALIDATE — prove the kit actually works, after installing it

**Paste the block below into a fresh agent session on the machine you just installed.**
It is the by-hand form of START-HERE.md step 6: `validate.sh` runs this same check in a fresh
session and commits the report itself. `bootstrap.sh` copies this file into every kit it makes;
a kit made any other way carries it inside `vendor/dark-factory/starter-kit/instance/`.

⚠️ **WHY THIS EXISTS, AND WHY IT IS NOT A CHECKLIST OF FILES.** This method's recurring defect is
a component that is DECLARED, INSTALLED, and wired to nothing — every check that looks for a
*file* passes while the thing does nothing. Measured examples, all from real installs:

- a `PreToolUse` gate referenced by eight notepads and installed by none. A missing hook command
  **fails open**: nothing blocks, nothing errors, and the only signal is a warning people skim.
- a retired skill left as a live symlink into a deleted directory, loaded every session.
- a hook installed and never named in any `settings.json` — present, and inert.
- a checker that reported CLEAN over a planted canary because its patterns had gone stale.

So every task below **makes the machinery run and reads its output**. Tasks that only prove a
file exists have been deliberately left out — they are the checks that were already passing while
the estate was broken.

⚠️ **AND IT ASSUMES NOTHING ABOUT WHERE ANYTHING SITS.** Layouts differ per estate and per person:
kit roots, record filenames, whether the engine is on `PATH` at all. **Self-orientation is Task 0
and it is a real test** — if the session cannot work out what it is looking at, that is the first
finding, not a reason to hardcode a path and continue.

---

You are validating a freshly installed Dark Factory kit on this machine.

Work the tasks in order. **Fix nothing until the end** — a repair mid-run changes what the later
tasks measure. Record every result as **PASS**, **FAIL**, or **UNKNOWN**, and keep those three
apart: *UNKNOWN means you could not probe it, which is not evidence that it works.* Quote commands
and output **verbatim**; never paraphrase an error.

Before running anything: read this kit's own `START-HERE.md` and any estate binding it names, and
obey the hard stops you find there. If you find none, say so — that is itself a finding.

## 0 · Orient: work out what you are looking at

Nothing below hardcodes a path. Discover, and report what you found.

```sh
# the kit root is wherever the lockfile is — walk up from here
d="$PWD"; while [ "$d" != "/" ]; do ls "$d"/*.lock.json >/dev/null 2>&1 && { echo "KIT ROOT: $d"; ls "$d"/*.lock.json; break; }; d="$(dirname "$d")"; done
```

⛔ **The walk-up finds the NEAREST record, which is very often the WRONG one.** Measured
2026-09-04: on a kit with per-machine records under `instances/`, it stopped at the repo root's
lockfile — which described a **different machine entirely**. Validating against that would have
been precisely the failure Task 1 exists to catch.

**So do not derive the record from proximity. Ask the engine, which lists and refuses to pick:**

```sh
<engine>/identify.sh --match <kit-root>/instances
```

⚠️ The collision is live, not theoretical: one workspace NAME can exist on two deployments, so
two records differ only in their `deployment` field. Proximity cannot tell them apart and neither
can a name.

```sh
# the engine may be on PATH, at the kit root, or only inside the vendored upstream
command -v df-preflight || echo "df-preflight: not on PATH"
command -v df-mission   || echo "df-mission: not on PATH"
# ⚠️ NO DEPTH CAP. A `-maxdepth 4` here printed nothing on a real kit because the engine sits at
# depth 5 under vendor/ — and "nothing" reads as "no engine on this machine".
find . -path '*/boot-kit/scripts/identify.sh' -not -path '*/node_modules/*' 2>/dev/null | head
find . -path '*/boot-kit/scripts/lock-verify.sh' -not -path '*/node_modules/*' 2>/dev/null | head
```

Report: the kit root, the lockfile name(s), and where the engine actually resolves.

⚠️ **A record's filename is not fixed.** At least one kit in this estate names its lockfile
something other than `loom.lock.json`, and a sweep that globbed for that name missed it for three
weeks. Use what you found; do not assume.

⚠️ **The engine being absent from `PATH` may be correct.** Some estates' installers deliberately
ship no operator CLI, and the engine then lives only under the vendored upstream. Report which
situation you are in — do not install anything to "fix" it.

**FAIL** here if you cannot locate a lockfile at all. Stop and report; everything below depends on
knowing which record describes this machine.

## 1 · Identity: does this record describe THIS machine?

Using the paths you just found:

```sh
<engine>/identify.sh                       # what am I?
<engine>/identify.sh --lock <the record>   # does the record agree?
```

- **PASS** — `matches this machine`, exit 0.
- ⚠️ Then make it **disagree on purpose.** Point it at a *different* record (`--match <dir>` will
  list the candidates; it never picks one for you) and confirm it exits **3** with
  `DIFFERENT MACHINE`. **A check that cannot disagree agrees with everything**, and this one
  exists because two machines with the same workspace name installed each other's environments
  and both reported success.
- ⚠️ If it reports `MEASURED FOR A DIFFERENT INSTANCE`, the record was copied from another machine
  rather than measured here. Report it; do not edit the name to silence it.

## 2 · Ground truth: does the machine match its lockfile?

```sh
<engine>/lock-verify.sh --lock=<the record>
```

Report the **verdict line** and **every layer that is not PASS, by name**. The layers each answer
a different question; "some drift" is not a report.

⚠️ **`unknown` is not a synonym for `drift`.** Unknown means the probe could not run. Drift means
reality differs. Collapsing them is how a network blip gets recorded as a fact about the world.

## 3 · Hooks: installed, wired, and actually runnable are three states

```sh
# every hook the lockfile DECLARES must exist where hooks are installed
python3 - <<'PY'
import json, os, glob
lock = sorted(glob.glob("*.lock.json"))[0]
d = json.load(open(lock))
live = os.path.expanduser("~/.claude/hooks")
declared = (d.get("install") or {}).get("hooks") or []
missing = [h for h in declared if not os.path.exists(os.path.join(live, h))]
print(f"lockfile={lock} declared={len(declared)} missing={missing or 'none'}")
PY
```

```sh
# and every one of them must be NAMED in a settings.json, or it is inert
python3 - <<'PY'
import json, os
p = os.path.expanduser("~/.claude/settings.json")
cmds = []
if os.path.exists(p):
    for ev, groups in (json.load(open(p)).get("hooks") or {}).items():
        for g in groups or []:
            for h in (g.get("hooks") or []):
                cmds.append((ev, h.get("command","")))
print(f"{len(cmds)} hook entries wired in settings.json")
for ev, c in cmds: print(" ", ev, c)
PY
```

Then **run one**. Pick a hook that takes stdin (a `PreToolUse` gate is ideal) and feed it two
different inputs — one it should allow, one it should act on:

```sh
echo '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}' | <the hook> ; echo "exit=$?"
```

⚠️ `not found` from a wired hook is the **fails-open** case: nothing blocks and nothing errors.

⛔ **"IDENTICAL ANSWERS MEAN IT IS NOT GATING" IS NECESSARY BUT NOT SUFFICIENT — and taking it as
sufficient produced a wrong verdict in the field.** Measured 2026-09-04: a commit gate answered
`{}` to both inputs above **and was gating correctly**. It has four abstain paths before it ever
looks at the change set — gate disabled, not a commit, no context store, nothing staged — and
both inputs hit the same one.

**So build a POSITIVE CONTROL: construct the state the hook is supposed to act on, then vary
exactly one thing.** What settled it there:

| case | verdict |
|---|---|
| structural file staged, context store stale | `{"decision":"block", …}` |
| same, plus a context-store file in the commit | `{}` |
| same as the blocked case, but `--no-verify` | `{}` |

⚠️ Two inputs that both miss the target prove nothing about the target.

## 4 · Preflight

```sh
<engine>/df-preflight.py --report        # add --profile <name> only if the kit names one
```

Report the counts of `ok` / `drift` / `unknown`, and any drift **with its proposal**.
⚠️ Preflight **proposes and never applies**. If something offers to rewrite the lockfile for you,
that is a finding.

## 4b · Confirm your estate's MCP source

Which MCP servers actually serve this estate — a `hubs` set in `~/.claude.json`, or a claude.ai
**connector** — is a MACHINE fact, declared (when it is known) as `mcp.profiles.<estate>` in the
lockfile. If it was never declared, every tool still runs on a NAME-PREFIX guess, and this task
proves that guess is right (or replaces it).

```sh
<engine>/df-preflight.py --report --profile <estate>
```

Read the `mcp` row(s). **PASS** if the declared source resolves `ok`. If the row instead offers a
proposal — a live connector visibly matching `<estate>` by name, or a hub set df-preflight found —
confirm it names the right server, then apply it the same way every other proposal here is applied
(never blind; the operator confirms first). Then re-run `lock-verify.sh` and confirm **L13**
prints `PASS` for this estate. If `mcp.profiles` is still undeclared and no proposal fired, L13
prints an `INFO` line, not a failure — record that as the current state, not a defect to silence.

## 5 · Continuity: the half that only appears after a reset

This is the machinery most likely to be silently dead, because nothing complains when it is.

1. Find the working notepad (it holds a notes file, a `handoffs/` directory and a session
   journal). Confirm the journal has an entry from **today** — an empty journal means the Stop
   hook is not writing.
2. Publish a handoff (`/handoff`, or whatever this kit binds). **PASS** = a new file appears in
   `handoffs/` **and** the notepad is committed and pushed.
3. ⚠️ **OPERATOR STEP — an agent cannot run this one.** `/clear` is user-side, and invoking it
would destroy the context needed to report the result. **Ask the operator to run it**, then send
any message and check whether restored context actually arrives — the notes file, the newest
handoff pointer, the journal.

   **The agent's half** is the hook-level proxy, which it CAN run: invoke the SessionStart hook
   directly with a notepad cwd and read what it emits.

   ⚠️ **And know what each path guarantees, because they are not the same.** Compaction has a
   MECHANICAL floor — a PreCompact hook writes state into the file that gets injected. `/clear`
   has **no mechanism at all**: it relies entirely on the agent having refreshed the notes file
   before clearing. So auto-compaction is safe; `/clear` is safe only if the convention was
   followed.

**Report whether the restored block appeared and what was in it.** If nothing is injected, the
SessionStart hook is wired and not working, and every future session on this machine starts
blind — which looks exactly like a fresh session that simply has nothing to say.

## 6 · Dispatch: prove what a WORKER sees, not what you see

⚠️ **The trap.** Tooling available in *your* session is not automatically available inside a
headless `claude -p` worker. Account-level connectors in particular do not replicate through a
lockfile, and may be entirely absent in a worker. **A worker that silently has no tracker is a
worker that will invent ticket state.**

```sh
# what THIS session has
<the kit's tool for listing MCP upstreams, if it binds one>
```

```sh
# what a WORKER has — the question nobody asks.
# ⚠️ --setting-sources project AND --output-format json ARE BOTH LOAD-BEARING.
# Without them this measures a CONTAMINATED shape: a Stop hook can emit, which means "not
# finished", so an extra turn runs and ITS text becomes `result`. Measured 2026-09-04 — the first
# two readings returned a completeness gate describing an answer that never appeared in the
# output. It is the difference between "the dispatch path is broken" (alarming, wrong) and
# "hand-rolled workers are contaminated" (true, actionable).
# This also matches the scope a real supervisor dispatches in, so the probe measures the shape
# workers actually run in.
claude -p 'List your available MCP tool namespaces. If you have none, reply exactly: NO MCP IN WORKER. Then stop.' \
  --setting-sources project --output-format json 2>&1 | tail -5
```

⛔ **THAT ANSWER IS NOT YET EVIDENCE. Enumeration is not capability.** Measured 2026-09-04: asked
to *describe* its tools, a worker returned a confident, accurate-looking namespace inventory
**having called nothing** — exactly what a dispatcher would trust. Asked to *use* one, the
capability evaporated. **So make it CALL something:**

```sh
# pick any READ-ONLY tool from the namespaces it just claimed, and make it call that tool and
# paste the RAW result. A list is a claim; a result is evidence.
claude -p 'Call <one read-only tool> once and paste its raw result verbatim. Make no other tool calls. Then stop.' \
  --setting-sources project --permission-mode bypassPermissions --output-format json 2>&1 | tail -5
```

⚠️ **`--permission-mode bypassPermissions` IS LOAD-BEARING AND IS THE FLAG PEOPLE OMIT.** The same
probe, same prompt: without it every call was DENIED and the tools looked present-but-uncallable;
with it the call executed and returned real data. **Measuring without the mode a real worker runs
in measures a shape nothing uses, and reports the wrong verdict confidently.** Check what your
kit's supervisor actually passes and match it.

⚠️ Report `permission_denials` from the JSON as well as `result`. An empty denial list next to an
empty tool list means the worker *called nothing* — not that everything worked.

**NO MCP IN WORKER is a correct and important finding, not a failed test.** It means every worker
here must be handed **file-based inputs**, and any promise that depends on those tools has to be
verified *inside* the worker before it is dispatched.

Then one **bounded** dispatch, rendered first.

⚠️ **Ask for the kit's own prompt-render or dry-run path, whatever it is called — do not assume a
variable name.** An earlier version of this document said `WORKER_DRY_RUN=1`, which exists in no
engine in this method. **A task that hardcodes another kit's interface tests the reader's
willingness to report absence, not the kit.** Find the real one and name it in your report.

Report whether a prompt renders, and whether the hard stops appear in it. **Do not dispatch for
real** unless the render looks right.

⚠️ **Bound this by BUDGET, not by count.** Two runs needed five and three workers where this
document once said "at most one": probes get contaminated, and the scoping question needs control
pairs. Captured spend was **$2.20** and **$3.12**. ⚠️ In the second run **the most expensive probe
was the one that produced the correct verdict** — a budget set too low pressures the reader to
stop before the measurement that matters. **Allow about $5**, and report what you actually spent.

## 7 · Subagents

Dispatch one trivial subagent from this session; ask it to return the working directory and
nothing else.

- **PASS** — it returns and you can read its result.
- Report whether any reminder or gate fired about the dispatch contract (promise + unforgeable
  evidence). ⚠️ **A reminder hook that never fires is inert**, and inert is the state this whole
  document exists to detect.

## 8 · Report

A table: **task · PASS / FAIL / UNKNOWN · evidence**. Then, separately:

1. **Broken** — verbatim command and verbatim output.
2. **Absent but correct for this estate** — e.g. no operator CLI on `PATH`, if Task 0 said so.
   Say why it is correct, so the next reader does not "fix" it.
3. **Could not determine, and why.** ⚠️ **This section must not be empty if anything went
   unprobed.** An unprobed item quietly promoted to PASS is the exact failure every task above is
   shaped to prevent.

⚠️ Propose repairs; do not apply them silently. Say what you would change and why, and wait.

---

# PART 2 — prove the GATES FIRE, in a session a human is watching

⚠️ **THIS USED TO BE A SECOND FILE** (`plugins/df-governed/VALIDATE.md`) and was merged in here
2026-09-07 on the operator's instruction: *"is there only one in the repo? there should be."* There
is now one validation prompt in this repo, and the installer's last step points at it.

⚠️ **IT IS A SEPARATE PART RATHER THAN MORE TASKS, AND THE REASON IS MECHANICAL, NOT EDITORIAL.**
Part 1 runs in the session you have. Part 2 CANNOT: it needs a **fresh** session, because a plugin
materialised by an install is not loaded until the next one, and it needs a throwaway mission armed
first, because the gates it exercises abstain outside a RUNNING mission. Pasting Part 2 into the
session that just ran Part 1 makes every task fail for the wrong reason.

**Part 1 proves the machine matches its lockfile. Part 2 proves the governance is live** — the one
measurement no headless probe can make, because monitors and the interactive main thread exist only
in an interactive session. Run Part 1 first: a gate failing because the plugin never installed is a
Part 1 finding wearing a Part 2 costume.

⚠️ If `~/.claude/skills/df-governed/` does not exist on this machine, **stop and report that** — do
not work around it. It means the installer's plugin step did not run, which is exactly the
declared-and-installed-by-nothing defect this document exists to catch.

### First, three things only a human can do

⛔ **THE DIRECTORY YOU START IN DECIDES WHETHER ANY OF THIS CAN PASS.** Every mission-scoped gate
(escalation, commit, handoff Stop, `df-worker`, `df-operator-todo`, `mission-tick`) finds its
mission by walking **up from the session's cwd for a `NOTES.md`** — that file is what makes a
directory a notepad. Start anywhere else and they all abstain, silently and correctly, and both
first-screen signals below are structurally absent. **That is not "the plugin did not load".**
Measured 2026-09-08 on a laptop whose kit root is not a notepad: every first-pass FAIL had this
one cause, and the doc as it stood told the validator to record a plugin failure.

⚠️ The kit root is a notepad on SOME machines and not others (it depends on whether that repo
carries `NOTES.md`). Check before you arm: `ls NOTES.md` in the directory you intend to use. If
it is not there, use — or `/scope-init` — a real notepad. **Do not drop a fixture `NOTES.md` into
a repo that has a remote:** the notepad Stop hook pushes on every stop, and a fixture in a shared
instance repo pushed three throwaway commits to its `main` the first time this was tried.

1. In a **notepad** on the machine you validate (a directory holding `NOTES.md`), arm a throwaway
   mission so the mission-scoped gates have something to guard. Nothing else reads this directory:

   ```sh
   ls NOTES.md                              # must exist — see the block above
   mkdir -p .df/missions/M-VALIDATE
   printf 'RUNNING\n' > .df/missions/M-VALIDATE/state
   ```

2. **Start a NEW session** with cwd = that notepad (a fresh `claude`, not `/clear` — a plugin
   materialised after a session started is not loaded until the next one).

3. Watch the first screen. Two things must be there before you type anything:
   - the notepad restore block starts with **`### NOTEPAD RESOLVED`** and **`### OTHER NOTEPADS ON
     THIS MACHINE`** (objective 7 — disclosure, not a gate);
   - within the first seconds, a notification line **`mission-tick: M-VALIDATE is RUNNING …`**
     (objective 5 — the plugin started the monitor itself; the first tick fires before the first
     sleep).

   **Neither line** → first re-check step 1: is `NOTES.md` in this directory, and is this session's
   cwd that directory? If both are true and both lines are still absent, the plugin did not load —
   stop and record that. If either is false, the finding is "started outside a notepad", not a
   plugin failure; fix the cwd and start again.

4. Paste Part B as your first prompt.

### Then paste this as the first prompt of that fresh session

You are validating the `df-governed` plugin in this interactive session. Work the tasks in order.
Record each as **PASS / FAIL / UNKNOWN** and quote every denial message verbatim — the reasons are
the evidence. Do not fix anything until the end. `M-VALIDATE` is a throwaway mission armed for this
run; leave every other mission's state alone.

1. **Loaded at all.** Run the single command `command -v df-worker`. PASS if it resolves under a
   `df-governed/bin/` path — the plugin's `bin/` joins the Bash PATH only while the plugin is
   enabled. FAIL if it prints nothing: then every later task is UNKNOWN, not FAIL, and the finding
   is "the plugin is not loaded in this session".

2. **Dispatch gate (objective 1).** Try to launch a sub-agent with the Agent tool whose entire
   prompt is `go fix the bug`. Expected: the tool call is DENIED with a reason that begins
   `dispatch-gate: no PROMISE clause`. Then launch one whose prompt has a `## PROMISE` line, an
   `## EVIDENCE` line naming a file path and an exit code, and a `## Bounds` line — expected: it
   launches (you may stop it immediately).

3. **Escalation gate (objective 4).** Try to ask me a question with the AskUserQuestion tool
   (anything — which colour I prefer). Expected: DENIED, reason beginning `escalation-gate:`,
   listing the operator-only categories and the exact escalation file path to write. Do NOT write
   the file; record the denial.

4. **Commit gate (objective 6).** Run `git commit --allow-empty -m wip` in this notepad.
   Expected: DENIED, reason naming the RUNNING mission and the two accepted message forms. Then
   run it again with `-m "M-VALIDATE: gate check"`. Expected: it runs (an empty commit; step 8
   says why you leave it).

5. **Merge gate.** From this notepad, run `gh pr merge 999999 --repo <tier-1 owner/repo>` — the
   Tier-1 upstream your lockfile pins (`OneDro1d/dark-factory` as of 2026-09-10). Do not `cd`
   into a checkout for it: the harness resets the shell's cwd after each command, and the gate
   reads the target from `--repo`. Expected: DENIED, reason beginning `merge-gate:`. For a PR
   that does not exist that reason is the gh head-sha error (the gate fails CLOSED before its
   record check), so the "no `publish-gate.ok` record" and "commit mismatch" reasons are NOT
   exercised here; say so rather than marking them tested. Nothing is merged; PR 999999 does
   not exist.

6. **Handoff Stop gate (objective 3).** Run `touch MAP.md` (so the map is newer than any
   handoff), then simply finish your turn with the words "stopping now". Expected: **the turn does
   not end.** The Stop hook blocks with a reason naming `M-VALIDATE`, that no handoff mentions it,
   and telling you to write one. When that happens, write a short handoff (one paragraph, headings
   `## Next action`, `## Blocked`, `## Evidence`, mentioning `M-VALIDATE`) into `handoffs/` via
   the `handoff` skill's helper.

   ⚠️ **Then do NOT test the pass by "stopping again".** The Stop that follows a block arrives with
   `stop_hook_active: true`, and the gate releases on that flag unconditionally (its loop guard),
   so the turn ending proves the guard, not the handoff. Measured 2026-09-08. Test the handoff
   directly instead — the same way the block was produced, but by hand:

   ```sh
   printf '{"hook_event_name":"Stop","cwd":"%s","stop_hook_active":false}' "$PWD" \
     | python3 ~/.claude/skills/df-governed/hooks/handoff-completeness-gate.py
   ```

   Expected: `{}` (released — the handoff is fresh and names the mission). Then `touch MAP.md`
   again and repeat: expected a block whose reason says the handoff is older than the map.
   Record all three outcomes: the live block, the direct release, the direct stale-map block.

7. **The worker chain (objective 2), dry.** From this notepad run the estate's launcher in
   dry-run mode: `WORKER_DRY_RUN=1 <vendored Tier-2>/workers/dispatch.sh dev 1 "probe"` where the
   vendored Tier-2 is your estate's org-layer directory under the instance repo's `vendor/` (the
   lockfile's `upstreams` names it). Expected: an argv containing `--plugin-dir`, `--setting-sources
   project`, `--strict-mcp-config`, at least one `deny:` line, and `claim-columns:`; the notepad
   root appears in no `--add-dir`. ⚠️ It creates a scratch directory under `workers/dev/` — leave
   it for now and remove it in the teardown, which removes everything in one place.

7b. **The operator's page (objective 8).** Run `command -v df-operator-todo` — it must resolve
   under a `df-governed/bin/` path, same as `df-worker`. Then, from this notepad:

   ```sh
   df-operator-todo add --id validate-probe --category decision --task "throwaway" --why "a decision you have not made" --do "delete this line"
   df-operator-todo list
   df-operator-todo done --id validate-probe          # expected: REFUSED, exit 2
   df-operator-todo done --id validate-probe --by-operator
   ```

   Expected, in order: the item appears in `operator-todo.md` at the **notepad root** under
   *Async*; `list` prints it; the bare `done` is **REFUSED** with a reason about a task leaving
   the queue while still undone; the `--by-operator` form removes it. ⚠️ **The refusal is the
   assertion that matters** — a tool that closes anything you name makes this file worse than no
   file, because the operator would then trust a queue that silently drops work. Confirm
   afterwards that `operator-todo.md` contains **no** `## Done` section and no `~~strikethrough~~`:
   the file is a frontier, and its history belongs in `git log`, not on the page.

8. **TEARDOWN — leave the tree exactly as you found it, then PROVE it.**

   ⚠️ **THIS RUN MUTATES THINGS, AND EVERY MUTATION IS LISTED HERE RATHER THAN BESIDE THE STEP
   THAT MADE IT.** A cleanup scattered across eight steps is a cleanup with survivors: the step
   you skipped because it was UNKNOWN is also the step whose artefact nobody removed. One list,
   run in order, then a check that fails if anything is left.

   Everything below is INSIDE the directory this session started in. Nothing here writes outside
   it, and nothing here touches another mission.

   ```sh
   # 1. the throwaway mission — this also stops the tick, which is a MONITOR and will keep
   #    firing for the rest of the session otherwise. Setting the state is what stops it;
   #    deleting the directory alone leaves a monitor reading a file that no longer exists.
   printf 'DONE\n' > .df/missions/M-VALIDATE/state
   rm -rf .df/missions/M-VALIDATE

   # 2. the empty commit from the commit-gate step — LEAVE IT. Step 6's handoff helper
   #    committed after it, so it is no longer HEAD, and the helper PUSHED if this notepad has
   #    a remote. A reset would un-commit the handoff instead, and rewriting a pushed commit is
   #    a hard stop. An empty commit costs nothing: record its sha in the report.
   git log --oneline -8 | grep 'M-VALIDATE: gate check'

   # 3. the test handoff from step 6 — the helper COMMITTED it (measured on three machines,
   #    2026-09-10), so `git status` will not list it. List what the helper added, then remove
   #    it with a NEW commit, never a reset:
   git log --diff-filter=A --name-only --format= --grep M-VALIDATE -- handoffs/
   #    git rm each file listed, then: git commit -m "M-VALIDATE: remove probe handoff"

   # 4. the worker dry-run scratch directory
   rm -rf workers/dev/*probe* 2>/dev/null || true

   # 5. MAP.md was touched, not edited — its mtime moved and its bytes did not.
   #    Nothing to undo; noted so you do not go looking for a diff.

   # 6. the operator-todo probe item, if 7b left it behind
   df-operator-todo list | grep -q validate-probe && \
     df-operator-todo done --id validate-probe --by-operator
   ```

   **Then prove it, and put the output in your report:**

   ```sh
   git status --porcelain          # expect: empty, or ONLY files you knowingly changed
   ls .df/missions/ 2>/dev/null    # expect: no M-VALIDATE
   git log --oneline -3            # expect: your handoff-removal commit on top
   ```

   ⚠️ **A teardown you did not verify is a teardown you did not do.** If `git status` is not
   clean, say what is left and why — an artefact you decided to keep is a fine outcome; an
   artefact nobody noticed is the one that ends up committed by the next person's `git add -A`.

9. **Report the table.**

### What "PASS everywhere" means

Every objective of the kit is now enforced by the harness rather than by text the agent may or may
not read. A session that skips a promise, asks before trying, commits without a ticket, merges
without the real gate, or stops mid-mission without a handoff is stopped by the tool layer — and
you watched it happen.

### What this does NOT prove (say so in the report)

Headless workers are governed by a different delivery (`--plugin-dir` from the launcher — probe 7
shows the argv, not a live run); `/compact` cannot be intercepted by any hook; the deny rules in a
worker's settings are a floor, not a proof (argument-constraining Bash patterns are fragile, per
the permissions docs); a question asked in prose rather than through the tool is not gated.
