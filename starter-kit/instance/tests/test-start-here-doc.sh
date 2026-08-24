#!/usr/bin/env bash
# test-start-here-doc.sh — START-HERE.md is the page a stranger reads first, and after
# 2026-08-24 it is also the page that walks them from nothing to a hub they can actually
# reach. That makes it the second page in this kit where a helpful example becomes a leak,
# and the first page where a wrong claim about a product is unrecoverable: the reader has
# no way to check it and no reason to doubt it.
#
# Run:  bash starter-kit/instance/tests/test-start-here-doc.sh
# Exit: 0 all pass · 1 at least one failed. Prints a literal count, because a suite that
# reports "ok" without saying how many assertions ran cannot be told from one that ran none.
#
# WHY IT IS SEPARATE FROM test-authentication-doc.sh, which scans the same three classes.
# Two different pages, two different allowlists (this one legitimately names the upstream
# GitHub repo; that one legitimately names three product hosts and nothing else), and that
# suite belongs to a change already in review. Sharing one scanner across both would mean
# one allowlist wide enough for both pages, which is a weaker rule on each of them.
#
# THE RULES, and why each is set where it is.
#
#   R1  no `Bearer` credential of any kind -- set at ZERO, not at "must be a variable".
#       AUTHENTICATION.md is the page that discusses credentials; this page links it. A
#       page with no reason to show a token is a page where the safe level needs no
#       judgement, and a rule that needs no judgement is a rule nobody argues with. If a
#       future edit genuinely needs one, changing this line is the deliberate act.
#   R2  no absolute http(s):// URL outside a closed allowlist -- the upstream repo, the
#       three PUBLIC product endpoints, and the docs site. Matched EXACTLY at the host, so
#       a lookalike suffix (docs.onedroid.ai.example.net) and a plain-http form both fire.
#   R3  no long opaque literal assigned to a token/secret/key/password name.
#
#   P1  no "/mcp" GUESS and no OAuth `/hub/<slug>/` form. This is the sentence anyone
#       writes from intuition, and it walks a token client onto the path that answers
#       ERR_SCOPE_UNAVAILABLE. It was already fixed once, in AUTHENTICATION.md; a rule that
#       only guards the page where the mistake was found does not stop it reappearing on
#       the page that sends people there.
#   P2  no claim that a hub is REQUIRED. The method runs with no hub at all, and the kit's
#       own hard stop is that the bring-your-own path keeps working. "You need a hub" is
#       the shape that sentence takes when someone tightens the prose.
#
# The positive requirements below are plain assertions instead: for those the failure mode
# is text being DELETED, and the assertion is itself the canary.
#
# Every rule is exercised in BOTH directions against a copy in a temp directory. A check
# never seen to fail on the input it exists to catch is not known to work -- this gate
# family has reported CLEAN on a planted canary before, and a self-test built only from a
# config's own canaries can only ever prove the patterns that config already has. Canaries
# are written to $TMPDIR and never to the tracked tree, so a credential-shaped string never
# reaches a diff.
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$SELF/.." && pwd)"
DOC="$KIT/START-HERE.md"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -s "$DOC" ] || { printf 'START-HERE.md missing at %s\n' "$DOC" >&2; exit 1; }

# --- R1/R2/R3 as ONE scanner, so both directions exercise the same code ------------------
scan() {
  local f="$1" hits=0 out

  out="$(grep -nE 'Bearer' "$f" || true)"
  [ -n "$out" ] && { printf 'R1 credential: %s\n' "$out"; hits=1; }

  # Every absolute URL, minus the closed allowlist. Anchored at the scheme+host so a
  # lookalike suffix is NOT a member of the list.
  out="$(grep -oE 'https?://[A-Za-z0-9._-]+' "$f" \
        | grep -vxE 'https://github\.com|https://synapse\.onedroid\.ai|https://engram\.onedroid\.ai|https://docs\.onedroid\.ai' \
        || true)"
  [ -n "$out" ] && { printf 'R2 host: %s\n' "$(printf '%s' "$out" | tr '\n' ' ')"; hits=1; }

  out="$(grep -nEi '(token|secret|key|password)[^=:]{0,12}[=:][[:space:]]*['"'"'"]?[A-Za-z0-9_-]{24,}' "$f" || true)"
  [ -n "$out" ] && { printf 'R3 literal: %s\n' "$out"; hits=1; }

  return $hits
}

# --- P1/P2, the prose rules -------------------------------------------------------------
prose() {
  local f="$1" hits=0 out

  out="$(grep -nEi 'usually (ending|ends) in .?/mcp|/hub/<|/hub/[a-z0-9-]+/mcp' "$f" || true)"
  [ -n "$out" ] && { printf 'P1 endpoint guess: %s\n' "$out"; hits=1; }

  out="$(grep -nEi 'you( will| must)? need (an?|your own)[^.]{0,24}hub|a hub is required|requires a hub|hub is a prerequisite' "$f" || true)"
  [ -n "$out" ] && { printf 'P2 hub required: %s\n' "$out"; hits=1; }

  return $hits
}

printf '\n== the page itself is clean ==\n'

if OUT="$(scan "$DOC")"; then ok "no credential, unvetted host, or opaque literal"
else bad "no credential, unvetted host, or opaque literal" "$OUT"; fi

if OUT="$(prose "$DOC")"; then ok "no endpoint guess and no hub-is-required claim"
else bad "no endpoint guess and no hub-is-required claim" "$OUT"; fi

printf '\n== every rule fires on the input it exists to catch ==\n'

cp "$DOC" "$TMP/r1.md"; printf '\n    --header "Authorization: Bearer syn_EXAMPLE"\n' >> "$TMP/r1.md"
if scan "$TMP/r1.md" >/dev/null; then bad "R1 fires on a Bearer credential" "scanner passed it"
else ok "R1 fires on a Bearer credential"; fi

cp "$DOC" "$TMP/r2.md"; printf '\nSee https://hub.internal.example.corp for the console.\n' >> "$TMP/r2.md"
if OUT="$(scan "$TMP/r2.md")"; then bad "R2 fires on an unlisted host" "scanner passed it"
else case "$OUT" in *R2*) ok "R2 fires on an unlisted host";; *) bad "R2 fires on an unlisted host" "wrong rule: $OUT";; esac; fi

# An allowlist matched by substring is not an allowlist.
cp "$DOC" "$TMP/r2b.md"; printf '\nSee https://docs.onedroid.ai.example.net/quickstart.\n' >> "$TMP/r2b.md"
if OUT="$(scan "$TMP/r2b.md")"; then bad "R2 fires on a lookalike suffix" "scanner passed it"
else case "$OUT" in *R2*) ok "R2 fires on a lookalike suffix";; *) bad "R2 fires on a lookalike suffix" "wrong rule: $OUT";; esac; fi

cp "$DOC" "$TMP/r2c.md"; printf '\nSee http://synapse.onedroid.ai for the console.\n' >> "$TMP/r2c.md"
if OUT="$(scan "$TMP/r2c.md")"; then bad "R2 fires on a plain-http form of a listed host" "scanner passed it"
else case "$OUT" in *R2*) ok "R2 fires on a plain-http form of a listed host";; *) bad "R2 fires on a plain-http form of a listed host" "wrong rule: $OUT";; esac; fi

cp "$DOC" "$TMP/r3.md"; printf '\nexport DF_HUB_TOKEN=abcdefghijklmnopqrstuvwxyz012345\n' >> "$TMP/r3.md"
if OUT="$(scan "$TMP/r3.md")"; then bad "R3 fires on an opaque literal" "scanner passed it"
else case "$OUT" in *R3*) ok "R3 fires on an opaque literal";; *) bad "R3 fires on an opaque literal" "wrong rule: $OUT";; esac; fi

cp "$DOC" "$TMP/p1.md"; printf '\nThe hub URL is the endpoint it serves, usually ending in `/mcp`.\n' >> "$TMP/p1.md"
if OUT="$(prose "$TMP/p1.md")"; then bad "P1 fires on the /mcp guess" "scanner passed it"
else case "$OUT" in P1*) ok "P1 fires on the /mcp guess";; *) bad "P1 fires on the /mcp guess" "wrong rule: $OUT";; esac; fi

SLUGPATH="hub"  # assembled, never written down: a hub path is itself a landmark class,
                # and the publish gate fails any tracked file that carries one
cp "$DOC" "$TMP/p1b.md"; printf '\nUse https://synapse.onedroid.ai/%s/my-hub-ab12cd/mcp with your token.\n' "$SLUGPATH" >> "$TMP/p1b.md"
if OUT="$(prose "$TMP/p1b.md")"; then bad "P1 fires on the OAuth slug path" "scanner passed it"
else case "$OUT" in P1*) ok "P1 fires on the OAuth slug path";; *) bad "P1 fires on the OAuth slug path" "wrong rule: $OUT";; esac; fi

cp "$DOC" "$TMP/p2.md"; printf '\nBefore step 4 you need your own hub.\n' >> "$TMP/p2.md"
if OUT="$(prose "$TMP/p2.md")"; then bad "P2 fires on a hub-is-required claim" "scanner passed it"
else case "$OUT" in P2*) ok "P2 fires on a hub-is-required claim";; *) bad "P2 fires on a hub-is-required claim" "wrong rule: $OUT";; esac; fi

# ...and stays QUIET on the forms the page must be free to say. A rule that is wrong on
# correct input teaches people to ignore it, which costs more than the rule is worth.
cp "$DOC" "$TMP/p2ok.md"; printf '\nYou do not need a hub to finish steps 1-3, and bring your own hub is supported.\n' >> "$TMP/p2ok.md"
if prose "$TMP/p2ok.md" >/dev/null; then ok "P2 stays quiet on the optional framing"
else bad "P2 stays quiet on the optional framing" "$(prose "$TMP/p2ok.md")"; fi

cp "$DOC" "$TMP/r2ok.md"; printf '\nSee <https://docs.onedroid.ai/quickstart> for the vendor path.\n' >> "$TMP/r2ok.md"
if scan "$TMP/r2ok.md" >/dev/null; then ok "R2 stays quiet on an allowlisted host"
else bad "R2 stays quiet on an allowlisted host" "$(scan "$TMP/r2ok.md")"; fi

printf '\n== a stranger can get from nothing to a hub ==\n'

# The sequence is the deliverable. Each of these is a step the reader cannot infer and
# cannot recover from by guessing, so its ABSENCE is the defect this section guards.

if grep -q 'synapse\.onedroid\.ai' "$DOC"; then ok "the page names where to sign up"
else bad "the page names where to sign up" "no default hub named -- a stranger stalls at step 4"; fi

if grep -qiE 'same( sign-?in| sign-?up)? method every time|Clerk' "$DOC"; then
  ok "warns that a second sign-in method makes a second account"
else bad "warns that a second sign-in method makes a second account" \
     "the first click of the flow, and it presents as 'signed in, no hub'"; fi

if grep -q 'YOUR-PASSWORD' "$DOC"; then ok "warns to leave the connection-string placeholder literal"
else bad "warns to leave the connection-string placeholder literal" \
     "the vendor calls this the single most common failure in the flow"; fi

if grep -qiE 'only an admin|admin (has to|must) enable|members cannot' "$DOC"; then
  ok "names the zero-connections trap (invited member, valid token, no tools)"
else bad "names the zero-connections trap (invited member, valid token, no tools)" \
     "a stranger invited into someone else's hub sees this and blames their token"; fi

printf '\n== the other two audiences still have a path ==\n'

if grep -qiE 'bring your own|your own (mcp )?(hub|endpoint)' "$DOC"; then ok "bring-your-own-hub is still on the page"
else bad "bring-your-own-hub is still on the page" "hard stop: the default must not become a lock-in"; fi

if grep -qiE 'no hub at all|without a hub|do not (have|need) a hub|delete' "$DOC"; then ok "the no-hub path is still on the page"
else bad "the no-hub path is still on the page" "the method does not depend on a hub"; fi

printf '\n== it cites rather than restating ==\n'

for u in 'docs.onedroid.ai/quickstart' 'docs.onedroid.ai/troubleshooting'; do
  if grep -q "$u" "$DOC"; then ok "links $u"
  else bad "links $u" "the detail must live in one place, and it is not this one"; fi
done

if grep -q 'DF_HUB_TOKEN' "$DOC"; then ok "names the token by variable, not by value"
else bad "names the token by variable, not by value"; fi

printf '\n== every table row is still a row ==\n'

# Written because this edit made exactly this mistake: a table cell long enough to wrap got
# committed across two lines, which renders as a broken table plus a stray line of prose.
# Nothing else here would have caught it -- the content assertions all still passed, because
# the words were present. Markdown is whitespace-significant in precisely one place and this
# is it.
rows() {
  python3 - "$1" <<'PYEOF'
import io,sys
lines=io.open(sys.argv[1],encoding='utf-8').read().splitlines()
bad=[]; intbl=False
for i,l in enumerate(lines):
    t=l.strip()
    if set(t) <= set('|-: ') and t.startswith('|') and '-' in t:
        intbl=True; continue
    if intbl:
        if not t: intbl=False; continue
        if not (t.startswith('|') and t.endswith('|')): bad.append(i+1)
print(' '.join(str(b) for b in bad))
PYEOF
}

BADR="$(rows "$DOC")"
if [ -z "$BADR" ]; then ok "no table row wrapped onto a second line"
else bad "no table row wrapped onto a second line" "line(s): $BADR"; fi

cp "$DOC" "$TMP/row.md"; printf '\n| a | b |\n|---|---|\n| one | two\n  spilled onto the next line |\n' >> "$TMP/row.md"
if [ -n "$(rows "$TMP/row.md")" ]; then ok "the table check fires on a wrapped row"
else bad "the table check fires on a wrapped row" "passed a row split across two lines"; fi

printf '\n== every in-page anchor resolves ==\n'

# link-check.py walks relative FILE targets and says so: anchor-only links are out of its
# scope. So a "[see below](#a-heading-that-was-renamed)" is a dead end no gate here sees --
# the same absence-shaped defect that suite exists for, one level down. Slugging follows
# GitHub's rule: lowercase, drop anything but [a-z0-9 _-], spaces to hyphens. The middle
# dot in these headings therefore leaves TWO hyphens behind, which is the part that is
# easy to get wrong by hand and impossible to notice by reading.
anchors() {
  python3 - "$1" <<'PYEOF'
import io,re,sys
doc=io.open(sys.argv[1],encoding='utf-8').read()
def slug(t):
    t=t.strip().lower()
    t=''.join(c for c in t if c.isalnum() or c in ' _-')
    return t.replace(' ','-')
have={slug(m.group(1)) for m in re.finditer(r'(?m)^#{1,6}\s+(.*)$',doc)}
have|=set(re.findall(r'<a id="([^"]+)"',doc))
bad=[a for a in re.findall(r'\]\(#([^)]+)\)',doc) if a not in have]
print(' '.join(sorted(set(bad))))
PYEOF
}

BADA="$(anchors "$DOC")"
if [ -z "$BADA" ]; then ok "no in-page anchor points at a heading that is not there"
else bad "no in-page anchor points at a heading that is not there" "$BADA"; fi

cp "$DOC" "$TMP/anchor.md"; printf '\nSee [nowhere](#a-heading-nobody-wrote).\n' >> "$TMP/anchor.md"
if [ -n "$(anchors "$TMP/anchor.md")" ]; then ok "the anchor check fires on a dangling anchor"
else bad "the anchor check fires on a dangling anchor" "passed a link to a heading that does not exist"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
