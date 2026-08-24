# Contributing

The method here is opinionated and earned. Most rules exist because something
failed — often expensively. That shapes what a good contribution looks like.

## The one rule that matters

**If you propose a change, say what failure it prevents.** "Cleaner", "more
consistent", or "best practice" are not reasons. A rule that cannot name its
failure is a rule nobody will keep under pressure.

Conversely: if you can name a failure this repo does not defend against, that is
a valuable issue even with no patch attached.

## What belongs here, and what does not

This repo is the **canonical, generic** method. Organisation-specific bindings —
trackers, board ids, clusters, deploy pipelines, domain rules — live in separate
repos that consume this one.

Read [`CONTENT-BOUNDARY.md`](CONTENT-BOUNDARY.md) before your first PR. The short
version: nothing here may name a client, a cluster, a hostname, a ticket, or a
person. The distinction that catches people out is **landmarks vs vocabulary** —
`HIPAA` and `Schematron` are public standards and belong; a real cluster ARN or an
internal project code does not.

## Before you open a PR

```bash
bash boot-kit/scripts/publish-gate.sh --history
```

It must print `CLEAN`. The gate scans the working tree *and* every blob ever
committed, because a deletion does not remove git history.

### First run: you will be on placeholder patterns

The real landmark list lives in `boot-kit/scripts/landmarks.conf`, which is
**gitignored and not in your clone**. It has to be: that file *is* the list of
nouns that must not be published, so committing it would publish exactly what the
gate protects.

So a fresh clone falls back to `landmarks.example.conf`, whose patterns match
fictional companies. The gate says so on its first line:

```
landmarks: landmarks.example.conf (PLACEHOLDER PATTERNS — copy to landmarks.conf and edit)
```

Read that line every time. A gate on placeholders and a gate on real patterns
produce an identical `CLEAN`, and only that line tells them apart.

If you maintain your own estate, `cp landmarks.example.conf landmarks.conf` and
put your real patterns in it.

### What CI can and cannot tell you

The `gate` workflow runs on every PR, and it runs against the **example** config
for the same reason — GitHub has no access to anyone's real landmark list, and a
fork PR could not reach a secret even if one existed.

A green check therefore proves:

- the gate is well-formed and runs
- no pattern class has gone inert
- no *placeholder* landmark leaked

It does **not** prove the branch is free of real landmarks. Only a maintainer
running the gate locally, with a real `landmarks.conf` present, can prove that —
and the PR template says so where a merger will actually see it.

This gap is stated rather than papered over. A check that looks stronger than it
is is worse than no check, because people stop looking behind it.

**If you changed the gate or `landmarks.conf`, run the self-test:**

```bash
bash boot-kit/scripts/gate-selftest.sh
```

It plants a known-positive canary for every pattern class and asserts the gate
**fails** on each, then asserts the baseline is clean with no canary present. A
gate that fails on everything is as useless as one that passes on everything.

Adding a pattern means adding its canary. That is deliberate friction: it forces
you to state what the pattern is supposed to catch, and it is the check that
would have caught every gate bug this repo has had. A gate you have only ever
seen pass is not a gate you have tested — that mistake has been made here twice:

- `P3` matched infra identifiers but never the product name, and reported CLEAN on
  a tree full of landmarks.
- `P2` used `\bmrn\b`. `git grep -E` is POSIX ERE with no PCRE, so `\b` compiles
  without error and matches **zero lines**. The PHI scan could never fire.

Note that plain BSD/GNU `grep -E` *does* honour `\b`, so a pattern tested with
`grep` will look correct and then do nothing under `git grep`. **Test with the
engine that will run it.**

**The self-test cannot find a pattern that is missing.** Its canaries come out of the
same file as the patterns, so a landmark class nobody ever wrote a pattern for has no
canary either — it is invisible, and the self-test goes green with the class entirely
unprotected. That is the third failure mode, and it is live:

```bash
cp boot-kit/scripts/gate-requirements.example.conf boot-kit/scripts/gate-requirements.conf
# fill in a real specimen of each class, then:
bash boot-kit/scripts/gate-reqtest.sh
```

`gate-reqtest.sh` starts from the **policy** side — the list of landmark classes your
publishing rules name — and plants a real specimen of each. `gate-requirements.conf` is
gitignored for the same reason `landmarks.conf` is: it holds the exact nouns that must
not ship. Run it after any change to `landmarks.conf`, alongside the self-test, not
instead of it. The two answer different questions:

| | asks | can it discover an absent pattern? |
|---|---|---|
| `gate-selftest.sh` | is every pattern the config **has** live? | no — its inputs come from the config |
| `gate-reqtest.sh` | is every class the policy **names** caught? | yes — its inputs come from outside it |

Three verdicts, and `INDETERMINATE` is not a synonym for either other: with no local
requirements file the tool exits **2** and reports that nothing was measured, rather
than reporting a green. "Could not check" rendered as "nothing found" is the shape of
every gate bug in this repo's history.

## Skills

A skill is a directory under `skills/` containing `SKILL.md` with YAML
frontmatter:

```yaml
---
name: my-skill
description: What it does, and the phrases that should trigger it.
---
```

Frontmatter is not optional. A `SKILL.md` without `name:` and `description:` will
not load in any harness that reads it — and a skill that silently fails to load is
worse than an absent one, because you will believe it ran.

Keep the skill generic. A generically-*named* skill carrying client-specific
content is the failure mode that leaked once already; the name is not the boundary,
the contents are.

## Hooks

A skill is advice; a hook is a control. Anything that must not depend on the
model's judgment belongs in `hooks/`.

If you add a hook that blocks something, **make sure the thing it blocks can tell
why.** A control the actor cannot attribute is indistinguishable from flakiness —
an agent handed a bare denial will reasonably retry until its budget is gone. That
has happened here too.

## Commit messages

Say what failed and what changed. The commit log is where the reasoning lives; a
message that only restates the diff wastes the one place a future reader will look.

## Reporting a security or disclosure problem

See [`SECURITY.md`](SECURITY.md). If you believe this repository has published
something it should not have — a credential, a client landmark, anything
identifying — please report it privately first.
