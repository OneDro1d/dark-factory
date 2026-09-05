#!/bin/bash
# Engram is the memory store this message names. What it is and how to reach it
# is documented in exactly one place:
# [Engram](../starter-kit/instance/AUTHENTICATION.md#engram)
# engram-pre-compact.sh — TIER 1. Promoted 2026-09-02 from two instance repos that each kept their own copy.
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
# PreCompact hook: nudge to save cross-session insight before context compression.
# Trusts that Claude learned routing from start_here earlier this session.

cat <<'EOF'
{"systemMessage":"Context is compressing. Save anything cross-session-valuable to Engram now — decisions, patterns, behaviors, session summary. Use the routing you learned from start_here earlier."}
EOF
