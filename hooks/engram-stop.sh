#!/bin/bash
# Engram is the memory store this message names. What it is and how to reach it
# is documented in exactly one place:
# [Engram](../starter-kit/instance/AUTHENTICATION.md#engram)
# engram-stop.sh — TIER 1. Promoted 2026-09-02 from two instance repos that each kept their own copy.
#
# WHY THIS IS GENERIC, and it is measured rather than argued: `<publisher>/<instance-repo>` and
# `<second-account>/<instance-repo>` both carried this file as `local:` content, on different
# estates, with different hubs and different git identities — and the two copies were
# BYTE-IDENTICAL. Two independent estates converging on the same bytes is what
# "generic" looks like from the outside.
#
# ⚠️ THE ONE BINDING IS THE TEXT, NOT THE MECHANISM. The mechanism — emit a systemMessage on
# this event — is domain-neutral. The store and collection named in the message body are an
# estate's choice. Both estates in the reference fleet name Engram, so the default stays; a
# consumer that uses a different store edits the message in its own layer rather than
# expecting configuration that no one has needed yet.
#
# ⚠️ Never add an endpoint, a token or a hub name to this file. It lives in a PUBLIC repo.
# The hooks promoted here were checked for all three before the move.
#
# ⛔ NOW A NO-OP, DELIBERATELY (2026-09-18). It used to emit a systemMessage after EVERY reply:
# "If this session did meaningful work, write a session summary to Engram". MEASURED that day on
# Claude Code 2.1.276 (a Stop hook emitting one output shape per run): a Stop `systemMessage` is
# shown to the operator and NEVER reaches the model. So the nudge could not do its job, and it put
# a line on the operator's screen after every single reply. Making it reach the model
# (additionalContext) would force a whole extra turn per reply, which is the cost this change removes.
# The nudge now lives where the model CAN act on it without a forced turn: the context-budget
# checkpoint (hooks/context-budget.py, REASON_CHECKPOINT step 3), which fires once per climb.
#
# ⚠️ The FILE stays, emitting {}, because instance lockfiles declare and wire it. Deleting it would
# turn a harmless no-op into a missing-hook drift on every machine. Undeclare it first.
cat >/dev/null 2>&1 || true   # drain the event
printf '{}\n'
