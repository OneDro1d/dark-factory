# START HERE — clone to a first working session, in about ten minutes

You are about to turn this template into **your** instance: a directory you own, a lockfile
that says exactly what is installed on this machine, and a session where the method is
actually running rather than merely described.

Read this page through once before typing. It is short, and two of the six steps fail in
ways that look like success if you do not know what to check.

> **One machine, one person.** If you are setting up a whole organisation — a shared layer
> plus a tier per developer — you want `../new-org-layer.sh` instead. The two are siblings;
> `README.md` in this directory explains which question each answers. An instance made here
> can be folded into an org layer later.

---

## Before you start

| you need | why |
|---|---|
| `git`, `jq`, `bash`, `python3` | `bootstrap.sh` refuses to run without `git` and `jq`; the engine is Python |
| an agent harness that reads `SKILL.md` and supports hooks | the skills and the session hook are the method's delivery mechanism |
| **optionally**, an MCP hub of your own | needed only from step 4. Steps 1–3 are fully offline-capable |

**You do not need a hub to finish steps 1–3**, and it is worth doing them first: an install
that is broken and a hub that is misconfigured produce similar-looking silence, and
separating them is most of the debugging.

---

## 1 · Clone and bootstrap

```sh
git clone https://github.com/OneDro1d/dark-factory.git
cd dark-factory
bash starter-kit/instance/bootstrap.sh my-instance
```

`bootstrap.sh` runs **once**. It creates `../my-instance` — deliberately a sibling of this
checkout, never inside it, because an instance nested in its own upstream gets committed to
that upstream by the first careless `git add -A` and nothing about the layout warns you.

It resolves the Tier-1 pin from the remote **at this moment** and writes it as a commit SHA.
If the remote is unreachable it pins your local `HEAD` and says so in `$refSource`. That
message is the whole point — a pin whose origin is unrecorded is a pin nobody can re-derive.

**Checkpoint.** The last lines print your instance path and `pinned: <8 chars>`. If instead
you see `WARN could not resolve any Tier-1 commit`, the lockfile holds `__T1_COMMIT__` and
step 3 will stop on it.

## 2 · Fill in the lockfile

```sh
cd ../my-instance
$EDITOR loom.lock.json
```

Three things to set, and one to leave alone:

- **`codeRoot`** — the directory your checkouts live under. Defaulted to `$HOME/code`;
  change it if that is not true. Tools find a repo under it by its **origin remote**, never
  by directory name, because names drift when a checkout is cloned or renamed and remotes
  do not.
- **`codeLayout`** — lane → directory. A lane is one grouping of repos you work in; name
  them however your work is actually divided. **Leaving it empty is correct** if you do not
  have lanes yet: the preflight then reports `unknown` for that probe, which is the honest
  answer. A guessed lane reports as a fact.
- **`install.skills` / `install.skillSources`** — the skills you want, and where each comes
  from. Every name must have a matching source entry; a name with no source is reported,
  never guessed at. `../../skills/` in this repo lists what is available, e.g.
  `"vinculum-loop": "dark-factory/skills/vinculum-loop"`.
- **Leave `probed` alone.** Tools write it; you do not.

Anything still holding a `__PLACEHOLDER__` is a value nobody supplied, and step 3 names it
rather than defaulting it.

## 3 · Install

```sh
bash install.sh
```

It fetches Tier 1 at the pin, copies the engine into `boot-kit/scripts/` **here**, hands the
remaining upstreams, skills and hooks to Tier 1's own `rehydrate.sh`, puts `df-mission` on
your `PATH`, verifies against the lockfile, and then prints what it could not do for you.

`install.sh` is the re-runnable half — run it again after any lockfile edit. Two flags worth
knowing: `--dry-run` prints the plan and changes nothing, `--offline` installs from whatever
is already vendored and touches no network.

**Checkpoint — read the exit code, not the last line of output.**

| exit | means | do |
|---|---|---|
| `0` | installed, and `lock-verify` says **LOCKED** | go to step 4 |
| `1` | a precondition failed — nothing was installed | fix what it named; the cause is one line |
| `2` | it installed, and the result does **not** match the lockfile | read the `verify` section. Do not proceed |

`2` is deliberately neither `0` nor `1`. Collapsing "ran but does not match" into success is
how an instance ships half-configured and stays that way.

If it warns that your bin directory is not on `PATH`, fix that now. Installed-but-unreachable
is not installed, and it fails much later as `command not found`, pointing at the wrong thing.

## 4 · The three pieces no installer will do for you

`install.sh` prints these on **every** run, not once, so that a green install is never read
as a complete setup:

| do this | from |
|---|---|
| merge the hook registration into your harness settings | `boot-kit/settings.template.json` |
| point the hub config at **your** hub, token by environment variable | `boot-kit/mcp.template.json` |
| copy the output style into your harness's output-styles directory and select it | `boot-kit/output-style.md` |

Each of these lands in a file shared with everything else you run. A script that rewrites
them silently deletes another tool's configuration, and the loss shows up much later as
behaviour that used to happen and now does not. So they stay manual, and
`boot-kit/README.md` says which is which and why.

**The token is read from the environment, not stored.** Export it in your shell profile
before launching anything unattended: a headless run whose parent process lacks the variable
boots cleanly, fails every hub write, and keeps going.

## 5 · Prove it, rather than assuming it

```sh
python3 boot-kit/scripts/df-preflight.py --report
```

This makes a **live call** against every configured hub and probes every binary, identity
and repo the lockfile declares. A present `Authorization` header proves nothing — an expired
token looks exactly like a working one until something needs it.

Three verdicts, and the third is not a polite synonym for the second:

| verdict | means |
|---|---|
| `ok` | probed; reality matches the record |
| `drift` | probed; reality **differs**. A positive finding, and it may carry a proposal |
| `unknown` | could not probe — binary absent, network down. **Not** a fact about the world |

Only a positive `drift` justifies changing anything. Collapsing `unknown` into `drift` is
how a network blip gets written into a lockfile as "no checkout on this machine". Proposals
are never applied for you: confirm one, then `--apply` records it under `probed`.

## 6 · Open a session

Open a **new** session in your instance directory. Hooks are read once, at session start, so
a hook installed mid-session does nothing — that, and the fact that hooks are *copied* while
skills are *symlinked*, account for almost every "my change did nothing".

The session hook should tell you which instance you are in, whether it is actually installed,
and what missions are running. If it says nothing at all, run it directly before blaming it:

```sh
printf '{"cwd":"%s"}' "$PWD" | bash ~/.claude/hooks/df-instance-start.sh | jq .
```

A SessionStart hook that errors, or prints anything that is not JSON, is discarded
**silently** — so a broken hook and a hook with nothing to say look identical from inside a
session. (Substitute your harness's hooks directory if it is not `~/.claude`.)

---

## When it goes wrong

| symptom | almost always |
|---|---|
| `install.sh` exits `1` naming a `__PLACEHOLDER__` | `bootstrap.sh` could not resolve it and you have not filled it in |
| `install.sh` exits `2` | something on disk is not declared in the lockfile, or something declared is missing. `lock-verify` checks **both** directions and the second is the one that usually goes missing |
| `df-mission: command not found` | it installed; your bin directory is not on `PATH` |
| a skill you declared is "unknown" | the session started before the install, or `skillSources` has no entry for that name |
| the hook does nothing | old session, or it is not valid JSON — run it directly, above |
| every hub call fails, nothing else is wrong | the token variable is not exported in **this** process |

## What to read next

- [`README.md`](README.md) — this directory's shape, and the two rules it depends on
- [`boot-kit/README.md`](boot-kit/README.md) — what your harness loads at session start, and
  which of it is automatable
- [`../../README.md`](../../README.md) — the method itself: the stages, the control loop, the
  delegability test
- [`AUTHENTICATION.md`](AUTHENTICATION.md) — what a hub is, how to point at your own, and
  what each kind of connector needs. Read it **before** step 5 if you are configuring a hub:
  the token is an environment reference, and a headless run whose parent never exported it
  boots cleanly and then fails every hub write in silence.

The one thing to carry out of this page: **a green run is not evidence.** Every check here
tells you what it could not see, and the parts that stay manual stay visible on purpose.
