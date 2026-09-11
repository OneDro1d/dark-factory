# START HERE — set up your agent from this kit

> **Human:** open Claude Code in this directory and tell it:
> **"Read START-HERE.md and execute it."**
>
> **Claude:** this file is your runbook. Execute it top to bottom. Every step ends with a
> **Check**: run it, and do not move on until it passes. Stop and ask the human only at steps
> marked **HUMAN**. Those need a decision, a login or a grant that only they can give. Report
> what you ran and what each check printed; never report a step as done without its check.

## What you end up with

- **Your own private GitHub repo** holding your agent's setup. You install from it on every
  machine you use, and each machine's validation report lands in it.
- **One record per machine** in that repo, at `instances/<machine>/loom.lock.json`. A laptop, a
  cloud workspace and a second laptop are three records in one repo. Each machine installs only
  its own.
- **A working, validated agent** on this machine: the skills, hooks and gates the kit declares,
  proven by a validation run that commits its own report.

What is specific to this kit is in **`KIT.md`**: who it is for, what it connects to, the access
you need, and what here cannot be undone. You read it in step 2.

This file is the same in every kit. It never names a commit: the pins live in the records, and
a commit written into prose is out of date the first time the kit updates.

---

## 0 · Where are you?

From this directory:

```sh
ls starter-kit/instance/bootstrap.sh 2>/dev/null   # present: the public method repo
ls ./*.lock.json 2>/dev/null                        # present: a kit
jq -r '.instance | if type == "object" then (.kind // "unset") else "instance" end' ./*.lock.json 2>/dev/null
git remote -v
```

| you see | you are in | go to |
|---|---|---|
| `starter-kit/instance/bootstrap.sh` exists | the public method repo | step 1, then **2A** |
| a `*.lock.json` whose `instance.kind` is `template` | a team kit someone shared with you | step 1, then **2B** |
| `instance.kind` is `instance` and `origin` is **the human's own private repo** | their setup, on a new machine | step 1, then **3** |
| `instance.kind` is `instance` and `origin` is **somebody else's** repo | somebody else's setup | **stop and ask the human.** Installing it gives this machine another person's environment |

The kit's record is the one `*.lock.json` at this directory's root. It is `loom.lock.json` in
almost every kit; wherever this file says `loom.lock.json`, use the real name.

## 1 · Check the tools

```sh
for c in git jq bash python3 gh claude; do command -v "$c" >/dev/null && echo "ok       $c" || echo "MISSING  $c"; done
gh auth status
claude -p 'Reply with the single word: ok' --output-format text
```

**Check:** every tool prints `ok`; `gh auth status` shows a GitHub account that can see this
kit; the last command prints `ok`.

- A tool is missing: tell the human which, and stop.
- **HUMAN**, if `gh` is not logged in: `gh auth login`. When the kit lives in an organisation the
  account cannot see, GitHub answers "Repository not found". That means the wrong account far
  more often than a missing repo.
- ⚠️ `claude auth status` is not a login test. It reads a file, and it reports a signed-in
  account even when the session can no longer refresh. The one-word call above is the test.

## 2A · Make your own copy of a generic kit

The public repo ships **generic kits**: sets of skills for a kind of work, not for a person.
`kits/dev` is for writing and shipping code. `kits/knowledge-worker` is for work whose output is
documents rather than code. Each pulls in `kits/method-core`, the method itself, on its own.
There are narrower kits too:

```sh
bash starter-kit/instance/bootstrap.sh --kit list
```

**HUMAN:** choose the kit (or kits; `--kit` repeats), a name for the setup such as `my-agent`,
and the GitHub owner of the private repo: their own account, or their organisation.

```sh
bash starter-kit/instance/bootstrap.sh <name> --kit <kit>
cd ../<name>
git init -q
git add -A
git commit -q -m "my agent setup, from kits/<kit>"
gh repo create <owner>/<name> --private --source . --remote origin --push
```

`bootstrap.sh` writes the new directory beside this checkout, never inside it, and pins the
method at the commit that is current right now. Then fill in `KIT.md` in the new directory with
the human. It takes five minutes and it is what the next person reads.

**Check:** `gh repo view <owner>/<name> --json visibility -q .visibility` prints `PRIVATE`, and
`git remote get-url origin` names that repo. **Tell the human to run Claude Code from the new
directory from now on**, and continue at step 3 there.

## 2B · Make your own copy of a team kit

A team kit is a template. It describes nobody's machine yet, and its maintainer keeps pushing
to it. Customise your own copy, never the shared one: a change made in the shared repo is
overwritten by the next update, and nothing warns you.

**Read `KIT.md` now.** Tell the human what it says must be granted before an install (the full
list is in `ACCESS-CHECKLIST.md` when the kit has one) and anything it marks as not reversible.

**HUMAN:** choose the name and the GitHub owner of the private repo.

```sh
git remote rename origin kit-upstream     # keep the kit as a second remote, for its updates
gh repo create <owner>/<name> --private --source . --remote origin --push
jq '.instance.kind = "instance" | .instance.name = "<name>" | del(.instance["$kindNote"])' loom.lock.json > loom.lock.json.tmp
mv loom.lock.json.tmp loom.lock.json
git add loom.lock.json
git commit -q -m "make this kit mine"
git push -q origin HEAD
```

**Check:** `gh repo view <owner>/<name> --json visibility -q .visibility` prints `PRIVATE`;
`git remote -v` shows `origin` (the human's repo) and `kit-upstream` (the kit);
`jq -r .instance.kind loom.lock.json` prints `instance`.

## 3 · Add this machine (once per machine)

Every machine has its own record under `instances/`. The root `loom.lock.json` is the base new
records are copied from. A few older kits also use the root file as their first machine's
record, and their `KIT.md` says which machine; every other machine still gets its own.

Name the machine like this, and use the same name every time you come back to it:

| machine | name |
|---|---|
| a laptop | `laptop-<user>-<os>`, for example `laptop-ana-macos` |
| a cloud workspace | `<provider>-<deployment>--<workspace>`, for example `coder-acme--dev-1` |

```sh
ls instances/ 2>/dev/null        # does this machine already have a record?
M=<machine-name>
mkdir -p "instances/$M"
jq --arg m "$M" --arg h "$HOME" --arg p "$(uname -s)" \
  '.instance = ((.instance | if type == "object" then . else {} end) + {name: $m, kind: "instance"})
   | del(.instance["$kindNote"]) | del(.install.identity) | .probed = {}
   | .machine.home = $h | .machine.platform = $p' \
  loom.lock.json > "instances/$M/loom.lock.json"
```

If `instances/<this machine>/` already exists, someone set this machine up before: skip the copy
and use it. **Never install another machine's record.** It installs that machine's paths and
profile here and still reports success.

The command sets `machine.home` and `machine.platform` from this machine, so a record copied from
a laptop does not describe a Linux workspace as a Mac. It also drops the source record's declared
identity and its `probed` measurements: those describe the machine the root record came from, and
`identify.sh --declare` in step 4 refuses a record that already declares one. Then edit what else is true of **this**
machine: `codeRoot`, an existing directory where code checkouts live (for example `$HOME/code`;
create it first, because step 4's proof checks that it exists), and `codeLayout` if `KIT.md` says
the kit uses lanes. Leave `probed` alone; the tools write it.

**Check:** `jq -r .instance.name "instances/$M/loom.lock.json"` prints the machine name, and the
directory `jq -r .codeRoot "instances/$M/loom.lock.json"` names exists.

## 4 · Install

```sh
bash install.sh --lock=instances/$M/loom.lock.json
```

It fetches everything at the pinned commits, installs the skills and hooks the record declares,
links the `vendor/` cache beside the record, checks the result against the record, and proves
the machinery runs. It is safe to re-run. `--dry-run` prints the plan and changes nothing.

**Check: read the exit code, not the last line.**

| exit | means | do |
|---|---|---|
| `0` | installed; `RESULT: LOCKED` and `PROVE: PASS` | continue |
| `1` | a precondition failed and nothing was installed | fix the one thing it names, and re-run |
| `2` | installed, but the result does **not** match the record | read the `DRIFT` and `FAIL` lines; each names the item and its repair |

Then record this machine's identity, so that installing this record on a different machine is
refused, and save the record:

```sh
bash boot-kit/scripts/identify.sh --declare "instances/$M/loom.lock.json"
git add "instances/$M"
git commit -q -m "add machine $M"
git push -q origin HEAD
```

If `boot-kit/scripts/identify.sh` is absent, the kit keeps the engine only in its cache: use
`vendor/dark-factory/boot-kit/scripts/identify.sh`. The same holds for `validate.sh` in step 6.

**Check:** `bash boot-kit/scripts/identify.sh --lock "instances/$M/loom.lock.json"` exits `0`,
and the push succeeded. Push before relying on the record: a record that exists only on the
machine it describes is one rebuild away from gone.

## 5 · Connect your tools (HUMAN)

No script can sign in for you, mint a token or grant access, so the install ends by printing what
is left. Walk the human through it one item at a time. [`AUTHENTICATION.md`](AUTHENTICATION.md)
explains each connection; `ACCESS-CHECKLIST.md`, when present, says who grants what.

**Three settings you merge by hand.** Each lands in a file shared with everything else the human
runs, and a script that rewrote those files would silently delete another tool's configuration.

| do this | from |
|---|---|
| merge the hook registration into the harness settings | `boot-kit/settings.template.json` |
| copy the hub entry into the harness config; the token stays in the environment | `boot-kit/mcp.template.json` |
| copy the output style into the harness's output-styles directory and select it | `boot-kit/output-style.md` |

**The hub is optional.** It gives the agent shared memory across sessions and machines, plus
connectors to the systems the human already uses. The method runs without one.

- **Already have a hub:** put its address in the `url`, and export its token as `DF_HUB_TOKEN`
  in the shell profile. The config refers to the variable; the token itself is never written to
  a file. A headless run whose parent never exported it starts cleanly, then fails every hub call.
- **No hub yet:** the template points at OneDroid Synapse, a public hub anyone can sign up for.
  It is a default, not a requirement. The vendor's walkthrough is
  <https://docs.onedroid.ai/quickstart>; follow it, with these four traps in mind:
  1. Sign up at <https://synapse.onedroid.ai>, and **use the same sign-in method every time**.
     Sign-in is Clerk, so Google and Microsoft on the identical email are two separate accounts.
     The symptom is signing in fine and finding no hub.
  2. If you bring your own Postgres, leave the literal `[YOUR-PASSWORD]` placeholder in the
     connection string exactly as it appears. The password is spliced in from its own field.
  3. Before minting a token, check the hub picker shows the hub you mean. A token is bound to one
     hub, and its plaintext is shown once.
  4. A new hub has zero connections. If it stays at zero, the upstreams are not enabled, and only
     an admin can enable them. Someone invited into another person's hub holds a valid token,
     sees no tools, and has to ask the hub's owner.
- **Bring your own hub instead:** replace the `url` and rename the server key. Ask your provider
  for the exact path rather than assuming it matches the default's.
- **No hub at all:** delete `boot-kit/mcp.template.json`. Everything else still works.

Then prove it:

```sh
df-preflight --report          # or: python3 boot-kit/scripts/df-preflight.py --report
```

**Check:** no `drift` on a hub or connector the record declares. `unknown` means it could not
look, which is neither a pass nor a failure; say which one, and why. A hub answering `401`
means a wrong token or a header that never arrived, and those look identical from here:
<https://docs.onedroid.ai/troubleshooting> tells them apart.

Then **open a new Claude Code session in this directory.** Tools and hooks load only when a
session starts.

## 6 · Validate

```sh
bash boot-kit/scripts/validate.sh --kit-root "$PWD" --headless
```

It opens a fresh session that exercises every gate the kit installs, writes
`VALIDATE-REPORT-<time>-<machine>.md`, and commits and pushes that report to the human's repo by
itself. It takes about ten minutes and costs a few dollars.

**Check:** exit `0`; a new report on the repo's `main`; and the report's **Broken** section says
nothing in the kit is broken. Show the human that section verbatim.

| exit | means |
|---|---|
| `3` | the report did not reach the repo. The output names the step that failed |
| `4` | the session could not start, almost always the login from step 1 |
| `5` | another validation is already running against this kit |

`VALIDATE-INSTALL.md`, where the kit ships it, is the same check as a prompt to paste into a
session by hand.

---

## Every other machine

On each new machine: `gh repo clone <owner>/<name>`, open Claude Code in it, and tell it to read
this file and execute it. It lands at step 3, because the repo already exists.

## Keeping current

- **Your own changes:** commit and push from any machine. On the others, `git pull`, then re-run
  step 4 with that machine's `--lock=`.
- **A team kit's updates:** `git fetch kit-upstream`, then `git merge kit-upstream/main`. The
  merge moves the pins in the root record only. Carry each pin that moved into every machine's
  record, or those machines keep installing the old one:
  ```sh
  C="$(jq -r '.upstreams["dark-factory"].commit' loom.lock.json)"
  for r in instances/*/loom.lock.json; do jq --arg c "$C" '.upstreams["dark-factory"].commit = $c' "$r" > "$r.tmp"; mv "$r.tmp" "$r"; done
  ```
  Do the same for any other upstream whose pin moved. Push, then re-run step 4 on each machine.
- **The method's updates (generic kits):** set `upstreams.dark-factory.commit` to the commit you
  want in the root record and in every `instances/*/loom.lock.json`, push, then re-run step 4 on
  each machine.
- **Never edit `vendor/`.** It is a cache the installer rebuilds, and edits there are lost.

## Working in it

Start sessions in this directory, or in a notepad beside it, not inside a code repo. Working
memory and mission state are found by walking **up** from where the session starts, so a session
started inside a code repo restores nothing and says nothing. Reach code repos with `git -C`.

A kit made by `bootstrap.sh` also carries a worked example, `.df/missions/EXAMPLE-FIRST-RUN/`.
It confines every write to its own directory and needs no hub:
`df-mission start EXAMPLE-FIRST-RUN --profile default --max-iter 5 --max-usd 5`.

## When it goes wrong

| symptom | almost always |
|---|---|
| "Repository not found" for a repo you can open in a browser | the wrong `gh` account, not a missing repo |
| `install.sh` exits `2` and reports every pin missing | the record's `vendor` link is absent. Re-run step 4, which creates it |
| "`--lock` takes an = sign" | write `--lock=instances/<machine>/loom.lock.json` |
| validate exits `4` with "OAuth session expired" | the login cannot refresh. **HUMAN:** `claude auth login` on this machine |
| a tool you connected does not appear | the session started before you connected it. Open a new one |
| a skill you declared is "unknown" | the session started before the install, or the record has no source for it |
| every hub call fails and nothing else is wrong | the token variable is not exported in this process |
| signed in, but there is no hub or the wrong one | a different sign-in method from the one used at sign-up: two accounts, one email |
| connected, token valid, zero tools | the hub has no upstreams enabled. Only an admin can enable them |
| `ERR_SCOPE_UNAVAILABLE` | a token sent to a browser-style hub address. See `AUTHENTICATION.md` |
| `df-mission: command not found` | it installed, but the bin directory is not on `PATH` |
