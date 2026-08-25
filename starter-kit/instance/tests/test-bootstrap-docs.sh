#!/usr/bin/env bash
# test-bootstrap-docs.sh — bootstrap.sh must hand the instance its project instructions.
#
# Run:  bash starter-kit/instance/tests/test-bootstrap-docs.sh
# Exit: 0 all pass · 1 at least one failed. Prints a literal count, because a suite that
# reports "ok" without saying how many assertions ran cannot be told from one that ran none.
#
# WHY THIS EXISTS. CLAUDE.md is the one artefact whose ABSENCE is silent. A missing skill
# fails as "unknown skill", a missing hook fails as nothing being injected -- both visible.
# An instance with no CLAUDE.md starts a session that simply infers its own rules, and the
# only symptom is an agent behaving reasonably and wrongly. So the render is asserted here
# rather than left to whoever next reads the bootstrap script.
#
# It also asserts the NEGATIVE: with the template removed, bootstrap must WARN rather than
# quietly produce an instance without instructions. A check never run against the input it
# must catch is not known to work.
#
# Everything happens under a temp root. Nothing here reads or writes the running machine's
# config, and no network is required beyond the pin bootstrap already tries to resolve.
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$SELF/.." && pwd)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }

command -v jq  >/dev/null 2>&1 || { printf 'jq is required to run these tests\n'  >&2; exit 1; }
command -v git >/dev/null 2>&1 || { printf 'git is required to run these tests\n' >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

NAME="probe-instance"

printf '\n== the kit ships the docs it promises ==\n'

for f in START-HERE.md CLAUDE.md.template README.md; do
  if [ -s "$KIT/$f" ]; then ok "$f is present and non-empty"
  else bad "$f is present and non-empty" "expected at $KIT/$f"; fi
done

# The template must still carry the placeholder. If someone renders it in place, the
# substitution below would silently become a no-op and this suite would still pass.
if grep -q '__INSTANCE_NAME__' "$KIT/CLAUDE.md.template"; then
  ok "CLAUDE.md.template still carries __INSTANCE_NAME__"
else
  bad "CLAUDE.md.template still carries __INSTANCE_NAME__" "nothing left to substitute"
fi

printf '\n== bootstrap renders it ==\n'

OUT="$TMP/out.txt"
if bash "$KIT/bootstrap.sh" "$NAME" "$TMP/$NAME" >"$OUT" 2>&1; then
  ok "bootstrap.sh exits 0"
else
  bad "bootstrap.sh exits 0" "$(tail -3 "$OUT")"
fi

DEST="$TMP/$NAME/CLAUDE.md"
if [ -s "$DEST" ]; then ok "the instance gets a non-empty CLAUDE.md"
else bad "the instance gets a non-empty CLAUDE.md" "expected $DEST"; fi

if head -1 "$DEST" 2>/dev/null | grep -q "$NAME"; then
  ok "CLAUDE.md names this instance"
else
  bad "CLAUDE.md names this instance" "first line: $(head -1 "$DEST" 2>/dev/null)"
fi

# A surviving placeholder is a value nobody supplied, and it reads as prose. But a document
# that TEACHES the placeholder convention necessarily contains one -- CLAUDE.md explains that
# hooks are copied "with `__HOME__` substituted per machine". A plain text scan reports that
# documentation as unfilled data: a warning that is wrong on every correct file, which is the
# fastest way to teach someone to skip warnings. install.sh hit this exact trap on the
# lockfile and answered it by walking values rather than grepping text. Markdown has no
# values, so the equivalent distinction here is inline code: inside backticks it is being
# named, outside them it is being used.
LEFTOVER="$(sed 's/`[^`]*`//g' "$DEST" 2>/dev/null | grep -o '__[A-Z_]*__' | sort -u | tr '\n' ' ')"
if [ -n "$LEFTOVER" ]; then
  bad "no placeholder survives the render" "$LEFTOVER"
else
  ok "no placeholder survives the render (backticked mentions are documentation, not data)"
fi

# The generated instance must not carry the template as well as the render: two files that
# say the same thing drift, and the one people edit is never the one that is read.
if [ -e "$TMP/$NAME/CLAUDE.md.template" ]; then
  bad "the template itself is not copied into the instance"
else
  ok "the template itself is not copied into the instance"
fi

if grep -q 'START-HERE.md' "$OUT"; then
  ok "bootstrap points the reader at START-HERE.md"
else
  bad "bootstrap points the reader at START-HERE.md" "not mentioned in its output"
fi

printf '\n== and says so when it cannot ==\n'

# Copy the kit, remove the template, and prove the WARN branch fires. Done on a copy so a
# failing test can never damage the real kit.
SBX="$TMP/sandbox"
cp -R "$KIT" "$SBX" 2>/dev/null
rm -f "$SBX/CLAUDE.md.template"
OUT2="$TMP/out2.txt"
bash "$SBX/bootstrap.sh" "$NAME" "$TMP/nodocs" >"$OUT2" 2>&1

if grep -q 'WARN.*CLAUDE.md.template missing' "$OUT2"; then
  ok "a missing template is reported, not skipped"
else
  bad "a missing template is reported, not skipped" "$(tail -3 "$OUT2")"
fi

if [ -e "$TMP/nodocs/CLAUDE.md" ]; then
  bad "no CLAUDE.md is invented when the template is gone"
else
  ok "no CLAUDE.md is invented when the template is gone"
fi


# ── the front door ────────────────────────────────────────────────────────────
# A stranger lands on README.md, not here. An on-ramp the front page does not name is an
# on-ramp nobody finds, and this is invisible from inside the repo: everyone who already
# knows the path can reach it. Found by a clean-room clone (ticket 12878505510), which is
# the only vantage point from which it is visible at all.
REPO_ROOT="$(cd "$KIT/../.." && pwd)"
README="$REPO_ROOT/README.md"
if [ -f "$README" ]; then
  if grep -q 'START-HERE' "$README"; then
    ok "README names START-HERE, so the entry point is reachable from the front door"
  else
    bad "README does not name START-HERE" "a stranger lands on README and finds no on-ramp"
  fi
  if grep -q 'starter-kit' "$README"; then
    ok "README names starter-kit/, so the directory is discoverable"
  else
    bad "README does not name starter-kit/" "the contents table omits the on-ramp entirely"
  fi
else
  bad "README.md not found at $README" "cannot check the front door"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
