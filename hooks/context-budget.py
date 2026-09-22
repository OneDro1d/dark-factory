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

Wiring: Stop (the gate), and SessionStart with matcher startup|resume (records the auto-compact
window this session started with; see record_session_window). Without the SessionStart wiring
the gate reads settings at each Stop, which is wrong for a session started before they changed.

Config:
  DF_CONTEXT_GATE=off             disable entirely
  DF_CONTEXT_GATE_MODE=restart    the pre-2026-09-18 text: hand off, ask the operator to /clear
  DF_CONTEXT_WINDOW=<int>         override the derived window
  DF_CONTEXT_THRESHOLD=<pct>      fire at this occupancy (default: scaled to the window, above)
  DF_CONTEXT_GATE_MODE=autoclear  checkpoint, then /clear the session automatically (below)
  DF_CONTEXT_AUTOCLEAR_DRYRUN=1   autoclear mode: report the decision, send no keys

## autoclear mode (2026-09-20) -- why a /clear can be better than a compaction

A compaction costs a full re-read of the window to produce a summary that is lossy anyway.
A /clear costs nothing and discards it outright. For a mission whose durable state is the
notepad (handoff + NOTES.md + the map), the clear is the cheaper equivalent -- PROVIDED the
state is actually on disk first, and provided something mechanical survives the clear.

So this mode is strictly two-phase, and the second phase is gated on evidence, never on the
agent's word that it checkpointed:

  phase 1  threshold crossed  -> block with the checkpoint instructions (as ever), arm phase 2
  phase 2  a later clean Stop -> verify the preconditions, then send `/clear` to the tmux pane

⛔ THE INTERLOCK, and it is the whole reason this is safe to wire before the fleet has the
floor. `/clear` DISCARDS the context; unlike compaction there is no summary behind it. If the
SessionEnd floor writer is not wired in settings.json, nothing mechanical survives, and firing
here would destroy exactly the state this gate exists to protect. A gate that cannot verify
its own safety net does not fire -- it degrades to the checkpoint text and says why. Same for
a missing tmux pane (no actuator) and for a checkpoint that did not actually land on disk.

⚠️ Every precondition is checked at FIRE time, not at arm time. The floor can be unwired, the
pane can close and the notepad can go stale in between, and a precondition read once is a
claim about a world that has since moved on.
"""
import json
import math
import os
import subprocess
import sys
import time

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

REASON_AUTOCLEAR = """Context checkpoint: {pct:.1f}% of the window is occupied ({occupied} of {window} tokens; threshold {threshold:.0f}%).
Window source: {source}.

AUTOCLEAR IS ARMED. When you next end a turn cleanly, this session will be sent `/clear`.
A clear DISCARDS the window -- there is no summary behind it, so what is not on disk is gone.
Do these now, and do not leave them half-done:
  1. Refresh the handoff: Skill(handoff) -- where the work stands, the ONE next action, what is
     blocked and on whom, every artefact by path/URL. It is restored in full on a cold start.
  2. Update NOTES.md -- goal, last decisions, next action at the TOP, because the top is what a
     cold restore reaches. Commit both in the same commit.
  3. Save anything cross-session-valuable to the memory store (Engram), routed by the domain of
     the content.
  4. Then end your turn. Do not start new work you are not willing to lose.

The clear will NOT fire unless all of these hold at that moment, and it says so if it skips:
the SessionEnd floor writer is wired, a tmux pane is available, and NOTES.md is NEWER than this
message -- the checkpoint is verified on disk, never taken on your word.

Off: DF_CONTEXT_GATE_MODE=checkpoint. Rehearse without sending keys: DF_CONTEXT_AUTOCLEAR_DRYRUN=1."""

REASON_AUTOCLEAR_SKIPPED = """Autoclear did NOT fire: {reason}

The context window is still full, so the checkpoint still matters -- the handoff and NOTES.md
are what a cold session reads first. {again}"""


def _tmux_pane():
    """The actuator, or None. Hooks inherit TMUX/TMUX_PANE from the session that launched
    Claude, so the pane to type into is the one in the environment -- never one discovered by
    listing panes, which would pick a stranger's session on a shared box."""
    if not os.environ.get("TMUX"):
        return None
    return os.environ.get("TMUX_PANE") or None


def _floor_is_wired():
    """⛔ THE INTERLOCK. True only if a SessionEnd hook runs the notepad floor writer.

    Without it a /clear leaves nothing mechanical behind. The floor writer itself fails closed
    on any SessionEnd whose reason is not `clear`, so an entry that has lost its matcher still
    degrades safely -- which is why the matcher is not required here, only the wiring."""
    path = os.path.join(os.path.expanduser("~"), ".claude", "settings.json")
    try:
        with open(path) as fh:
            settings = json.load(fh)
    except Exception:
        return False
    for entry in (settings.get("hooks") or {}).get("SessionEnd") or []:
        for hook in entry.get("hooks") or []:
            if "pre-compact.sh" in (hook.get("command") or ""):
                return True
    return False


def _notepad_root(cwd):
    """Nearest ancestor holding NOTES.md -- the notepad root marker. The directory name is
    never the test; several notepads are named nothing like their objective."""
    path = os.path.abspath(cwd or os.getcwd())
    while True:
        if os.path.isfile(os.path.join(path, "NOTES.md")):
            return path
        parent = os.path.dirname(path)
        if parent == path:
            return None
        path = parent


def _checkpoint_is_fresh(cwd, armed_at):
    """Did the checkpoint this gate ASKED for actually land on disk after it asked?

    A self-report is not an assessment: the agent saying it wrote the handoff and the handoff
    having been written are different facts, and only one of them survives the clear. mtime is
    coarse but unforgeable by an agent that simply did not do the work."""
    root = _notepad_root(cwd)
    if not root:
        return False, "no notepad above cwd (no NOTES.md) -- nothing to clear into"
    notes = os.path.join(root, "NOTES.md")
    try:
        if os.path.getmtime(notes) > armed_at:
            return True, root
    except OSError:
        return False, "cannot stat NOTES.md"
    return False, "NOTES.md not touched since the gate armed -- checkpoint not on disk"


def _fire_clear(pane):
    """Type `/clear` into the pane, then Enter as a SEPARATE send-keys after a pause.

    One send-keys carrying both would race the TUI's slash-command autocomplete, where Enter
    selects a menu entry instead of submitting the line. The pause is the cheap fix; a wrong
    menu selection is not."""
    subprocess.run(["tmux", "send-keys", "-t", pane, "/clear"],
                   check=True, timeout=10,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.4)
    subprocess.run(["tmux", "send-keys", "-t", pane, "Enter"],
                   check=True, timeout=10,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# ---- RESUME AFTER THE CLEAR (2026-09-21) ----------------------------------------------------
#
# ⛔ WHY THIS EXISTS. autoclear was named "checkpoint, then CONTINUE" and shipped only the
# checkpoint half: `_fire_clear` typed `/clear` + Enter and stopped. The new session received the
# whole restore as CONTEXT -- and a SessionStart hook cannot start a turn, so it sat at an empty
# prompt until a human typed. Measured 2026-09-21: seven clears fired on this box, and the operator
# reported that none of the sessions resumed their mission afterwards.
#
# ⛔ WHY NOT A CRON (the operator's first proposal, rejected on the evidence). A tick fires on a
# clock, not on the clear: most ticks land on sessions that are busy or deliberately waiting on the
# operator, so it pushes them past the one natural pause and spends a turn per session per tick. It
# cannot tell which session owns which mission (`mission-tick` has exactly that defect, Engram
# `743565ea`). This file is the component that SENDS the clear, so it already knows the moment.
#
# ⛔ IT MUST BE DETACHED. `/clear` cannot execute until this Stop hook RETURNS, so the hook can never
# wait for the new session itself -- it would be waiting for something its own return unblocks.
#
# The helper types only when THREE things are proven, each read fresh:
#   1. THE CLEAR HAPPENED. `SessionEnd(clear)` rewrites the notepad's PRECOMPACT.md the moment the
#      clear executes (the interlock above already refuses to fire without that writer). An mtime
#      newer than the spawn is unforgeable; a timer is a guess.
#   2. THE PROMPT IS READY AND STABLE. The LAST `❯` line is empty, continuously, for SETTLE seconds.
#      This is nuntius-relay's production rule (pkg/tmuxsession inputLineEmpty), ported rather than
#      re-invented: a human's half-typed draft ("❯ HALF-TYPED") and the permission menu ("❯ 1. Yes",
#      which reuses the glyph) both have text after the glyph, so both fail it.
#   3. STILL READY AT THE LAST MOMENT. Re-checked immediately before delivering. Never trust a read
#      across the gap between deciding and doing.
# ⚠️ FAILS CLOSED. If any proof never arrives it types NOTHING and records why. Typing into a pane
# in an unknown state is worse than a session that waits for a human, which is today's behaviour.
# ⚠️ THE PANE IS THE ONE THIS HOOK INHERITED (TMUX_PANE), never one found by listing -- see
# `_tmux_pane`. On a shared box a listed pane can be a stranger's session.
# ⚠️ Residual race, accepted: nuntius-relay also injects into idle panes. It re-checks the input line
# right before injecting too, and a pasted-then-submitted prompt is non-empty then busy, so the
# window is the ~0.3 s between paste and Enter.
RESUME_TEXT = (
    "Autoclear just cleared this session's context to free the window. Resume the mission from the "
    "restored notepad above: read the newest handoff and NOTES.md, then take the ONE next action. "
    "Do not re-derive state, and do not stop to ask unless you reach a genuine hard stop.")
RESUME_BUFFER = "df-autoresume"


def _input_line_empty(pane_text):
    """nuntius-relay's rule: the LAST line starting with `❯` (after left-trim) has nothing after the
    glyph but whitespace or NBSP. No `❯` line at all is NOT empty -- it is not a prompt."""
    last = None
    for line in pane_text.split("\n"):
        line = line.rstrip("\r")
        if line.lstrip(" ").startswith("❯"):
            last = line
    if last is None:
        return False
    rest = last.lstrip(" ")[1:]
    return rest.strip(" \t ") == ""


def _capture(pane):
    try:
        return subprocess.run(["tmux", "capture-pane", "-p", "-t", pane], check=True, timeout=10,
                              capture_output=True, text=True).stdout
    except Exception:
        return None


def _deliver(pane, text):
    """Bracketed paste, then Enter as a separate keystroke -- nuntius-relay's delivery. A literal
    send-keys would submit at the first embedded newline."""
    subprocess.run(["tmux", "load-buffer", "-b", RESUME_BUFFER, "-"], input=text, text=True,
                   check=True, timeout=10, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["tmux", "paste-buffer", "-p", "-d", "-b", RESUME_BUFFER, "-t", pane],
                   check=True, timeout=10, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.3)
    subprocess.run(["tmux", "send-keys", "-t", pane, "Enter"], check=True, timeout=10,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def _resume_after_clear(pane, root, t0, record):
    """The detached helper's body. Returns the outcome string it also writes to `record`."""
    clear_wait = float(os.environ.get("DF_CONTEXT_RESUME_CLEAR_WAIT", "60"))
    ready_wait = float(os.environ.get("DF_CONTEXT_RESUME_READY_WAIT", "120"))
    settle = float(os.environ.get("DF_CONTEXT_RESUME_SETTLE", "3"))
    poll = 0.5
    floor = os.path.join(root, "PRECOMPACT.md")

    def done(outcome):
        try:
            with open(record, "w") as fh:
                fh.write("%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), outcome))
        except OSError:
            pass
        return outcome

    deadline = time.time() + clear_wait
    while True:
        try:
            if os.path.getmtime(floor) > t0:
                break
        except OSError:
            pass
        if time.time() >= deadline:
            return done("SKIPPED clear-not-observed: %s not rewritten within %ss -- typed nothing"
                        % (floor, clear_wait))
        time.sleep(poll)

    deadline = time.time() + ready_wait
    stable_since = None
    while True:
        text = _capture(pane)
        if text is not None and _input_line_empty(text):
            stable_since = stable_since or time.time()
            if time.time() - stable_since >= settle:
                break
        else:
            stable_since = None
        if time.time() >= deadline:
            return done("SKIPPED prompt-never-ready: no stable empty input line in %s within %ss "
                        "-- typed nothing" % (pane, ready_wait))
        time.sleep(poll)

    text = _capture(pane)
    if text is None or not _input_line_empty(text):
        return done("SKIPPED prompt-changed: the input line stopped being empty at the last "
                    "moment -- typed nothing")
    try:
        _deliver(pane, os.environ.get("DF_CONTEXT_AUTOCLEAR_RESUME_TEXT") or RESUME_TEXT)
    except Exception as exc:
        return done("FAILED delivery: %s" % exc)
    return done("RESUMED pane %s" % pane)


def _schedule_resume(pane, root, record):
    """Spawn the helper fully detached and return at once. Never raises: a resume that cannot be
    scheduled leaves today's behaviour (the session waits for a human), which is safe."""
    if os.environ.get("DF_CONTEXT_AUTOCLEAR_RESUME", "1") == "0":
        return
    try:
        subprocess.Popen([sys.executable, os.path.abspath(__file__), "--resume-after-clear",
                          pane, root, repr(time.time()), record],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, close_fds=True, start_new_session=True)
    except Exception:
        pass


def _autoclear(event, armed_at):
    """Phase 2. Returns None if the clear FIRED, else (reason, retryable).

    Every precondition is read here, at fire time. Read at arm time they would be claims about
    a world that has since moved on -- the pane can close and the wiring can change in between.

    `retryable` separates the two kinds of skip, because they deserve opposite treatment. An
    unmet ENVIRONMENT precondition (no pane, no wiring, no notepad) will not change inside this
    session, so re-reporting it every turn is pure noise: say it once and disarm. A missing
    CHECKPOINT is the agent's to fix and fixing it is the whole point, so that one is worth
    saying again."""
    pane = _tmux_pane()
    if not pane:
        return ("no tmux pane in this environment -- there is nothing to type into", False)
    if not _floor_is_wired():
        return ("the SessionEnd floor writer is NOT wired in ~/.claude/settings.json, so a "
                "clear would leave nothing mechanical behind -- refusing to fire", False)
    ok, detail = _checkpoint_is_fresh(event.get("cwd") or "", armed_at)
    if not ok:
        retryable = detail.startswith("NOTES.md not touched")
        return (detail, retryable)
    if os.environ.get("DF_CONTEXT_AUTOCLEAR_DRYRUN"):
        return ("DRY RUN -- would have sent /clear to tmux pane %s (notepad %s)"
                % (pane, detail), False)
    try:
        _fire_clear(pane)
    except Exception as exc:
        return ("tmux send-keys failed (%s) -- the session is unchanged" % exc, False)
    return None


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
    """Return (last_usage, last_real_model, max_occupancy_seen, compactions, epoch_max).

    epoch_max = the largest occupancy since the last compaction. A session that held more than an
    auto-compact window without compacting was not running under that window.

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
    epoch_max = 0
    compactions = 0
    with open(transcript_path, errors="replace") as fh:
        for line in fh:
            if '"compact_boundary"' in line:
                try:
                    rec = json.loads(line)
                    if rec.get("type") == "system" and rec.get("subtype") == "compact_boundary":
                        compactions += 1
                        epoch_max = 0
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
            if occ > epoch_max:
                epoch_max = occ
    return usage, model, max_occ, compactions, epoch_max


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


def _session_key(event):
    return str(event.get("session_id") or "nosession").replace("/", "_")


def _record_path(event):
    return os.path.join(STATE_DIR, "%s.window.json" % _session_key(event))


def record_session_window(event):
    """SessionStart: record the auto-compact window THIS session runs under. Never blocks.

    ⛔ ADDED 2026-09-18. The harness reads autoCompactWindow once, when the process starts; a
    settings change reaches only sessions started after it (measured: a session started before the
    change still compacted at 967k). Read from disk at each Stop, the new value was applied to old
    sessions too, and one at ~350k was told "116% of the window". So the value is taken at the two
    moments the harness itself reads settings -- a new process (startup) and a resumed one (resume)
    -- and kept for the session. compact and clear run in the same process with the same settings,
    so they keep the record that is already there and never write one.
    """
    if event.get("source") not in ("startup", "resume"):
        return
    try:
        acw, src = auto_compact_window(event.get("cwd"))
        os.makedirs(STATE_DIR, exist_ok=True)
        path = _record_path(event)
        with open(path + ".tmp", "w") as fh:
            json.dump({"autoCompactWindow": acw, "source": src or "none configured",
                       "event": event.get("source")}, fh)
        os.replace(path + ".tmp", path)
    except Exception:
        pass


def session_auto_compact_window(event):
    """(tokens or None, source) for this session: the SessionStart record first, else settings.

    A record of None means no auto-compact window was configured when the session started, so the
    model window applies, whatever the settings say now. No record (the session started before this
    code was installed) falls back to reading settings now, which is right unless they changed.
    """
    try:
        with open(_record_path(event)) as fh:
            rec = json.load(fh)
        acw = rec.get("autoCompactWindow")
        return (_acw_value(acw) if acw is not None else None), \
            "recorded at session %s: %s" % (rec.get("event", "start"), rec.get("source", "?"))
    except Exception:
        return auto_compact_window(event.get("cwd"))


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

    if event.get("hook_event_name") == "SessionStart":
        record_session_window(event)
        allow()

    # A Stop hook that already blocked is re-entered with this flag set.
    # Never block twice in a row -- that is an infinite loop, not a policy.
    #
    # ⛔ BUT IN AUTOCLEAR MODE THE RE-ENTRY STOP IS EXACTLY WHEN PHASE 2 MUST RUN, and returning here
    # was the bug the operator reported as "sessions get ready to clear, but something stops before
    # clearing". Phase 1 BLOCKS, so the stop that ends the checkpoint turn is always a re-entry.
    # With the old early return, phase 2 was never evaluated there; it waited for the NEXT clean
    # stop, and an autonomous session that has just checkpointed has no next turn — it goes idle
    # saying it is "ready for autoclear" and sits until something external prompts it. MEASURED
    # 2026-09-22 on a real session: armed, checkpoint on disk, then idle for 240 s, no clear.
    # (The 5 min – 2 h arm-to-clear delays measured earlier were the wait for that outside prompt,
    # which I had first called "working as designed".)
    # So re-entry is carried forward, and only the BLOCKING paths are closed to it: phase 2 may FIRE
    # (it types /clear and ALLOWS — no block, so no loop), but may not arm, and may not refuse with
    # a block. Every other mode keeps the old early return untouched.
    reentry = bool(event.get("stop_hook_active"))
    if reentry and os.environ.get("DF_CONTEXT_GATE_MODE", "checkpoint") != "autoclear":
        allow()

    transcript = event.get("transcript_path") or ""
    if not transcript or not os.path.isfile(transcript):
        allow()

    try:
        usage, model, max_occ, compactions, epoch_max = scan_transcript(transcript)
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
        # that is the window this gate must scale to (see auto_compact_window) -- the value THIS
        # session started with (see record_session_window). A session that already held more than
        # that window since its last compaction is not running under it, so the value is disproven
        # and ignored: the same evidence rule as the observed floor.
        if not os.environ.get("DF_CONTEXT_WINDOW"):
            acw, acw_src = session_auto_compact_window(event)
            if acw and epoch_max > acw:
                acw = None
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
    mode = os.environ.get("DF_CONTEXT_GATE_MODE", "checkpoint")
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        armed = os.path.exists(marker)
        if armed and mode != "autoclear":
            allow()
        if not armed:
            if reentry:
                allow()   # arming BLOCKS, and a re-entry stop may never block
            open(marker, "w").close()
    except OSError:
        allow()

    # PHASE 2 (autoclear only). The marker already exists, so the checkpoint was asked for on an
    # earlier turn and the agent has had a full turn to do it. Now verify and fire.
    if armed:
        fired = marker + ".cleared"
        disarmed = marker + ".disarmed"
        try:
            if os.path.exists(fired) or os.path.exists(disarmed):
                allow()
            armed_at = os.path.getmtime(marker)
        except OSError:
            allow()
        outcome = _autoclear(event, armed_at)
        if outcome is None:
            try:
                open(fired, "w").close()
            except OSError:
                pass
            # Checkpoint, then CONTINUE: without this the new session sits at an empty prompt.
            # `_autoclear` just proved both the pane and the notepad exist, so neither is None.
            root = _notepad_root(event.get("cwd") or "")
            pane = _tmux_pane()
            if root and pane:
                _schedule_resume(pane, root, marker + ".resumed")
            # The keys are already in the pane; the clear happens as this turn ends. Blocking
            # here would start a turn that is about to be discarded.
            allow()
        if reentry:
            # A refusal is reported by BLOCKING, which re-entry may not do. Change nothing — no
            # disarm either — so the next clean stop retries and, if it still refuses, says why.
            allow()
        reason, retryable = outcome
        try:
            if not retryable:
                open(disarmed, "w").close()
        except OSError:
            pass
        block(REASON_AUTOCLEAR_SKIPPED.format(reason=reason,
                                              again="I will try again after your next turn."
                                              if retryable else
                                              "Autoclear is now disarmed for this session."))

    if mode == "restart":
        block(REASON_RESTART.format(pct=pct, occupied=occupied, window=window, source=source))
    if mode == "autoclear":
        block(REASON_AUTOCLEAR.format(pct=pct, occupied=occupied, window=window, source=source,
                                      threshold=threshold))
    block(REASON_CHECKPOINT.format(pct=pct, occupied=occupied, window=window, source=source,
                                   threshold=threshold))


if __name__ == "__main__":
    # The detached resume helper re-enters this same file (one home for the rule it applies).
    if len(sys.argv) == 6 and sys.argv[1] == "--resume-after-clear":
        _resume_after_clear(sys.argv[2], sys.argv[3], float(sys.argv[4]), sys.argv[5])
        sys.exit(0)
    main()
