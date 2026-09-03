# START HERE — clone to a first working session, in about ten minutes

You are about to turn this template into **your** instance: a directory you own, a lockfile
that says exactly what is installed on this machine, and a session where the method is
actually running rather than merely described.

Read this page through once before typing. It is short, and several of its steps fail in
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
| a hub — **or none** | needed only from step 4; [§4a](#4a--if-you-do-not-have-a-hub-yet) is the path if you have none. Steps 1–3 are fully offline-capable |

**You do not need a hub to finish steps 1–3**, and it is worth doing them first: an install
that is broken and a hub that is misconfigured produce similar-looking silence, and
separating them is most of the debugging.

---

## 1 · Clone and bootstrap

```sh
git clone https://github.com/OneDro1d/dark-factory.git
cd dark-factory
bash starter-kit/instance/bootstrap.sh --kit list          # what kinds of work are bundled
bash starter-kit/instance/bootstrap.sh my-instance --kit dev
```

**Pick the kit that matches the work, not the person.** `kits/dev` for writing and shipping
code; `kits/knowledge-worker` if what you produce is documents rather than code;
`kits/code-review`, `kits/frontend`, `kits/distributed-systems` for the narrower jobs. Repeat
`--kit` to compose. Each one pulls in `kits/method-core` — the method itself — through its own
`extends`, so you never name the floor by hand.

⚠️ **`--kit` is optional, and omitting it is a real choice rather than a mistake.** Without it
your instance ships an **empty** skill list and you fill it in at step 2. That is honest: a
default set nobody chose would arrive in every install, and this repo declines to ship one
anywhere else either.

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
  from. **If you passed `--kit`, these are already filled in and paired** — read them, prune
  what you will not use, and move on; `install.$kitResolution` records which bundle they came
  from. If you did not, list them by hand: `../../skills/` lists what is available, e.g.
  `"vinculum-loop": "dark-factory/skills/vinculum-loop"`.

  Every name must have a matching source entry and every source entry must have a name;
  `lock-verify` (L7) checks both directions, because either half alone installs nothing while
  still reading like a declaration. A source resolves under your vendor directory unless it
  begins with `local:`, which resolves inside your own instance — that is how you declare a
  skill or hook you wrote yourself.

  ⚠️ **Adding a name here is not the same as adding a skill.** The lockfile is the authority;
  a directory nothing declares is installed by nothing and reported by nothing, so it does not
  exist as far as any check is concerned.
- **Leave `probed` alone.** Tools write it; you do not.

Anything still holding a `__PLACEHOLDER__` is a value nobody supplied, and step 3 names it
rather than defaulting it.

### ⚠️ Is this instance yours yet? — `instance.kind`

There are two kinds of kit and they need opposite handling.

| | **instance** | **template** |
|---|---|---|
| describes | one real machine | nobody's machine yet |
| you should | install and re-install from it | clone it somewhere you own, THEN customise |
| identity | declared, and the guard is armed | not declared, correctly |

`bootstrap.sh` gives you an **instance**: you named it, so it is about your machine. A kit
somebody hands you — a shared team kit — is a **template**, and its installer says so on every
run until you flip the marker.

**Making a template yours, once:**

1. put it somewhere **you** own — a fork, or your own branch
2. customise the lockfile: `codeRoot`, `codeLayout`, `instance.name`
3. declare the machine: `bash boot-kit/scripts/identify.sh --declare loom.lock.json`
4. flip the marker: `"instance": { "kind": "instance", ... }`
5. commit and push to **your** copy — that is what you re-install from ever after

⚠️ **Step 4 is not bookkeeping.** It is you saying this repo now describes a real machine, which
is what makes the identity guard meaningful here. Until then the guard is present, passing, and
checking nothing — and a check that cannot disagree with anything agrees with everything.

⚠️ **Step 1 is not optional, and skipping it is the failure people actually hit.** If you
customise a shared template in place, your setup lives where the maintainer also pushes, and the
next upstream change overwrites it. Installing an uncustomised template still *works* — it
installs the defaults — so nothing breaks loudly. It just silently is not yours.

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
| point the hub config at a hub — it already points at one; the token is yours to export | `boot-kit/mcp.template.json` |
| copy the output style into your harness's output-styles directory and select it | `boot-kit/output-style.md` |

Each of these lands in a file shared with everything else you run. A script that rewrites
them silently deletes another tool's configuration, and the loss shows up much later as
behaviour that used to happen and now does not. So they stay manual, and
`boot-kit/README.md` says which is which and why.

**The token is read from the environment, not stored.** Export it in your shell profile
before launching anything unattended: a headless run whose parent process lacks the variable
boots cleanly, fails every hub write, and keeps going.

## 4a · If you do not have a hub yet

Skip this if you already have one, or if you are running without one. Otherwise it is about
five minutes, once, and then step 4's middle row is done.

`boot-kit/mcp.template.json` ships pointing at **OneDroid Synapse**, a public MCP hub that
anyone can sign up for. That is a **default, not a requirement** — the two other paths are at
the end of this section, and neither is second-class.

The vendor's own walkthrough is <https://docs.onedroid.ai/quickstart>, and it is the page to
follow. What is below is the *order*, plus the things that go wrong along the way — each of
which presents as something other than its cause.

1. **Sign up** at <https://synapse.onedroid.ai>. Google, Microsoft, or email.

   > ⚠️ **Use the same method every time.** Sign-in is Clerk, so Google and Microsoft on the
   > *identical* email address are two separate accounts. The symptom is not an error; it is
   > signing in successfully and finding no hub, or the wrong one.

2. **Choose where the data lives** — managed, or your own Postgres.

   > ⚠️ If you bring your own: leave the literal `[YOUR-PASSWORD]` placeholder in the
   > connection string **exactly as it appears**, because the password is spliced in from a
   > separate field and is deliberately never stored in the URI. Substituting the real one
   > presents as *"the credentials are right and the connection test fails"*, which sends
   > you looking at the database.

3. **Create the hub.** The slug you get back is not the slug you typed — a short unique
   suffix is appended. It does not matter here: the slug selects a hub for *browser* clients,
   and this kit is the token avenue, which carries the hub in the token instead. That is why
   the template's URL has no slug in it and must not gain one.

4. **Mint a token** — check the hub picker is on the hub you mean first, since a token is
   bound to one hub at creation. The plaintext is shown **once**.

5. **Wire it.** Export the token as `DF_HUB_TOKEN` in your shell profile, then copy the
   `mcpServers` block out of `boot-kit/mcp.template.json` into your harness config. The
   template already carries the URL, and carries the token as `${DF_HUB_TOKEN}` rather than
   as a value — [`AUTHENTICATION.md`](AUTHENTICATION.md) is why, and it is worth two minutes
   before you paste anything.

Then go to step 5 and prove it, rather than assuming it.

> ⚠️ **A fresh hub has zero connections, and that is expected.** If it *stays* at zero, the
> upstreams have not been enabled — which only an admin can do. Sign up on your own and you
> are the admin of your own hub, so this is yours to fix. Get *invited* into someone else's
> and it is not: you will hold a perfectly valid token, see no tools, and have every reason
> to blame the token. Ask whoever owns the hub.

**Bring your own hub instead.** Replace the `url` and rename the server key. Ask your
provider for the exact path rather than assuming it looks like the default's — the split
between token and browser paths above is one product's design, not a standard.
[`AUTHENTICATION.md`](AUTHENTICATION.md) covers what stays true either way.

**Or run no hub at all.** Delete `boot-kit/mcp.template.json`. You lose shared memory across
sessions and machines, and connectors to systems you already use. Nothing else in the method
depends on it, and steps 5 through 7 all still work.

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

**What this check cannot tell you apart.** A hub that answers `401` is reported as `drift`,
and the note says *token expired or revoked* — but a wrong token and a header that never
arrived produce the same `401` here. Those are the two failures that look identical from
inside an agent, and the vendor's probe distinguishes them by returning a different code in
the body: <https://docs.onedroid.ai/troubleshooting>. Run that before changing anything in
your config, because the two causes have nothing in common.

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

## 7 · Run the worked example, before you frame anything of your own

`bootstrap.sh` installed one mission already: `EXAMPLE-FIRST-RUN`, under
`.df/missions/`. It is a real mission — a supervisor runs it, fresh iterations claim its
tickets — and it is safe to run on any machine because its own `HARD-STOPS.md` confines
every write to its own directory. It makes no network call and touches no hub.

```sh
df-mission start EXAMPLE-FIRST-RUN --profile default --max-iter 5 --max-usd 5
df-mission status EXAMPLE-FIRST-RUN
```

It leaves behind `RESULT.md` in that directory: what the runtime here was *shown* to do,
what it could not be shown to do, and which of the two a reader on another machine should
expect to differ. Read the second section first — a run with no blind spots has not looked
hard enough at itself.

Run this before framing a mission of your own. Everything above this line is a check that
the pieces are present; this is the first thing that tells you they work together. It also
shows you the three overrides a mission makes against the generic iteration prompt — its
own tracker (`TICKETS.md`, a file, because the discipline is the claim convention and not
any particular product), its own handoff directory, and no estate binding at all.

**If it stops at `BLOCKED`, that is not a failed install.** The example is written so a
blocked run with a well-named reason is a successful run: read `state` and the ticket it
was on. The failure mode to worry about is the opposite one — a `DONE` whose `RESULT.md`
has an empty "what could not be shown" section.

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
| `df-mission: no such mission` for the example | you are not inside the instance directory, or an inherited `$NOTEPAD` is pointing at a different notepad — it wins over the upward walk |
| the example finishes `DONE` with nothing it could not verify | read it again; that section being empty is the defect the ticket warns about |
| signed in, but there is no hub or it is the wrong one | you signed in with a different provider than you signed up with — two accounts, one email. [§4a](#4a--if-you-do-not-have-a-hub-yet) |
| the connection test fails and the credentials look right | the real password was substituted for the `[YOUR-PASSWORD]` placeholder, which is meant to stay literal |
| connected, token valid, and zero tools appear | the hub has no upstreams enabled. Only an admin can enable them, so if you were invited into someone else's hub this is not yours to fix |
| `ERR_SCOPE_UNAVAILABLE` | a token sent to a slug-carrying URL. The token avenue has no slug — see [`AUTHENTICATION.md`](AUTHENTICATION.md) |

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

For the default hub, the vendor's own pages — authoritative, and deliberately not copied into
this kit, because two copies of a setup path drift and then neither can be trusted:

- <https://docs.onedroid.ai/quickstart> — sign-up through to a first verified call
- <https://docs.onedroid.ai/troubleshooting> — the failure table, including the two `401`s

The one thing to carry out of this page: **a green run is not evidence.** Every check here
tells you what it could not see, and the parts that stay manual stay visible on purpose.
