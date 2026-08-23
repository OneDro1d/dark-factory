# EXAMPLE-FIRST-RUN — prove the loop on this machine, touching nothing else

This is the worked example that ships with the kit. It is a **real mission**, not a
simulation: a supervisor starts it, fresh iterations claim its tickets, and it produces an
artefact you will actually want. What makes it safe to run on any machine is not that it
pretends — it is that everything it may write lives inside this one directory.

Run it once, immediately after `install.sh`, before you frame a mission of your own.

## Objective

Produce `RESULT.md` in this directory: an honest account of what the Dark Factory runtime
on **this** machine could be shown to do, what it could not, and which of those two a
reader on a different machine should expect to change.

"Honest" is the load-bearing word. A `RESULT.md` that says everything works is worth
nothing unless it also says what it could not see. Every claim in it carries the command
that produced it and that command's literal output.

## Done looks like

- `RESULT.md` exists in this directory and every claim in it cites a command and its output.
- All three tickets in `TICKETS.md` are `Done`, each with evidence recorded under it.
- Nothing outside this directory has been created, modified or deleted.
- The final iteration writes `DONE` to `state`.

## This mission overrides the standing iteration template — deliberately

The rendered iteration prompt is generic. It names a tracker, a `MAP.md` at the notepad
root and a `handoffs/` directory beside it. This mission has none of those, and its own
frame outranks the template. Concretely:

| the template says | here, instead |
|---|---|
| claim a ticket on the tracker | claim it in `TICKETS.md`, in this directory |
| update `MAP.md` at the notepad root | update `TICKETS.md`; there is no map, three tickets need none |
| write a handoff into `handoffs/` | write it into `handoffs/` **inside this directory** |
| load the estate binding skill | there is no estate. Skip it; nothing here needs a binding |

That substitution is the first thing this example teaches, and it is why the template's own
section 0 says the mission wins. A generic loop that could only ever run against one
tracker would not be a generic loop.

**There is no tracker, no hub and no network in this mission.** If a step seems to need one,
that is the finding — record it in `RESULT.md` rather than reaching for it.

## The tickets

`TICKETS.md` holds three, with one blocking edge, because a single-ticket example would not
show the thing worth showing: a frontier that advances. `E1` and `E2` are both ready and
independent; `E3` cannot start until they are done.

One ticket per iteration. Claim before you work, not after — an unclaimed ticket that is
half-done looks exactly like an untouched one to the next iteration, which will start it
again from the beginning.

## Not in scope

- Any git operation. No `add`, no `commit`, no branch, no push. This mission produces a
  file, and whether that file belongs in your history is your decision, not the loop's.
- Any network call, hub call or tracker write.
- Any change to your harness configuration, your lockfile, or anything installed.
- Fixing whatever the run turns up. If the runtime is broken here, `RESULT.md` says so
  precisely; repairing it is a mission you frame yourself afterwards.

## Why this is the example, and not a "hello world"

A hello-world mission proves the loop can run and nothing else, so a machine on which it
passes can still fail on the first real mission. This one exercises the parts that actually
break during onboarding — is the engine reachable, does the preflight report unknowns
honestly, does a fresh iteration inherit enough to work — and it leaves behind a record you
can read months later when something has drifted, or paste into an issue when it has not.
