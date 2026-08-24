#!/usr/bin/env bash
# test-authentication-doc.sh — AUTHENTICATION.md is the one page in this kit whose SUBJECT
# is credentials, which makes it the one page where a helpful example becomes a leak.
#
# Run:  bash starter-kit/instance/tests/test-authentication-doc.sh
# Exit: 0 all pass · 1 at least one failed. Prints a literal count, because a suite that
# reports "ok" without saying how many assertions ran cannot be told from one that ran none.
#
# WHY THIS EXISTS, given that a publish gate already exists. The landmark gate only tells
# the truth when a maintainer runs it locally with the real, gitignored config; CI runs it
# with the example config, whose patterns match fictional hosts. So the check that would
# catch a real hub URL pasted into this file is precisely the check that does not run on a
# pull request. These three rules need no private config and hold anywhere:
#
#   1. no `Bearer` followed by anything but an environment reference
#   2. no absolute http(s):// URL except the three documented PUBLIC product endpoints
#   3. no long opaque literal assigned to a token/secret/key/password name
#
# Rule 2 USED TO BE "no absolute URL at all", on the reasoning that "which hosts are safe to
# write down" is a judgement call made file by file, and a rule needing judgement is a rule
# that gets argued with. That held while the kit had no default hub. It stopped holding when
# the kit gained one: a page that may not name the endpoint it now ships cannot explain it.
#
# The property was re-expressed rather than dropped, because the thing R2 protected -- no
# PRIVATE or unvetted host reaches the one page whose subject is credentials -- is unchanged.
# What changed is the mechanism: a three-entry allowlist instead of zero. The allowlist is
# closed and exact, so a lookalike (docs.onedroid.ai.example.com) and a plain-http form both
# still fire. Adding a fourth host is a deliberate edit here, which is the point.
#
# Two PROSE rules were added for the same reason, and they are negative on purpose -- they
# catch a claim being re-inverted, not a word going missing:
#
#   P1  no "usually ends in /mcp" -- that guess walks a token client onto the OAuth path
#   P2  no read-only TOKEN -- read-only is a property of the role, never of the token
#
# The positive requirements below are plain assertions instead: for those, the failure mode
# is text being deleted, and the assertion IS the canary.
#
# Every rule is exercised in BOTH directions against a canary copy in a temp directory: a
# check never seen to fail on the input it exists to catch is not known to work, and this
# gate family has reported CLEAN on a planted canary before. The canaries are written to
# $TMPDIR and never to the tracked tree, so a credential-shaped string never reaches a diff.
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$SELF/.." && pwd)"
DOC="$KIT/AUTHENTICATION.md"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- the three rules, as one scanner so both directions test the SAME code ---------------
# Prints each violation; returns 1 if any fired.
scan() {
  local f="$1" hits=0 out
  out="$(grep -nE 'Bearer[[:space:]]+[^$[:space:]]' "$f" || true)"
  [ -n "$out" ] && { printf 'R1 bearer-literal: %s\n' "$out"; hits=1; }
  # Exact-match allowlist. grep -o captures the whole host, so a lookalike suffix
  # (docs.onedroid.ai.example.com) is captured whole and fails -xE, and http:// fails too.
  out="$(grep -oE 'https?://[A-Za-z0-9._-]+' "$f" \
         | grep -vxE 'https://(synapse|engram|docs)\.onedroid\.ai' || true)"
  [ -n "$out" ] && { printf 'R2 absolute-url: %s\n' "$out"; hits=1; }
  out="$(grep -nE '[A-Za-z_]*(TOKEN|SECRET|KEY|PASSWORD)[A-Za-z_]*[[:space:]]*=[[:space:]]*.?[A-Za-z0-9_-]{16,}' "$f" || true)"
  [ -n "$out" ] && { printf 'R3 literal-assignment: %s\n' "$out"; hits=1; }
  return "$hits"
}

# --- the two prose rules, likewise one function so both directions test the SAME code -----
prose() {
  local f="$1" hits=0 out
  out="$(grep -niE 'usually end(s|ing) in' "$f" || true)"
  [ -n "$out" ] && { printf 'P1 old-mcp-guess: %s\n' "$out"; hits=1; }
  out="$(grep -niE 'read-?only (personal access )?token|token (scoped |as )?read-?only|scope (the |a |your )?token read-?only' "$f" || true)"
  [ -n "$out" ] && { printf 'P2 readonly-token: %s\n' "$out"; hits=1; }
  return "$hits"
}

printf '\n== the doc exists and says the things it must ==\n'

if [ -s "$DOC" ]; then ok "AUTHENTICATION.md is present and non-empty"
else bad "AUTHENTICATION.md is present and non-empty" "expected at $DOC"; exit 1; fi

# The token must be taught as an ENVIRONMENT REFERENCE. If this page ever stops saying so,
# the config template's placeholder loses the only place that explains it.
if grep -q 'DF_HUB_TOKEN' "$DOC"; then ok "names the token environment variable"
else bad "names the token environment variable" "DF_HUB_TOKEN not mentioned"; fi

# WAS: "names the hub URL placeholder" -- asserted the doc mentions __HUB_URL__, back when
# the template shipped one. The template now ships a resolvable public default, so that
# assertion is false BY DESIGN and deleting it would drop the property underneath: a reader
# must be able to find out which endpoint the kit points at, why that exact path, and how to
# point it somewhere else. Re-expressed as five checks that are together stronger.

if grep -q 'synapse.onedroid.ai/agent/mcp' "$DOC"; then ok "names the documented default hub endpoint"
else bad "names the documented default hub endpoint" "the kit ships this URL; the page must say so"; fi

# The mission's correctness item, held open rather than fixed once: a token uses /agent/mcp
# with no slug. The page has to explain the failure, not just avoid it -- a reader who has
# already made the mistake arrives searching for this string.
if grep -q 'ERR_SCOPE_UNAVAILABLE' "$DOC"; then ok "names the failure a slugged token URL returns"
else bad "names the failure a slugged token URL returns" "ERR_SCOPE_UNAVAILABLE not mentioned"; fi

# A default that is only a default in the author's head is a hard-code to the reader.
if grep -qi 'bring your own' "$DOC"; then ok "documents the bring-your-own-hub path"
else bad "documents the bring-your-own-hub path"; fi

# Cite, do not restate: two copies of the token model drift and the reader trusts neither.
if grep -q 'docs.onedroid.ai' "$DOC"; then ok "links the vendor docs rather than restating them"
else bad "links the vendor docs rather than restating them"; fi

# Narrowing is a ROLE and tool-toggle concern. If this sentence goes, P2 alone would let the
# page fall silent on the question instead of answering it wrongly -- which is also a failure.
if grep -qi 'tool toggles' "$DOC"; then ok "points narrowing at role and tool toggles"
else bad "points narrowing at role and tool toggles"; fi

# The memory upstream is the one connector the method itself leans on, and ~11 other files in
# this repo name it in passing. This page is where those references resolve to a meaning.
if grep -q 'Engram' "$DOC" && grep -qi 'versioned agent memory' "$DOC"; then ok "says what the memory upstream is"
else bad "says what the memory upstream is" "Engram is named across the repo; define it once, here"; fi

# The headless failure is the expensive one: the child boots cleanly and fails every write.
if grep -qi 'inherited from the environment' "$DOC"; then ok "states that hub auth is inherited from the environment"
else bad "states that hub auth is inherited from the environment"; fi

# unknown must not be collapsed into drift -- the preflight's three verdicts.
if grep -q 'unknown' "$DOC" && grep -q 'drift' "$DOC"; then ok "distinguishes unknown from drift"
else bad "distinguishes unknown from drift"; fi

printf '\n== the scanner passes the real file ==\n'

if OUT="$(scan "$DOC")"; then ok "no bearer literal, no unvetted host, no literal secret"
else bad "no bearer literal, no unvetted host, no literal secret" "$OUT"; fi

if OUT="$(prose "$DOC")"; then ok "no /mcp guess, no read-only token"
else bad "no /mcp guess, no read-only token" "$OUT"; fi

printf '\n== and fails a canary for each rule (the direction that matters) ==\n'

# R1: an Authorization header with a value instead of an environment reference.
cp "$DOC" "$TMP/r1.md"; printf '\n    "Authorization": "Bearer sk-notarealtoken-000"\n' >> "$TMP/r1.md"
if OUT="$(scan "$TMP/r1.md")"; then bad "R1 fires on a bearer literal" "scanner passed a planted header"
else case "$OUT" in R1*) ok "R1 fires on a bearer literal";; *) bad "R1 fires on a bearer literal" "wrong rule fired: $OUT";; esac; fi

# The same header written as the template writes it must still PASS -- otherwise the rule
# forbids the correct form, and a rule that is wrong on correct input teaches people to
# ignore it. This is the narrowing check: R1 must be off for ${...}, not off entirely.
cp "$DOC" "$TMP/r1ok.md"; printf '\n    "Authorization": "Bearer ${DF_HUB_TOKEN}"\n' >> "$TMP/r1ok.md"
if scan "$TMP/r1ok.md" >/dev/null; then ok "R1 stays quiet on the environment-reference form"
else bad "R1 stays quiet on the environment-reference form" "$(scan "$TMP/r1ok.md")"; fi

# R2: any host that is not on the allowlist, however innocuous-looking.
cp "$DOC" "$TMP/r2.md"; printf '\nSet the URL to https://hub.invalid/mcp and you are done.\n' >> "$TMP/r2.md"
if OUT="$(scan "$TMP/r2.md")"; then bad "R2 fires on an off-allowlist host" "scanner passed a planted host"
else case "$OUT" in R2*) ok "R2 fires on an off-allowlist host";; *) bad "R2 fires on an off-allowlist host" "wrong rule fired: $OUT";; esac; fi

# The narrowing check: R2 must be off for the three documented endpoints, not off entirely.
# A rule that is wrong on correct input teaches people to ignore it.
cp "$DOC" "$TMP/r2ok.md"; printf '\nSee https://docs.onedroid.ai and https://engram.onedroid.ai for more.\n' >> "$TMP/r2ok.md"
if scan "$TMP/r2ok.md" >/dev/null; then ok "R2 stays quiet on the documented public endpoints"
else bad "R2 stays quiet on the documented public endpoints" "$(scan "$TMP/r2ok.md")"; fi

# An allowlist that matches by substring is not an allowlist. This is the case a hand-rolled
# `grep -v docs.onedroid.ai` would wave through, and it is the one an attacker would pick.
cp "$DOC" "$TMP/r2look.md"; printf '\nGo to https://docs.onedroid.ai.example.net/tokens instead.\n' >> "$TMP/r2look.md"
if OUT="$(scan "$TMP/r2look.md")"; then bad "R2 fires on a lookalike host" "scanner passed a suffixed lookalike"
else case "$OUT" in R2*) ok "R2 fires on a lookalike host";; *) bad "R2 fires on a lookalike host" "wrong rule fired: $OUT";; esac; fi

# R3: a long opaque literal assigned to a credential-shaped name.
cp "$DOC" "$TMP/r3.md"; printf '\nexport DF_HUB_TOKEN=abcdefghijklmnopqrstuvwxyz012345\n' >> "$TMP/r3.md"
if OUT="$(scan "$TMP/r3.md")"; then bad "R3 fires on a literal assignment" "scanner passed a planted secret"
else case "$OUT" in R3*) ok "R3 fires on a literal assignment";; *) bad "R3 fires on a literal assignment" "wrong rule fired: $OUT";; esac; fi

# P1: the guess this mission exists to remove. It is not enough to have deleted it once --
# it is the sentence anyone would write from intuition, so it needs a standing guard.
cp "$DOC" "$TMP/p1.md"; printf '\nThe endpoint usually ends in `/mcp`.\n' >> "$TMP/p1.md"
if OUT="$(prose "$TMP/p1.md")"; then bad "P1 fires on the /mcp guess" "scanner passed the old guess"
else case "$OUT" in P1*) ok "P1 fires on the /mcp guess";; *) bad "P1 fires on the /mcp guess" "wrong rule fired: $OUT";; esac; fi

# P2: read-only is a property of the ROLE the token inherits, never of the token. The vendor
# docs have no read-only token concept at all, so writing one would be inventing behaviour.
cp "$DOC" "$TMP/p2.md"; printf '\nMint a read-only token for diagnosis work.\n' >> "$TMP/p2.md"
if OUT="$(prose "$TMP/p2.md")"; then bad "P2 fires on a read-only token" "scanner passed an invented control"
else case "$OUT" in P2*) ok "P2 fires on a read-only token";; *) bad "P2 fires on a read-only token" "wrong rule fired: $OUT";; esac; fi

# ...and stays quiet on the correct form, which the page must be free to say.
cp "$DOC" "$TMP/p2ok.md"; printf '\nA read-only role, not a read-only credential, is the control.\n' >> "$TMP/p2ok.md"
if prose "$TMP/p2ok.md" >/dev/null; then ok "P2 stays quiet on read-only as a role"
else bad "P2 stays quiet on read-only as a role" "$(prose "$TMP/p2ok.md")"; fi

printf '\n== the doc is reachable from the pages that send people to it ==\n'

# Plain-text references were correct only while the file did not exist. Now that it does,
# a plain reference is a dead end the link checker cannot see -- it only walks links.
for src in README.md START-HERE.md; do
  if grep -q '(AUTHENTICATION\.md)' "$KIT/$src"; then ok "$src links to AUTHENTICATION.md"
  else bad "$src links to AUTHENTICATION.md" "still a plain-text reference"; fi
done

# install.sh's reference stays PLAIN: it is printed to a terminal, where markdown is noise.
if grep -q 'Read AUTHENTICATION.md' "$KIT/install.sh"; then ok "install.sh still points the reader at it"
else bad "install.sh still points the reader at it"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
