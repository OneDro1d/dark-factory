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
#   2. no absolute http(s):// URL at all -- the hub is a placeholder here, never a host
#   3. no long opaque literal assigned to a token/secret/key/password name
#
# Rule 2 is stricter than "no PRIVATE host" on purpose. "Which hosts are safe to write down"
# is a judgement call made file by file, and a rule that needs judgement is a rule that gets
# argued with. "None, in this file" is checkable and needs no list to maintain.
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
  out="$(grep -nE 'https?://' "$f" || true)"
  [ -n "$out" ] && { printf 'R2 absolute-url: %s\n' "$out"; hits=1; }
  out="$(grep -nE '[A-Za-z_]*(TOKEN|SECRET|KEY|PASSWORD)[A-Za-z_]*[[:space:]]*=[[:space:]]*.?[A-Za-z0-9_-]{16,}' "$f" || true)"
  [ -n "$out" ] && { printf 'R3 literal-assignment: %s\n' "$out"; hits=1; }
  return "$hits"
}

printf '\n== the doc exists and says the things it must ==\n'

if [ -s "$DOC" ]; then ok "AUTHENTICATION.md is present and non-empty"
else bad "AUTHENTICATION.md is present and non-empty" "expected at $DOC"; exit 1; fi

# The token must be taught as an ENVIRONMENT REFERENCE. If this page ever stops saying so,
# the config template's placeholder loses the only place that explains it.
if grep -q 'DF_HUB_TOKEN' "$DOC"; then ok "names the token environment variable"
else bad "names the token environment variable" "DF_HUB_TOKEN not mentioned"; fi

if grep -q '__HUB_URL__' "$DOC"; then ok "names the hub URL placeholder"
else bad "names the hub URL placeholder" "__HUB_URL__ not mentioned"; fi

# The headless failure is the expensive one: the child boots cleanly and fails every write.
if grep -qi 'inherited from the environment' "$DOC"; then ok "states that hub auth is inherited from the environment"
else bad "states that hub auth is inherited from the environment"; fi

# unknown must not be collapsed into drift -- the preflight's three verdicts.
if grep -q 'unknown' "$DOC" && grep -q 'drift' "$DOC"; then ok "distinguishes unknown from drift"
else bad "distinguishes unknown from drift"; fi

printf '\n== the scanner passes the real file ==\n'

if OUT="$(scan "$DOC")"; then ok "no bearer literal, no absolute URL, no literal secret"
else bad "no bearer literal, no absolute URL, no literal secret" "$OUT"; fi

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

# R2: any concrete host, however innocuous-looking.
cp "$DOC" "$TMP/r2.md"; printf '\nSet the URL to https://hub.invalid/mcp and you are done.\n' >> "$TMP/r2.md"
if OUT="$(scan "$TMP/r2.md")"; then bad "R2 fires on an absolute URL" "scanner passed a planted host"
else case "$OUT" in R2*) ok "R2 fires on an absolute URL";; *) bad "R2 fires on an absolute URL" "wrong rule fired: $OUT";; esac; fi

# R3: a long opaque literal assigned to a credential-shaped name.
cp "$DOC" "$TMP/r3.md"; printf '\nexport DF_HUB_TOKEN=abcdefghijklmnopqrstuvwxyz012345\n' >> "$TMP/r3.md"
if OUT="$(scan "$TMP/r3.md")"; then bad "R3 fires on a literal assignment" "scanner passed a planted secret"
else case "$OUT" in R3*) ok "R3 fires on a literal assignment";; *) bad "R3 fires on a literal assignment" "wrong rule fired: $OUT";; esac; fi

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
