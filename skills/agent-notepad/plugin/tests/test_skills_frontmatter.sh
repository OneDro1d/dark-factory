#!/usr/bin/env bash
# tests/test_skills_frontmatter.sh — U7 acceptance: the two skill instruction docs
# (scope-init, scope-retire) exist and carry valid frontmatter (name + description),
# and name matches the skill directory. These are instruction docs — no runtime code —
# so the test verifies the frontmatter parses, per the U7 brief.
#
# Portable: bash + python3 only. Run: bash tests/test_skills_frontmatter.sh
set -u

_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILLS_DIR="$(cd "$_DIR/.." && pwd)/skills"

pass=0
fail=0

ok() { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
no() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }

# Parse a SKILL.md frontmatter block with python3 (no PyYAML dependency): read the
# first `---`...`---` fence and extract top-level `key: value` lines. Prints the
# value for the requested key, or nothing.
fm_get() {
  # $1 = file, $2 = key
  python3 - "$1" "$2" <<'PY'
import sys
path, key = sys.argv[1], sys.argv[2]
try:
    text = open(path, encoding="utf-8").read()
except OSError:
    sys.exit(0)
lines = text.splitlines()
if not lines or lines[0].strip() != "---":
    sys.exit(0)  # no opening fence
body = []
closed = False
for ln in lines[1:]:
    if ln.strip() == "---":
        closed = True
        break
    body.append(ln)
if not closed:
    sys.exit(0)  # unterminated frontmatter
for ln in body:
    if ":" in ln and not ln.startswith((" ", "\t", "#")):
        k, _, v = ln.partition(":")
        if k.strip() == key:
            print(v.strip())
            break
PY
}

for skill in scope-init scope-retire; do
  f="$SKILLS_DIR/$skill/SKILL.md"

  if [ -f "$f" ]; then
    ok "$skill: SKILL.md exists"
  else
    no "$skill: SKILL.md exists ($f missing)"
    continue
  fi

  name="$(fm_get "$f" name)"
  if [ -n "$name" ]; then
    ok "$skill: frontmatter has name ('$name')"
  else
    no "$skill: frontmatter has name"
  fi

  if [ "$name" = "$skill" ]; then
    ok "$skill: name matches directory"
  else
    no "$skill: name matches directory (got '$name')"
  fi

  desc="$(fm_get "$f" description)"
  if [ -n "$desc" ]; then
    ok "$skill: frontmatter has description (${#desc} chars)"
  else
    no "$skill: frontmatter has description"
  fi

  # grep sanity (brief asks specifically: "grep name:/description:")
  if grep -q '^name:' "$f"; then
    ok "$skill: grep '^name:' matches"
  else
    no "$skill: grep '^name:' matches"
  fi
  if grep -q '^description:' "$f"; then
    ok "$skill: grep '^description:' matches"
  else
    no "$skill: grep '^description:' matches"
  fi
done

printf -- '----\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
