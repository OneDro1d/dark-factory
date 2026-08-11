# 02 — Design Options: Auto-Handoff Across Compaction

**Date:** 2026-06-26 · **Stage:** DF Stage 2 (SA, options) · **Author:** Loom
**Decision owner:** the maintainer — pick A, B, or C (or the B+A hybrid). Then we proceed to TDD + tickets.

> **DECISION (2026-06-26): Option B selected** — live model-maintained handoff with the
> deterministic PreCompact dump as the unskippable safety-net. Build target ~2–3 human-days.
> Next stage = TDD + tickets (see outline at the bottom of this doc).

## TL;DR

Three options on a single **fidelity ↔ cost/complexity** axis. All share the same read-back
path (`SessionStart(compact|clear)` → inject latest handoff as `systemMessage`). They differ
in **how/when the handoff is produced**.

- **A — PreCompact deterministic dump.** Simplest, unskippable, zero model cost. Low fidelity.
- **B — Live model-maintained state (+ PreCompact safety-net).** ⭐ Recommended. High fidelity,
  always-ready, robust. Per-turn token tax.
- **C — ~90% external watcher runs the `/handoff` skill.** Closest to your literal ask, highest
  fidelity *at the moment of capture*. Most complex + racy + relies on % estimation.

All three reuse Loom's existing `handoff` skill and Engram where they need model-written content.

---

## Shared spine (all options)

```
SessionStart(matcher: "compact"|"clear")  →  read .claude/handoff/handoff-latest.md
   (cwd-matched, age-windowed, O(1), no compute)  →  inject as systemMessage   [VR-5,6,7,8]
```

Storage: `.claude/handoff/handoff-<session>.md` + `handoff-latest.md` symlink/copy per cwd;
mirror to Engram (`loom-sessions`, chain-linked) for cross-session search. Atomic write
(temp+rename). Redaction reused from the `handoff` skill.

---

## Option A — PreCompact deterministic snapshot

```
PreCompact (auto|manual)  →  shell reads transcript JSONL  →  extract
   {last N user msgs, files touched, git state, open TODOs, recent commands}
   →  write handoff-latest.md  (deterministic, no model)            [VR-1,3,4-lite,8]
```

- **Mechanism:** pure shell (`jq` over `transcript_path` from hook stdin). No model turn needed.
- **Pros:** can't be skipped; zero token cost; trivial to reason about; proven (who96). Fully
  automatic. Survives crash (writes on every PreCompact).
- **Cons:** **mechanical, not semantic** — captures *what* was touched, not *why* / decisions /
  intent / next action (partially fails VR-2). Redaction is regex-only (weaker VR-4). Trigger is
  the ~95% boundary, never an earlier 90%.
- **Build cost:** ~1 day. **Fidelity:** ●○○.

## Option B — Live model-maintained state + PreCompact safety-net ⭐

```
UserPromptSubmit  →  inject lightweight directive: "if meaningful work happened since last
   update, rewrite .claude/handoff/handoff-latest.md (resume-minimum, ≤120 lines)"  [VR-2,3]
PostToolUse(Edit|Write)  →  mark dirty (cheap)
PreCompact  →  deterministic flush: if doc stale/missing, run Option-A dump as a HARD net  [VR-1]
SessionStart(compact|clear)  →  inject latest                                            [VR-5]
```

- **Mechanism:** the model keeps a running terse handoff current (reusing `handoff` skill
  content rules), so a high-fidelity doc **always already exists** before any compaction. The
  PreCompact deterministic dump is the unskippable floor if the model under-updated (closes the
  soft-imperative gap from memory: *soft nudge for fidelity, hard hook for guarantee*).
- **Pros:** high semantic fidelity (decisions, intent, next step); **always-ready** so no % timing
  needed; survives auto-compact, `/clear`, and crash; chain-links cleanly (VR-9). Best
  robustness-per-complexity.
- **Cons:** per-turn token tax (small, bounded by rewrite-mode cap); a directive on every prompt
  (can be made terse/conditional); two-part trust (soft update + hard net) is more moving parts.
- **Build cost:** ~2–3 days. **Fidelity:** ●●●.

## Option C — ~90% external watcher fires the `/handoff` skill

```
background watcher  →  poll transcript token estimate (ccusage-style)  →  at ~90%:
   inject high-priority instruction / queued prompt: "run /handoff NOW, then continue"
   →  model writes full rich handoff while context is still intact (pre-lossy)        [VR-2 max]
SessionStart  →  inject latest                                                        [VR-5]
```

- **Mechanism:** the only design that captures a **full model-written handoff before** the lossy
  summarization, at a chosen threshold. Literal match to "at 90%, auto-use the handoff skill."
- **Pros:** highest capture-moment fidelity (full `/handoff` skill, full context); proactive, not
  reactive; closest to the stated intent.
- **Cons:** **% is estimated**, not exact (no native usage signal — see research doc); injecting a
  prompt / forcing a skill-run from outside the turn loop is **not a first-class hook capability**
  today (needs an external supervisor process or a harness feature); **racy** against auto-compact;
  most code + most fragile. Highest maintenance.
- **Build cost:** ~4–6 days + ongoing fragility. **Fidelity:** ●●● (at capture) but reliability ●●○.

---

## Decision matrix

| Criterion (weight) | A | B ⭐ | C |
|---|---|---|---|
| Resume fidelity (VR-2) | ●○○ | ●●● | ●●● |
| Reliability / always-ready (VR-1,5,8) | ●●● | ●●● | ●●○ |
| Token/latency cost | ●●● (none) | ●●○ | ●●○ |
| Build simplicity | ●●● | ●●○ | ●○○ |
| Matches literal "90%" ask | ○○○ | ○○○ (boundary) | ●●● |
| Maintenance risk | low | low–med | high |

## Recommendation

**Option B**, with **Option A's deterministic dump as the built-in PreCompact safety net**
(B already specifies this). Rationale:

1. It delivers the actual goal — *resume with intent intact* — not just a file list.
2. "Always-ready" sidesteps the unsolvable precise-% trigger entirely (VR met without C's fragility).
3. The hard PreCompact net honors the memory lesson: don't trust a soft imperative for a
   guarantee — back it with a mechanism.
4. Reuses the `handoff` skill + Engram we already own; ~2–3 day build, low maintenance.

Consider **C later** only if you want proactive pre-lossy capture *and* accept maintaining an
external watcher; it layers cleanly on top of B (B's doc becomes the watcher's payload).

## If B is chosen — next-stage outline (not built this session)

- TDD units: (1) UserPromptSubmit directive + rewrite-cap logic; (2) PreCompact deterministic
  flush net (`jq` extractor); (3) SessionStart cwd/age-matched injector (`systemMessage`);
  (4) redaction + Engram chain-link persist.
- Test list = VR-1…VR-9 + TS-1…TS-8 verbatim from `01-requirements.md`.
- Tickets: 1 epic + ~4 stories (2 SP = 1 human-day). Tracker: TBD (Jira CAT? confirm).
