# TICKETS — EXAMPLE-FIRST-RUN

The tracker for this mission is this file. That is the point: the loop's discipline lives
in the claim convention, not in any particular tracker product, and a kit that only ran
against one hosted board would not be a generic kit.

## How to use it

**Claim before you work.** Set `Claimed By` to `<role>/<short-id>` and `Status` to `Doing`
in the same edit, then start. An unclaimed half-done ticket is indistinguishable from an
untouched one, so the next iteration begins it again from nothing.

**Frontier** = `Status: Ready` **and** `Claimed By:` empty **and** `Blocked By:` satisfied.
Take one. Not two.

**Evidence goes under the ticket, verbatim.** The command, then its literal output. Not a
summary of the output and not a claim about it — a summary cannot be re-checked, and the
whole method rests on a later reader being able to re-check.

Statuses: `Ready` · `Doing` · `Review` · `Done` · `Blocked`.

---

## E1 — inventory the installed engine

**Status:** Ready · **Role:** dev · **Effort:** S · **Blocked By:** —
**Claimed By:**

Establish which pieces of the Dark Factory runtime are actually present and runnable on
this machine, as opposed to declared. For each engine script the lockfile installs, record
whether the file exists, whether it is executable, and what it prints when asked for its
usage.

Two failure modes this is looking for, both of which look like success from the outside:

- a script that is installed but not on `PATH` — installed-but-unreachable is not
  installed, and it surfaces much later as `command not found` pointing at the wrong thing;
- a script that exists but cannot run here, because an interpreter or a dependency it
  needs is missing.

**Evidence:** for each script, the command you ran and its literal output, including the
exit status. Where a script has no usage output, say so — silence is a result, but only if
it is recorded as one.

**Evidence:**

---

## E2 — run the preflight and read it honestly

**Status:** Ready · **Role:** dev · **Effort:** S · **Blocked By:** —
**Claimed By:**

Run the preflight probe in report mode and record its three verdict counts — `ok`, `drift`,
`unknown` — verbatim, together with its exit status.

Then do the part that matters: name at least one thing it reported as `unknown` and say
what would have to be true for it to become `ok`. If it reported no unknowns at all, that
is itself a claim needing evidence — say which checks ran, and why a machine with no
network access to some of them still produced none.

`unknown` is not a polite `drift`. `drift` means it probed and reality differs; `unknown`
means it could not probe. Collapsing the two is how a network blip gets written down as a
fact about the machine, and this ticket exists to make you read them apart at least once.

**Evidence:** the command, its exit status, the verbatim verdict lines, and your reading of
one `unknown`.

**Evidence:**

---

## E3 — write RESULT.md

**Status:** Ready · **Role:** po · **Effort:** S · **Blocked By:** E1, E2
**Claimed By:**

With E1 and E2 done, write `RESULT.md` in this directory. Four sections:

1. **What was shown to work** — each item citing the command and output from E1 or E2.
2. **What could not be shown** — everything the run could not reach, and why. This section
   being empty is a defect, not a triumph: a run with no blind spots has not looked hard
   enough at itself.
3. **What a reader on another machine should expect to differ** — which findings are about
   this laptop and which are about the kit.
4. **The loop itself** — how many iterations it took, which tickets each one claimed, and
   anything about the mechanism that surprised you.

Then set this ticket to `Done` and write `DONE` to `state`.

**Evidence:** `RESULT.md` exists, and each claim in section 1 traces to a recorded command.

**Evidence:**
