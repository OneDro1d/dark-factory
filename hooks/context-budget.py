#!/usr/bin/env python3
"""context-budget — force a handoff before the context window is spent (Stop hook).

WHY: native compaction summarises lossily and unpredictably. For a long autonomous
mission the durable state should be the Mission Map + tickets + notepad, not a
compaction summary. This gate makes the handoff happen while there is still enough
room left to write a good one.

How occupancy is measured: the transcript records a `usage` block per assistant
turn. Occupancy = input_tokens + cache_read_input_tokens + cache_creation_input_tokens
(cache reads still occupy the window). Verified against a live session at 221,936.

IMPORTANT -- a hook cannot clear the context window. This gate only forces the
handoff to be WRITTEN. The actual /clear is the operator's action, or the next
scheduled tick starting a fresh session.

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
  DF_CONTEXT_GATE=off        disable entirely
  DF_CONTEXT_WINDOW=<int>    override the derived window
  DF_CONTEXT_THRESHOLD=<pct> fire at this occupancy (default 85)
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


REASON = """Context budget gate: {pct:.1f}% of the window is occupied ({occupied} of {window} tokens).
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


def scan_transcript(transcript_path):
    """Return (last_usage, last_real_model, max_occupancy_seen).

    max_occupancy is the evidence that disproves a too-small assumed window: the
    session demonstrably HELD that many tokens at once, so the window is at least
    that big. It is tracked across the whole transcript, not just the last turn,
    because a compaction resets current occupancy but does not shrink the window.
    """
    usage = None
    model = None
    max_occ = 0
    with open(transcript_path, errors="replace") as fh:
        for line in fh:
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
    return usage, model, max_occ


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
        usage, model, max_occ = scan_transcript(transcript)
    except Exception:
        allow()
    if not usage:
        allow()

    occupied = occupancy(usage)
    save_learned(model, max_occ)

    try:
        window, source = resolve_window(model, max_occ)
        threshold = float(os.environ.get("DF_CONTEXT_THRESHOLD", "85"))
    except ValueError:
        allow()
    if window <= 0:
        allow()

    pct = 100.0 * occupied / window
    if pct < threshold:
        allow()

    # Fire at most once per session per 5-point band, so a long tail of turns
    # above the line does not block every single one. Bands are capped at 100 --
    # without the cap an over-100% reading (i.e. a wrong window) mints a fresh
    # band every ~5% and blocks almost every turn, which is what happened on
    # 2026-08-02 at 360/365/370.
    band = min(int(pct // 5) * 5, 100)
    session = str(event.get("session_id") or "nosession").replace("/", "_")
    marker = os.path.join(STATE_DIR, "%s.%d" % (session, band))
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        if os.path.exists(marker):
            allow()
        open(marker, "w").close()
    except OSError:
        allow()

    block(REASON.format(pct=pct, occupied=occupied, window=window, source=source))


if __name__ == "__main__":
    main()
