---
name: vinculum-loop
description: 'Run the autonomous, evidence-gated, Promise-Theory-verified control loop (the Vinculum governed loop + Dark Factory process) on any dev project. Use when the user wants to hand over a mission objective with full autonomy under a 2-trigger notify contract (done | blocked-on-all-fronts), evidence-gated decisions (Promise Theory, not self-reports), and an A/B/C decision policy. This is the single entry point that explains how the loop works and points to the dark-factory-build orchestrator. Trigger phrases: "run the loop", "vinculum loop", "give me a mission and full autonomy", "autonomous build".'
---

# Vinculum Loop — the autonomous, governed dev loop for any project

Two pieces work together. Keep them distinct:

1. **The loop = orchestration.** The [`dark-factory-build`](../dark-factory-build/SKILL.md) skill + the Workflow tool. This is what actually *runs*: mission → discover → PO → design → TDD build → deploy → test → ship — autonomously, sub-agent-fanned, Promise-Theory-verified. Works on any project today.
2. **The substrate = trust / provenance (optional, not in this package).** A separate, harness/LLM-agnostic signed-provenance layer can record every decision/action as a hash-chained, append-only ledger entry. It is **not bundled here and not required** — the loop runs fully without it. Enable it later only if your org wants cryptographic provenance.

> You **run** the loop with `dark-factory-build`. The signed-provenance substrate is an optional layer underneath — the loop's correctness rests on Promise-Theory verification, not on signing.

## When to use

- "Give me a mission objective and full autonomy" → the 2-trigger contract.
- "Run the loop / vinculum loop on `<project>`."
- Any non-trivial build you want done end-to-end: evidence-gated, ticketed, documented.

## The contract the loop guarantees (the VR invariants)

- **VR-5 — 2-trigger notify:** come back only when the **objective is met** or **blocked on all fronts**. No step-wise check-ins.
- **A/B/C decisions:** **A** = hard blocker → escalate · **B** = reversible → decide + log · **C** = "is it done?" → own the judgment.
- **VR-1 — evidence-gated (Promise Theory):** decisions rest on *proven* claims; a sub-agent's "done / all passing" is unverified until you re-run its evidence.
- **VR-3 — sensitive data never cleartext public:** keep PHI/secrets private; publish only hashes/metadata.
- **VR-7 — harness/LLM-agnostic:** Claude Code or any agentic harness; API key, subscription, or local OS model.
- **VR-2 / VR-6 — sign-before-act + append-only hash-chained ledger:** provided by the *optional* provenance substrate. **Not active in the default unsigned mode** described here.

## How to run it on a NEW project

1. **Frame:** mission objective + explicit hard-stops (prod deploy, merge to protected branch, financial/on-chain spend, outbound mail/posts).
2. **Orchestrate:** invoke [`dark-factory-build`](../dark-factory-build/SKILL.md), or launch a Workflow running `discover → PO → design → TDD build → deploy(dev) → test → QA`, each stage blind-verified ([`df-adversary-gate`](../df-adversary-gate/SKILL.md)).
3. **Record decisions:** the loop's durable decision record is the stage docs + tickets it writes. (Optional: an internal signed-ledger substrate can additionally sign + hash-chain each entry — not included here, not required.)
4. **Autonomy:** act in dev/non-prod by default; **HARD-STOP** at the boundaries in step 1 —
   production deploys, merges to a protected branch, financial or on-chain spend, outbound mail
   or public posts, and customer-visible configuration. Escalate rather than guess. The
   generic stance is [`work-autonomously`](../work-autonomously/SKILL.md), which ships here
   — an organisation MAY bind a **stricter** one on top of it. The *stance* is method and
   lives at Tier 1; what an organisation adds is the **binding**: which boundaries its
   estate treats as real-world, and which of its own skills implement them. Reference a
   binding by name only, never by path — it resolves on that lane and nowhere else.

## The heartbeat tick — how an attended loop survives the orchestrator's attention

The unattended shape has `df-supervisor.sh`, which is bash and has no context window, so it
ticks by itself. **The attended shape has no such thing**: the orchestrator is a session, and a
session that finishes a turn simply stops. Long authorised work then sits, done or not, until
somebody happens to look.

So when you are running attended and the work outlives one turn, **set a tick** — a scheduled
prompt that re-enters this loop and asks *is there queued work I should be doing?* Point it at
the mission's own state files, not at a summary you wrote, because the files are the state and
the summary decays. End it with an instruction to **stop the tick** when the queue is empty.

⚠️ **`CronList` — or your harness's equivalent listing — is the ONLY proof a tick is live.**
Three failure modes, each observed:

- **A job id written in a file is not evidence.** A tick never survives a session restart, so a
  file naming one describes a job that may have died hours ago while reading as current.
- **Never compose an id.** Copy it from the tool that minted it. A plausible-looking id typed
  from memory produces a record of a tick that never existed — indistinguishable, on the page,
  from one that did.
- **A tick firing over an empty queue is worse than no tick.** It manufactures no-change
  wake-ups, and an operator who sees seven of them learns to ignore the eighth. Delete it the
  moment its scope is finished, and verify the deletion the same way you verified the creation.

⚠️ **A tick is a reminder, not a mechanism.** It does not make work happen; it makes *you* look.
If the work itself must survive the session, that is the unattended shape, and the supervisor
is the answer.

## Maturity — be honest about what is wired

- **Shipped & usable now (this package):** the autonomous loop itself — A/B/C autonomy gate, evidence gating, Promise-Theory sub-agent verification, stage docs + tickets. Runs via `dark-factory-build` + Workflow, **unsigned**, on any project today.
- **Optional / separate (not in this package):** a signed DSSE ledger + hash-chain verify + on-chain anchoring live in an internal provenance substrate (a standalone Go library plus an external blockchain). They are still maturing and are **not required** to run the loop. Until adopted, provenance rests on Promise-Theory verification + the stage docs/tickets the loop writes.

## Running it today — no signing required

**You do not need any substrate, keys, blockchain, or external repo to use the loop right now.** The default is **unsigned mode**: run `dark-factory-build` + the `df-*` skills and let provenance rest on Promise-Theory verification ([`df-adversary-gate`](../df-adversary-gate/SKILL.md)) plus the stage docs and tickets the loop writes. Signed / on-chain provenance is an optional add-on, supplied separately and still being wired — every stage in this skill works without it.

## Related skills

[`dark-factory-build`](../dark-factory-build/SKILL.md) (the engine) · [`df-product-owner`](../df-product-owner/SKILL.md) / [`df-solution-architect`](../df-solution-architect/SKILL.md) / [`df-tdd-developer`](../df-tdd-developer/SKILL.md) / [`df-qa`](../df-qa/SKILL.md) / [`df-adversary-gate`](../df-adversary-gate/SKILL.md) / [`df-dispatch-subagents`](../df-dispatch-subagents/SKILL.md) · [`critical-thinking`](../critical-thinking/SKILL.md) / [`work-autonomously`](../work-autonomously/SKILL.md) (the operating stance). An organisation may bind a stricter stance, and its own memory-recall skill, on top of these (Tier-2).

See also the repo's `HOW-TO-AUTONOMOUS-BUILD.md` for the narrative walkthrough.
