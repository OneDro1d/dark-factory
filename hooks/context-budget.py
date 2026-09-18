#!/usr/bin/env python3
"""context-budget — make the session CHECKPOINT before the window fills (Stop hook).

WHY: native compaction summarises lossily. For a long autonomous mission the durable
state should be the Mission Map + tickets + notepad, not a compaction summary. This gate
makes that state current while there is still room to write it well.

## Checkpoint, then CONTINUE (default since 2026-09-18) — not "hand off and /clear"

MEASURED on the HoP session, 2026-09-18: one auto-compaction at 12:00:17Z took the window
from 967,138 to 37,101 tokens in 75 s (`compact_boundary`, preTokens/postTokens), the session
carried on, and its Monitor tasks and CronCreate jobs survived. Meanwhile this gate had fired
at 85, 90 and 95% asking the operator for a restart that was never needed. The restart cycle
spends the operator's attention on MECHANISM, which the estate's prime directive forbids.

So the default now: refresh the handoff + NOTES.md, commit, save cross-session insight to
the memory store, and KEEP WORKING. When auto-compaction comes, agent-notepad's
SessionStart(source=compact) restore brings the handoff and NOTES back. The old
"write a handoff and ask for /clear" text is kept behind DF_CONTEXT_GATE_MODE=restart.

Fires ONCE per threshold crossing: once per compaction epoch (the count of
`compact_boundary` records in the transcript), in either mode. After a compaction occupancy
drops, and the next climb is a new crossing.

The default threshold scales with the window: fire when RESERVE tokens are left, where
RESERVE = min(80,000, 20% of the window). A 1M window auto-compacts at ~97% (967,138 measured
above), so 92% leaves ~50k tokens to write the checkpoint; a 200k window fires at 80%.
DF_CONTEXT_THRESHOLD=<pct> still overrides.

The memory store the checkpoint names is Engram; what it is and how to reach it is
documented in exactly one place: [Engram](../starter-kit/instance/AUTHENTICATION.md#engram)

How occupancy is measured: the transcript records a `usage` block per assistant
turn. Occupancy = input_tokens + cache_read_input_tokens + cache_creation_input_tokens
(cache reads still occupy the window). Verified against a live session at 221,936.

IMPORTANT -- a hook cannot clear or compact the context window. This gate only makes the
checkpoint get WRITTEN. Compaction is the harness's; a /clear (restart mode only) is the
operator's.

Contract: read hook JSON on stdin; print {} to let the turn end, or
{"decision":"block","reason":...} to force the agent to keep working with that
reason injected. EXIT 0 ALWAYS.

## Deriving the window (rewritten 2026-08-02)

Nothing in the Stop-hook payload or the transcript reports the context window --
there is no `contextWindow` field to read (verified by grep over a 125MB
transcript). So it must be inferred, and the v1 inference was a bare lookup table
that failed silently: a session on `claude-opus-4-8` (absent from the table) fell
through to the 200k default and the gate reported

    "370.4% of the window is occupied (740860 of 200000 tokens)"

A reading above 100% is arithmetically impossible. It is not a measurement, it is
a DISPROOF of the assumed window -- and v1 reported it as fact.

So the window now comes from three sources, strongest first:
  1. DF_CONTEXT_WINDOW              -- operator override, always wins.
  2. Observed floor                 -- the largest occupancy ever seen for this
                                       model (this transcript, plus a learned
                                       floor persisted across sessions), snapped
                                       up to the next known tier. Evidence, not
                                       a guess: a session that reached 998,200
                                       tokens PROVES the window is at least that.
  3. MODEL_WINDOWS lookup           -- fast path so a known model is right from
                                       turn 1, before occupancy has climbed.

Consequence: an unrecognised model can now cost at most ONE spurious block --
the first time it crosses the conservative default. After that the floor is
learned and persisted, and every later session with that model starts correct.

Config:
  DF_CONTEXT_GATE=off             disable entirely
  DF_CONTEXT_GATE_MODE=restart    the pre-2026-09-18 text: hand off, ask the operator to /clear
  DF_CONTEXT_WINDOW=<int>         override the derived window
  DF_CONTEXT_THRESHOLD=<pct>      fire at this occupancy (default: scaled to the window, above)
"""
import json
import math
import os
import sys

STATE_DIR = os.path.join(os.path.expanduser("~"), ".claude", "state", "context-budget")
LEARNED_PATH = os.path.join(STATE_DIR, "windows.json")

# Measured, not guessed:
#   claude-opus-5 / sonnet-5 / fable-5 -- `claude -p --output-format json`
#                                         -> modelUsage[*].contextWindow
#   claude-haiku-4-5                   -- same
#   claude-opus-4-8                    -- observed holding 998,200 tokens of occupancy
#                                         in a live transcript (2026-08-02), which is
#                                         only possible on a 1M window.
MODEL_WINDOWS = {
    "claude-opus-5": 1000000,
    "claude-opus-4-8": 1000000,
    "claude-sonnet-5": 1000000,
    "claude-fable-5": 1000000,
    "claude-haiku-4-5": 200000,
}

# Real context windows shipped to date. An observed floor is snapped UP to the
# smallest tier that can contain it; beyond the largest tier we round to 100k.
KNOWN_TIERS = (200000, 1000000)

# DECISION -- the unknown-model policy, deliberately conservative.
# Too small: one spurious handoff on a new model (noisy, cheap, self-healing via
#            the learned floor below).
# Too large: the gate never fires, the window blows, and native compaction eats
#            the mission state -- exactly what this gate exists to prevent.
# We take the noisy failure over the silent one. Raise this only if you would
# rather lose a mission than see a false handoff.
DEFAULT_WINDOW = 200000


def window_for(model):
    """Longest known prefix match, so dated ids (claude-haiku-4-5-20251001) resolve."""
    if not model:
        return DEFAULT_WINDOW
    best = None
    for known, size in MODEL_WINDOWS.items():
        if model.startswith(known) and (best is None or len(known) > len(best[0])):
            best = (known, size)
    return best[1] if best else DEFAULT_WINDOW


def snap_up(observed):
    """Smallest plausible window that can actually contain `observed` tokens."""
    for tier in KNOWN_TIERS:
        if observed <= tier:
            return tier
    return int(math.ceil(observed / 100000.0) * 100000)


def load_learned():
    """Per-model observed floors carried across sessions. Never fatal."""
    try:
        with open(LEARNED_PATH) as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def save_learned(model, observed):
    """Record that `model` was seen holding `observed` tokens. Never fatal."""
    if not model or observed <= 0:
        return
    try:
        data = load_learned()
        if observed <= int(data.get(model) or 0):
            return
        data[model] = observed
        os.makedirs(STATE_DIR, exist_ok=True)
        tmp = LEARNED_PATH + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(data, fh, indent=2, sort_keys=True)
        os.replace(tmp, LEARNED_PATH)
    except Exception:
        pass


REASON_CHECKPOINT = """Context checkpoint: {pct:.1f}% of the window is occupied ({occupied} of {window} tokens; threshold {threshold:.0f}%).
Window source: {source}.

Checkpoint, then CONTINUE. Auto-compaction will come; this makes it lossless where it matters.
Do these now, then carry on with the work you were doing:
  1. Refresh the handoff: Skill(handoff) -- where the work stands, the ONE next action, what is
     blocked and on whom, every artefact by path/URL. It is restored IN FULL after compaction.
  2. Update NOTES.md (goal, last decisions, next action at the TOP -- the top is what is restored)
     and commit both in the same commit. If a mission is running, update its map/ticket too.
  3. Save anything cross-session-valuable to the memory store (Engram) -- decisions, patterns,
     gotchas, and a session summary (kind=session) if the session did meaningful work -- routed
     by the domain of the content.
  4. Keep working. Do NOT stop, do NOT ask the operator to /clear or restart: after compaction the
     SessionStart(compact) restore re-injects the handoff and NOTES.md, and running Monitor
     tasks and CronCreate jobs survive compaction.

This fires once per crossing; it re-arms after the next compaction.
Old behaviour (hand off, then ask for /clear): DF_CONTEXT_GATE_MODE=restart. Off: DF_CONTEXT_GATE=off."""

REASON_RESTART = """Context budget gate: {pct:.1f}% of the window is occupied ({occupied} of {window} tokens).
Window source: {source}.

Do these now, before ending the turn:
  1. Call Skill(handoff) — write the handoff into the notepad's handoffs/ directory.
  2. Update the Mission Map: Decisions-so-far, any newly-surfaced or graduated tickets, current frontier.
  3. Post the state of the claimed ticket to the tracker so a cold session can resume from it.

Then tell the operator the handoff is written and the session is safe to /clear.
Resume order is: Mission Map -> claimed ticket -> handoff. Do NOT rely on native
compaction; it summarises lossily, and the map exists precisely so it is not needed.

Bypass (intentional): DF_CONTEXT_GATE=off, or raise DF_CONTEXT_THRESHOLD."""


def allow():
    print("{}")
    sys.exit(0)


def block(reason):
    print(json.dumps({"decision": "block", "reason": reason}))
    sys.exit(0)


def occupancy(usage):
    return (usage.get("input_tokens", 0)
            + usage.get("cache_read_input_tokens", 0)
            + usage.get("cache_creation_input_tokens", 0))


def default_threshold(window):
    """Fire when RESERVE tokens are left: RESERVE = min(80k, 20% of the window).

    1M -> 92% (auto-compaction measured at ~97%, so ~50k tokens to write the checkpoint);
    200k -> 80%. A fixed 85% left 150k unused on 1M and only ~15k of headroom on 200k.
    """
    reserve = min(80000.0, 0.20 * window)
    return 100.0 * (window - reserve) / window


def scan_transcript(transcript_path):
    """Return (last_usage, last_real_model, max_occupancy_seen, compactions).

    compactions = the number of `compact_boundary` system records: the compaction EPOCH. The
    gate fires once per epoch, so it re-arms after each compaction and never repeats inside one.

    max_occupancy is the evidence that disproves a too-small assumed window: the
    session demonstrably HELD that many tokens at once, so the window is at least
    that big. It is tracked across the whole transcript, not just the last turn,
    because a compaction resets current occupancy but does not shrink the window.
    """
    usage = None
    model = None
    max_occ = 0
    compactions = 0
    with open(transcript_path, errors="replace") as fh:
        for line in fh:
            if '"compact_boundary"' in line:
                try:
                    rec = json.loads(line)
                    if rec.get("type") == "system" and rec.get("subtype") == "compact_boundary":
                        compactions += 1
                except ValueError:
                    pass
                continue
            if '"usage"' not in line:
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if obj.get("type") != "assistant":
                continue
            msg = obj.get("message") or {}
            u = msg.get("usage")
            if not u:
                continue
            usage = u
            m = msg.get("model")
            # "<synthetic>" turns carry no real model -- keep the last real one
            if m and not m.startswith("<"):
                model = m
            occ = occupancy(u)
            if occ > max_occ:
                max_occ = occ
    return usage, model, max_occ, compactions


def _acw_value(v):
    """autoCompactWindow / CLAUDE_CODE_AUTO_COMPACT_WINDOW: a plain integer, clamped like the harness."""
    try:
        n = int(str(v).strip())
    except (TypeError, ValueError):
        return None
    return max(100000, min(1000000, n))


def auto_compact_window(cwd):
    """(tokens, source) of the configured AUTO-COMPACT window, or (None, "").

    ⛔ ADDED 2026-09-18. With `autoCompactWindow: 300000` a 1M-window session compacts at ~300k,
    so a threshold scaled to the MODEL window (92% of 1M = 920k) is never reached and the
    checkpoint never fires before compaction. The window the gate must scale to is the one
    compaction uses. Precedence is the harness's own: the env var, then managed, project-local,
    project and user settings (docs: settings-reference#autocompactwindow, env-vars).
    """
    env = os.environ.get("CLAUDE_CODE_AUTO_COMPACT_WINDOW")
    if env and _acw_value(env):
        return _acw_value(env), "CLAUDE_CODE_AUTO_COMPACT_WINDOW"
    candidates = ["/etc/claude-code/managed-settings.json"]
    d = os.path.abspath(cwd or os.getcwd())
    for _ in range(12):                       # project settings: walk up from the session's cwd
        candidates += [os.path.join(d, ".claude", "settings.local.json"),
                       os.path.join(d, ".claude", "settings.json")]
        if os.path.dirname(d) == d:
            break
        d = os.path.dirname(d)
    candidates.append(os.path.join(os.path.expanduser("~"), ".claude", "settings.json"))
    for p in candidates:
        try:
            with open(p) as fh:
                v = (json.load(fh) or {}).get("autoCompactWindow")
            if v is not None and _acw_value(v):
                return _acw_value(v), "autoCompactWindow in %s" % p
        except Exception:
            continue
    return None, ""


def resolve_window(model, max_occ):
    """(window, human-readable source). Evidence outranks the lookup table."""
    override = os.environ.get("DF_CONTEXT_WINDOW")
    if override:
        return int(override), "DF_CONTEXT_WINDOW override"

    table = window_for(model)
    table_src = ("model table (%s)" % model) if model in MODEL_WINDOWS or window_for(model) != DEFAULT_WINDOW \
        else "default — model %r not in the table" % (model,)

    floor = max(max_occ, int(load_learned().get(model) or 0))
    if floor > table:
        # The assumed window is disproven by observed occupancy. Trust the evidence.
        return snap_up(floor), "observed floor — %s held %d tokens, so the table value %d is wrong" % (
            model or "this session", floor, table)
    return table, table_src


def main():
    if os.environ.get("DF_CONTEXT_GATE", "on") == "off":
        allow()

    try:
        event = json.load(sys.stdin)
    except Exception:
        allow()

    # A Stop hook that already blocked is re-entered with this flag set.
    # Never block twice in a row -- that is an infinite loop, not a policy.
    if event.get("stop_hook_active"):
        allow()

    transcript = event.get("transcript_path") or ""
    if not transcript or not os.path.isfile(transcript):
        allow()

    try:
        usage, model, max_occ, compactions = scan_transcript(transcript)
    except Exception:
        allow()
    if not usage:
        allow()

    occupied = occupancy(usage)
    save_learned(model, max_occ)

    try:
        window, source = resolve_window(model, max_occ)
        if window <= 0:
            allow()
        # Compaction fires at the AUTO-COMPACT window when one is set below the model window, so
        # that is the window this gate must scale to (see auto_compact_window).
        if not os.environ.get("DF_CONTEXT_WINDOW"):
            acw, acw_src = auto_compact_window(event.get("cwd"))
            if acw and acw < window:
                source = "%s; compaction at %d (%s)" % (source, acw, acw_src)
                window = acw
        env_threshold = os.environ.get("DF_CONTEXT_THRESHOLD")
        threshold = float(env_threshold) if env_threshold else default_threshold(window)
    except ValueError:
        allow()

    pct = 100.0 * occupied / window
    if pct < threshold:
        allow()

    # ONCE PER CROSSING (since 2026-09-18). The old rule fired once per 5-point band, so a single
    # climb blocked at 85, 90 and 95% -- three interruptions for one event (measured on HoP). The
    # marker is now keyed on the COMPACTION EPOCH: one block per climb, re-armed by the next
    # compaction, which drops occupancy and starts a new climb. It also still caps the
    # over-100% case (a wrong window) that minted a fresh band every ~5% on 2026-08-02.
    session = str(event.get("session_id") or "nosession").replace("/", "_")
    marker = os.path.join(STATE_DIR, "%s.e%d" % (session, compactions))
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        if os.path.exists(marker):
            allow()
        open(marker, "w").close()
    except OSError:
        allow()

    if os.environ.get("DF_CONTEXT_GATE_MODE", "checkpoint") == "restart":
        block(REASON_RESTART.format(pct=pct, occupied=occupied, window=window, source=source))
    block(REASON_CHECKPOINT.format(pct=pct, occupied=occupied, window=window, source=source,
                                   threshold=threshold))


if __name__ == "__main__":
    main()
