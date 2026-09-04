# VALIDATE — prove the kit actually works, after installing it

**Paste the block below into a fresh agent session on the machine you just installed.**
It is the last step of the install, and it ships with every kit.

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

```sh
# the engine may be on PATH, at the kit root, or only inside the vendored upstream
command -v df-preflight || echo "df-preflight: not on PATH"
command -v df-mission   || echo "df-mission: not on PATH"
find . -maxdepth 4 -name 'identify.sh' -o -maxdepth 4 -name 'lock-verify.sh' 2>/dev/null | head
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

⚠️ **A hook that answers identically to both inputs is not gating.** Report both outputs.
⚠️ `not found` from a wired hook is the **fails-open** case: nothing blocks and nothing errors.

## 4 · Preflight

```sh
<engine>/df-preflight.py --report        # add --profile <name> only if the kit names one
```

Report the counts of `ok` / `drift` / `unknown`, and any drift **with its proposal**.
⚠️ Preflight **proposes and never applies**. If something offers to rewrite the lockfile for you,
that is a finding.

## 5 · Continuity: the half that only appears after a reset

This is the machinery most likely to be silently dead, because nothing complains when it is.

1. Find the working notepad (it holds a notes file, a `handoffs/` directory and a session
   journal). Confirm the journal has an entry from **today** — an empty journal means the Stop
   hook is not writing.
2. Publish a handoff (`/handoff`, or whatever this kit binds). **PASS** = a new file appears in
   `handoffs/` **and** the notepad is committed and pushed.
3. ⚠️ **Now the part that cannot be tested by looking:** run `/clear`, send any message, and check
   whether restored context actually arrives — the notes file, the newest handoff, the journal.

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
# what a WORKER has — the question nobody asks
claude -p 'List your available MCP tool namespaces. If you have none, reply exactly: NO MCP IN WORKER. Then stop.' 2>&1 | tail -20
```

**NO MCP IN WORKER is a correct and important finding, not a failed test.** It means every worker
here must be handed **file-based inputs**, and any promise that depends on those tools has to be
verified *inside* the worker before it is dispatched.

Then one **bounded** dispatch, dry-run first:

```sh
WORKER_DRY_RUN=1 <the kit's dispatch script> dev <any-ticket-id> \
  "Print the repo root and exit. Evidence: the verbatim path."
```

Report whether a prompt renders. **Do not run it for real** unless the dry run looks right, and
dispatch **at most one** real worker — this costs money.

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
