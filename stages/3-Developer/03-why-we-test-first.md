---
title: Why We Test First — The Logic of TDD (for everyone)
stage: 3. Developer
type: rationale
status: living
audience: all (non-developers welcome)
---

# Why We Test First — The Logic of TDD

## TL;DR

A **test** is an executable version of a **validation rule**: a tiny program that says *"given this input/state, the transform must produce this output — or reject it."* We write the tests **before** the code (**RED → GREEN → REFACTOR**) for two reasons: it forces us to define "correct" before we build, and it leaves behind a permanent **safety net** that lets AI agents keep changing the code without silently breaking it. That safety net is what makes an autonomous Developer stage possible at all.

This doc is the *why*. The *how* — with real Go and Python examples — is in [`02-tdd-implementation-guide.md`](02-tdd-implementation-guide.md).

## A test is an executable validation rule

In [the data-transform model](../../reference/data-transform-model.md), a system is data flowing through transforms, governed by validation rules. A test encodes one of those, in a form a machine can check on every change:

> `State 0 (precondition) → Trigger (input) → expected State 1 (output, or a rejection)`

It either passes (the behaviour is correct) or fails. Nothing more mysterious than that.

## The three beats

### 1. RED — write the test first, and watch it fail
You take one case — say, *"a vitals reading with no `correlationId` must be rejected"* — and write the test for it **before** any real code exists. You run it. It **fails** (red), because the behaviour isn't built yet.

Writing it first matters even if you never touch code:
- It forces you to define *correct* up front, so you can't later fool yourself into believing whatever you built was the goal.
- It proves the test actually tests something. A test that passes *before* the code is written is checking nothing — the red failure is the proof it has teeth.
- The failing test is a precise target: "make exactly this true."

### 2. GREEN — write the simplest code that passes
Now write the least code needed to turn the test green — crude, not clever. Then run **all** the tests; everything should be green.

Why minimal? Anything beyond what the test demands is **unrequested, unproven code** — a hiding place for bugs. You build only what a test asks for.

### 3. REFACTOR — improve the structure, never the behaviour

This is the step most people haven't heard of, and it rests on one idea: **code has two separate properties.**
- **What it does** — the behaviour, visible from outside (does it reject the bad record? charge the card once?).
- **How it's built inside** — the organisation, naming, tidiness — *invisible* from outside.

The tests pin down **what it does**. REFACTOR means: now that the test is green and the behaviour is *proven*, go back and clean up **how it's built** — rename a confusing variable, delete duplicated logic, split an overgrown function — **without changing what it does.** After each small tidy you re-run the tests. Still green? Behaviour unchanged, you're safe. A test goes red? You accidentally changed behaviour — undo it.

Two rules make REFACTOR safe:
- You can only do it fearlessly **because the green tests are a tripwire.** Without tests, "improving" code is gambling — you can't tell if you broke something. With them, cleanup is routine and boring.
- You **never add new behaviour during refactor.** New behaviour needs a new RED test first.

**Analogies:**
- *Writing an essay.* RED = the requirement for a paragraph ("must make argument X"). GREEN = a clumsy draft that makes the argument. REFACTOR = editing for clarity and flow — the *argument is unchanged*, the prose just gets readable.
- *Constructing a building.* RED = the acceptance criterion. GREEN = the quick build that passes inspection. REFACTOR = tidying and labelling the wiring so the next person can maintain it — *the building does the same thing*, it's just no longer a fire hazard.

## Why this is the heart of the dark factory

- **The case list is pre-supplied.** The PO already wrote the validation rules and Test Scenarios. So the agent doesn't invent what to test — it turns each rule into a RED test, writes GREEN code, then REFACTORs. Upstream defines the target.
- **The green suite is a permanent regression net.** In a dark factory, AI agents *continuously* edit and extend code. That net is what makes autonomous editing safe: the moment an edit breaks any behaviour, a test goes red. Without it, every AI change is a roll of the dice.
- **Effects stay safe.** For `effect` transforms (send / charge / notify), the tests also lock *idempotency* and *compensation*, so no future change can quietly reintroduce a double-charge.

## In one sentence

**RED defines the target, GREEN hits it the simple way, REFACTOR makes the inside clean — and the tests are what let us (and the agents) do that last step without fear.**

<!-- ───────────── AI-AGENT CONTEXT BELOW ───────────── -->

## For the agent

This is the *why*; the *how* (workflow + Go/Python examples) is [`02-tdd-implementation-guide.md`](02-tdd-implementation-guide.md). The discipline is non-negotiable: **never refactor on red** (get back to green first), refactor in **small steps** re-running the suite each time, and **never add behaviour during a refactor** — new behaviour starts with a new failing test.

## References

- [`02-tdd-implementation-guide.md`](02-tdd-implementation-guide.md) — the practical how-to
- [`reference/data-transform-model.md`](../../reference/data-transform-model.md) — tests are validation rules + scenarios made executable
- `superpowers:test-driven-development` skill — the canonical discipline
