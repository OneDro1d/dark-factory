---
name: tester-brief
description: Roles, rules and loops for a builder/tester agent pair - the tester is product owner + architect + tester and holds the tests; the builder builds to the tester's spec and never sees the tests. Use when writing a spec, writing or running tests, rechecking the builder's results, verifying a deploy, setting up an optional live test runner (Argus), or triaging a red. Read TESTER-BRIEF.md in this folder for the tester's full method.
---

# Builder/tester pair — how to test and build without the builder seeing the tests

A tester judges the app with checks **the builder did not write and cannot see**. If you remember one thing:
*a builder that reads the checks has no checks.* Everything here is generic; the pair's names, apps, repos,
paths and channels are in `pair.yaml` and in the rendered listener config.

## 1. The roles (one person may own several; one SESSION must not)

| Role | Holds | May use | Where |
|---|---|---|---|
| **Builder** | the code, built only to the tester's spec; forwards new requests with `handoff request` | runner-scope test tokens only (redacted reports) | the builder workspace |
| **Tester** — also product owner + architect | the requirement, acceptance and design (`handoff spec`), and the tests + expected values | author-scope test tokens, its test folder, the live runner | **its own workspace** (`tester.host` in pair.yaml) |
| **Adversary** (optional subagent) | nothing of its own | read-only; gets a claim + evidence, tries to kill it | a subagent of either |
| **Owner** (a person) | approves deploys, merges, answers decisions | chat commands (`approve`, `review`, `deployed`, `<name> restart`, help) | Teams self-chat / DMs |

Why separate: a builder that can see the expected answer writes code that passes the expected answer.
**A sparse checkout is not a holdout** (every blob stays in `.git`), and **no hook on the same identity is a
security boundary** — the guard is a tripwire. The real boundaries are: separate workspaces, the builder
holding only runner-scope tokens (redacted reports), the tester keeping tests in its own home or the test
catalog, and leak markers that make a leak visible (TESTER-BRIEF "Leak markers").

## 2. The loop (`handoff`)

```
someone asks → builder forwards VERBATIM (request) or tester gets it directly
            → tester: clarify, requirement node, acceptance + design (spec / spec-open)
            → builder: build exactly that, unit tests, PR at an exact commit (fix)
            → tester: local test of that commit, no deploy (result --stage local)
            → owner: deploy now, or review first (approve <ns> <min> | review <id> | deployed <id>)
            → tester: live retest (result --stage live) → done → owner merges
```

A FAIL goes back to the builder; after `rules.max_rounds` local or live rounds it is escalated to the owner.
Every step is offered to the team's change channel (`handoff notices --steps`); decision points also go to the
owner's self-chat (`handoff notices`). The full record is in `<paths.ledger>/handoffs/`.

## 3. Builder's checklist (every task)

When `dark_factory.enabled` is true every task runs the Dark Factory loop (`dark_factory.loop_skill`), scaled to
its size: the requirement and design stages are the tester's; the builder's stage is the test-first build
(`dark_factory.skills.build`), then the reviewer (`dark_factory.skills.adversary` / `rules.reviewer`).

1. **Understand** — quote the request. New work → forward it (`handoff request`); never write acceptance.
   Anything ambiguous (scope, target branch, environment, acceptance) → ask; never guess or widen scope.
2. **Build** to the spec in `handoff show <id>`: branch on the app's base, change, Dockerfile-faithful build,
   unit tests. Do not hand over a red build.
3. **Hand over** — `handoff fix <id> --pr .. --commit <40-hex> --deploy-cmd-file .. --rollback-file ..`.
4. **Deploy only** inside an approval window the owner granted (`chat-approval`), or let the owner deploy;
   then `handoff deployed <id>`. Never mark a deploy that did not happen.
5. **Live result** — with a runner id: run, poll the redacted report, report run id + tallies. No runner id or
   no token → write "runner: unverified", never "verified". A red: read the observed side only and triage it
   (`CODE_BUG | TEST_BUG | REQUIREMENT_GAP | FLAKE | INCONCLUSIVE`); fix CODE_BUG, send the rest to the tester.
   **Never re-run until green** — a flake is proved by its rate, not by one pass. Your own test results are
   posted only after the tester's recheck exists (`testrun release` refuses before that).
6. **Before "done"** on anything load-bearing: hand the claim + raw evidence to the reviewer (`rules.reviewer`).
   GO with evidence, or it is not done.
7. **Report** with the shape below, in the PR body and as a bot-marked reply where it was asked. Open the PR;
   never merge it.
8. **Notices** — every tick `handoff notices` → post each to the owner's self-chat AND the change channel
   (bot-marked), plus the email alert; **only after both posts succeed** `handoff notices --mark KEY`. Never post
   on a channel listed in `rules.never_post` (read-only there).

```
WHAT WAS ASKED    <quote + link>
WHAT I CHANGED    <PR link, branch, commits, files>
HOW I TESTED      local: <build/unit results, exact commands>
                  tester: <hand-over id, local/live verdicts, run ids>
                  reviewer: <GO|NO-GO|UNVERIFIED> — <one line>
NEEDS YOU         deploy: `<exact command>`   rollback: `<exact command>`
                  review/merge: <PR>          decisions: <anything I did not decide>
WHAT I DID ALONE  the ledger's writes for this session (pushes, PRs, posts, image pushes)
NOT VERIFIED      <anything not tested, and why>
```

## 4. Tester's checklist
See **TESTER-BRIEF.md** in this folder: order of work, requirement first (and the requirements index),
expected answers from the requirement only, the Dark Factory skill playbook, the check gate, generated
inputs from `repos[].input_schemas`, past bugs as regression checks, the edge-case method, leak markers,
guard-block reports, change-aware runs / test-the-tests / accuracy score (`verdict`), the fix loop, rechecks.

## 5. Optional live runner (Argus)

When `argus.url` is set in pair.yaml, `kit/scripts/argus.sh` wraps the Argus CLI for the pair:

| Command | Who | What |
|---|---|---|
| `argus.sh doctor` | both | read-only health: control plane, sign-in, token presence (sizes only) |
| `argus.sh login author|runner` | tester / builder | device sign-in; the builder must never hold an author token |
| `argus.sh status <app>` | both | `poll_accepted: true` = the app's runner (executor) is live |
| `argus.sh validate <app>` | tester | validate the working-copy scenarios |
| `argus.sh seed <app>` / `run <app> [--scenario ID]` | tester | store in the catalog / run (exit 3 = not green) |
| `argus.sh schedule <app> 1h` | tester | monitor mode once green or every red understood |

Apps come from `argus.apps` (subset of `repos[].app`). Onboarding a runner writes to a cluster: that is the
owner's (or an admin's) step, not an agent's; its egress allow-list (`argus.egress_script`) must admit each of
the app's `repos[].sut_namespaces`. Until a runner is live, every live result is "UNVERIFIED".
- Tester signs in as **author** with a token bound to the app's runner workspace (an account-wide token is
  refused for enrollment); the builder signs in as **runner** only and must never hold an author token.
  Check a token by its size (`wc -c`), never by printing it.
- The tester mints one **runner id** per app instance for the builder (an id, not a secret).
- Every enroll / schedule / teardown is posted to the change channel as it happens.
- **The catalog is the holdout**: every validated check is stored there; `tester.kits_dir` is a working copy
  in the tester's home only — never on the shared disk, never in git. Reuse an app's suite from
  `argus.existing_suites` once its owner OKs it; never duplicate it.

## 6. Accuracy rules

- **Evidence is raw**: run id, HTTP status + body, row counts, digests — not "looks fine".
- **Name the scope of every claim**: "health 4/4 on run X", not "it works".
- **Positive and negative control** for every check.
- **Measurements expire**: re-run before repeating yesterday's result.
- **An absence needs proof the check ran** (exit code, run id).
- **Outbound posts are claims**: read the echoed body back (scanners may rewrite text).

## 7. Guards that enforce this

- `pair-guard` (PreToolUse, builder workspace): blocks reads of the tester's tests and tokens, `coder ssh`
  into the tester's workspace, and exec/cp/debug/attach into the tester's pod (by kubectl or a cloud
  run-command), also when hidden in a local script. Every block is logged to `<ledger>/guard-blocks.jsonl` and
  reported by the tester. It is a tripwire, not a boundary.
- `deploy-gate` (PreToolUse): deploys and cluster writes need the owner's approval window.
