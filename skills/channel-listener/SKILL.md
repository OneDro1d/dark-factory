---
name: channel-listener
description: Read the sources you name — Teams/Slack channels, a code repo's commits and pull requests, a Confluence space, a tracker board or one person's tickets — and report only what is relevant to a project you name. You invoke it; it reads what is new since last time, checks each claim, and proposes what to do. Triggers on "check my channels", "what did I miss", "what happened in <repo>", "anything new in <space>", "what is on the board", "catch me up", "channel listener".
---

# channel-listener

You run it; it reads what is new since the last run and reports only what matters to the
project you named. Nothing is deployed and nothing polls: it does one pass per invocation.

⚠️ **STATUS.** Rewritten 2026-09-14 down to that one job. The previous version tried to be a
standing, self-driving watcher — a lock, a four-state durable inbox, crash recovery, a surge
guard, thread following. An independent adversarial review found ~35 defects in that machinery,
16 of them correctness bugs, and it had never run end to end. Most of those are gone here
because the machinery they lived in is gone: a command you invoke does not need to survive its
own crash mid-handler. What remains is listed under *Limits*, honestly.

**This file ships no channels and no project definitions.** Both come from you at `setup`.
Anything here that looks like a channel, a project or an id is an example; resolve real values
live, never by copying.

## Modes

| | |
|---|---|
| `setup` | Ask which sources and which project. Write the config. Seed the watermarks to now. |
| `check` | The default. Read what is new, judge it, report it. |
| `forget` | Delete the config and state. There is nothing else to stop. |

## Source kinds

A source is anything with an ordered stream of items and a cursor. The loop under *Check* is the
same for all of them — read past the cursor, judge relevance, verify the claim, report, advance.
Only these three columns differ, and **only this table needs to change to add a kind.**

| `kind` | an *item* is | cursor (`last_seen`), in the source's OWN native type |
|---|---|---|
| `teams` | a channel post | `createdDateTime`, ISO-8601 |
| `slack` | a channel message | `ts`, epoch seconds as a **string** |
| `repo` | a commit on a watched branch, or a PR opened / merged / closed / review-requested | commit `committedDate` ISO-8601; PRs `updatedAt` ISO-8601 — **two cursors, kept separately** |
| `confluence` | a page created or updated in the space | page `version.when`, ISO-8601 |
| `tracker` | an issue created or transitioned, on a board or matching a person filter | issue `updated`, ISO-8601 |

⚠️ **A repo, a space and a board are NOT low-volume like a chat channel.** One merge can be 40
commits; a sprint transition moves 30 issues at once. Two consequences, and neither is optional:
the relevance filter does more work here than it does on chat, and **`report_max_items` will
actually bite** — when it does, say how many were dropped and on what ordering, rather than
silently reporting the first N.

⚠️ **A commit, a page diff and an issue body are ALL far larger than a chat message.** The
two-memory rule under *Check* is not a nicety here, it is the only thing keeping a repo source
from filling the context window with a diff nobody asked to read. Keep the subject line, the
ids, the URL — **never the diff, never the page body.**

⚠️ **One source, one estate — and the estate is read from the config, never inferred.** A repo,
a Confluence space and a tracker board each belong to exactly one estate, and the hub that can
read them is that estate's. Declare `hub` per source. **Do not reach across:** a source in one
estate must not be read through another estate's hub even when the tool happens to resolve,
because "it resolved" is not the same as "this session may see it".

## Setup

**Resolve the tool names in THIS install first.** Tool prefixes are per install, and a wrong
prefix is indistinguishable from a missing tool. List the available tools and find the real
channel-read and channel-list tools for each platform being watched. Resolve each platform
separately: one hub does not necessarily carry both, and a failure on one says nothing about the
other. If nothing resolves, ask; never guess.

**`setup` is a conversation, not a form.** Ask, wait, and never substitute a default because the
answer seems obvious — a wrong channel is silent, and a listener watching the wrong place looks
exactly like a quiet week.

1. **Which sources?** Enumerate everything they could pick and show it numbered. Let them answer
   with numbers or names, resolve each to an id from the list you just printed, and **read the
   resolved set back before writing**. If a name is not in the enumeration, say so and show near
   matches — never resolve by guessing.

   - **Teams** — list every team, then the channels in each, and show `team / channel`. Channel
     names repeat across teams and a bare name is ambiguous.
   - **Slack** — include private channels explicitly; the default is public-only, so without that
     a channel they use daily reports as not existing.
   - **Repo** — resolve `owner/repo` against the account that can actually see it, and ask
     **which branches** (default: the default branch only) and whether they want commits, PRs or
     both. ⚠️ A 404 here means the wrong identity far more often than a missing repo.
   - **Confluence** — list spaces and store the space KEY, not its display title: titles are
     renamed and keys are not.
   - **Tracker** — ask for a board, a project, or a person. ⚠️ **Resolve the workspace/site id
     LIVE at every run, never from the config**: these are ephemeral and have been recreated
     under this estate, which broke every hardcoded copy at once.

   ⛔ **For a person filter, get the account id from the tracker's OWN directory, and never from
   a call you pass the identity to.** Ask for the person, search the tracker's user directory,
   show the matches with enough to disambiguate, and let the operator pick. This estate has been
   burned by lookups that **ignore the id argument and return the caller** — two such calls
   "confirm" each other, a correct attribution gets corrected into a wrong one, and the report
   then silently covers the wrong human. Prefer the record that DECLARES the identity; a call
   that does not error is not a call that was right.
2. **Which project?** What it is called in conversation, and what it is called in the system:
   repos, services, ticket-key pattern, namespaces, the people whose posts about it matter.
   This is what makes a message relevant, and it is theirs to define.
3. **Action policy** — `report-only` (default) or `act`. See *Action policy*.

Config: `~/.claude/channel-listener/config.json`, shape in `reference/config.example.json`.

## State

One file per source: `~/.claude/channel-listener/state/<key>.json`, holding `last_seen` and the
last ~200 `seen_ids`.

⚠️ **`last_seen` has a DIFFERENT TYPE per platform.** Teams uses ISO-8601
(`createdDateTime`); Slack uses epoch seconds as a string (`ts`, and `oldest` expects the same).
They are not comparable. **Store each platform's own native value** — converting invites a
rounding bug at exactly the boundary that decides whether a message is re-read or skipped — and
read it back through the source's `kind`, never by sniffing the value's shape. When ordering
items from both platforms in one report, sort on a normalised UTC timestamp computed for the
sort only; never write that normalised value back as `last_seen`.

⚠️ **Dedup by message id, not timestamp.** Edit timestamps change, so a timestamp-only watermark
replays edited messages forever.

⚠️ **The same rule, sharper, on the non-chat kinds.** A PR and an issue are *long-lived mutable*
objects: they move on every comment, label and transition, so an `updatedAt` cursor alone
re-reports the same PR forever. Dedup on **`<id>@<updatedAt>`**, not on the bare id — the bare id
would report a PR once and then never again, silently swallowing the merge you actually cared
about. A commit is immutable, so its sha alone is enough. **A repo source keeps TWO cursors**,
one for commits and one for PRs; they advance independently and collapsing them loses whichever
moves slower.

⚠️ **Confluence: a page is not new because its version number rose.** A typo fix and a rewritten
runbook both increment it. Record `version.number` alongside the timestamp and say *created* or
*updated* in the report — they mean different things to the reader and only one of them usually
needs an action.

## Check

For each source:

1. **Read items newer than `last_seen`.** Slack has a server-side `oldest`; Teams needs
   client-side filtering. **The read-size key differs: Slack takes `limit`, Teams takes
   `max_results`** — same meaning, neither tool accepts the other's name.

   **Push the cursor into the QUERY on the kinds that support it, and know which those are.**
   A repo lists commits `since=<cursor>` and PRs sorted by `updated` descending — stop paging at
   the first item older than the cursor. A tracker takes it in the query language itself
   (`updated >= "<cursor>"`, plus the board or the person clause) — **let the server filter**,
   because pulling a whole board and filtering client-side is how a check that should cost one
   call costs thirty. Confluence sorts by last-modified; page until you pass the cursor.
   ⚠️ Where a kind has **no** server-side cursor, say so in the report rather than quietly
   reading a fixed window and calling it complete.

   **Start small and page.** If the oldest message returned is still newer than `last_seen`,
   there is more beyond the window: page (Slack `cursor`) until the oldest predates it. **Do not
   widen the read instead.** One measured Slack read of 30 messages returned ~83,000 characters
   and **errored outright rather than returning less** — so a failed read leaves you with nothing,
   not with fewer. That is one datapoint from one platform, and whether size or count is the
   binding constraint was never isolated; treat it as a reason to page, not as a law.
   If you cannot reach back to `last_seen`, **say so in the report** — a silently truncated
   catch-up is the failure this is least able to notice about itself.

2. **A single oversized message is a separate problem, and capping the count does not fix it.**
   Keep the first ~2000 characters of the markup-stripped text for judging, and record the
   message's permalink (`webUrl` on Teams, `message_link` on Slack) rather than its body. Say
   `truncated` in the report so the reader knows to open the original. If even a single-message
   read fails, report it as unreadable with its id and permalink — never drop it silently — and
   move on.

3. **Judge relevance, one message at a time, on the session's own model.** Is this about the
   project the operator named? Use the config's repos, services, ticket pattern, namespaces and
   people, and read the message like a person would — a reply carries its parent's subject
   implicitly, so judge it in the context of the thread it is in rather than demanding it repeat
   the keywords.

   ⚠️ **Never delegate this judgment to a cheaper model.** A false negative here is **invisible
   by construction**: the operator is never told about the message they were never told about, so
   nothing ever surfaces that the cheap model is getting it wrong. The *fetching* may be
   delegated — a wrong fetch shows up immediately as a missing id — and a subagent doing it must
   return raw ids, timestamps and verbatim text, never a summary. Delegate what fails loudly;
   keep what fails silently.

4. **The current task orders, it never filters.** Cheaply note the repo and branch you are in and
   what the operator has been doing this session, and lead with anything that touches it, saying
   why (*"this names the branch you are on"*). A message about their project that has nothing to
   do with today's work is still their project's message. **Use the task to order and explain,
   never to drop.**

   ⚠️ **On a repo, a space or a board the relevance filter is doing MOST of the work.** Chat is
   already roughly scoped by which channel someone posted in; a repo is not. A dependency bump
   and the commit that changes the thing the operator is standing on arrive through the same
   stream and look alike at a glance. Read what the item DID, not what it is called — a commit
   subject and a PR title are both self-descriptions, and a green CI badge says a pipeline ran,
   not that the change is what it claims.

5. **Check each claim before reporting it.** A chat message is a claim about the world, not the
   world. So is a commit subject, a PR description, a page's summary and an issue's status
   field — **"Done" on a board is a claim that work happened, not evidence that it did.** Where
   a check is cheap and read-only, take it: read the linked ticket, confirm the PR actually
   merged rather than just being titled as if it had, open the page and see whether the section
   it claims to add is there. Where a check is cheap and read-only, take it: read the ticket it names, look at the
   pod it says is failing, confirm the deploy it announces landed. Report both what was said and
   what you found, and say plainly when they disagree. If a check is impossible — no access, the
   ticket is in a project you cannot see — mark it **unverified** and name what blocked it,
   rather than implying it was checked. **Verification is allowed under every action policy**: it
   is read-only.

6. **Advance `last_seen` only after the report has been given**, and mark the ids seen. A second
   run before the first finishes re-reports; it does not skip. That is the safe direction.

## Report

One consolidated report. Urgent first — anything naming this operator directly, or production
impact — then oldest first.

**One line per message**: who, when, the gist, the permalink, and a proposed next step.

For the proposal: name a **specific** action, not a category ("re-run the e2e against the new
image", not "look into it"). **"No action needed, recorded for awareness" is a valid and common
proposal** — inventing work to look useful is worse than silence. If several messages point at
one thing, propose once for the group. The proposal is a question, not permission.

Cap at ~8 items. Beyond that, give counts by topic, list the urgent ones and the ones with a real
action, and say how many more there are. Nothing is lost — the watermark has not moved past them
in a way that hides them, and the reader can ask.

**If nothing was relevant, say so in one line.** Do not narrate an empty run.

Then the operator answers. **Yes** → do it, bounded by *Action policy*. **No** → it is done;
drop it, and do not raise the same thing again unless it returns with materially new information.

## Action policy

| Value | Behaviour |
|---|---|
| `report-only` | **Default.** Read anything in order to verify — tickets, logs, repos, cluster reads — then report and propose. **No writes.** |
| `act` | Also writes: ticket comments, non-production changes. The operator sets this deliberately. |

**The boundary is writes, not reads.** A default that cannot check is a default that repeats
whatever chat said, wearing the authority of a report.

At every level the standing hard stops bind: production deploys, protected-branch merges,
outbound mail or posts, regulated data, and any irreversible real-world act stop for a human.

## Hard rules

- **Never post as someone else.** If the session's posting identity on a platform is not the
  operator, this skill is **read-only** there. Posting as another person is unrecoverable; a
  missed reply is not, and that asymmetry decides every ambiguous case.
- **Re-read the posting identity immediately before each post, not once at setup.** It is a
  reading with an expiry: a Slack identity was measured changing mid-session, silently, from one
  person to another.
- **Never add another person's id to the self-filter.** That list means "ignore as my own
  output". A colleague's id there silently drops every message they post — for a listener
  watching their work, close to the worst possible failure.
- **A timed-out read is safe to retry; a timed-out write is not.** A timeout is precisely the
  state in which you cannot tell whether it landed.
- **A negative result is per install.** "This tool is broken" is not a fact about the estate
  until it has been tried on every hub that exposes it — measured: the same Microsoft tool
  returned `null` on one hub and worked on another, and the first reading was taken as the truth.

## Limits

- **It does one pass when you run it.** Nothing watches between runs. Watermarks persist, so the
  next run catches up; the cost of a gap is latency, not data.
- **Two runs at once may report the same messages twice.** The watermark advances after the
  report, so the duplicate is the failure mode rather than a skip. Run one at a time.
- **Relevance is a judgment and it will sometimes be wrong.** A false negative is invisible —
  that is why step 3 refuses to delegate it, and why an ambiguous message should resolve toward
  reporting it.
