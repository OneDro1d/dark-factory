#!/usr/bin/env bash
# Every SKILL.md frontmatter must be parseable YAML — specifically, `description:` must not
# carry an unquoted `: `.
#
# WHY THIS EXISTS. `description: Run the gate: assess whether…` is ambiguous YAML: the
# second colon reads as a nested mapping and the parser rejects the whole document. The
# skill is then SKIPPED at install. Twelve skills — almost exactly the Dark Factory method
# set, because those descriptions are written in the "Stage: what it does" style — were
# silently absent from every `npx skills add` for weeks. The installer did print a warning
# per skill; it scrolled past above a summary line that said only how many succeeded.
#
# The count nobody had: there are more SKILL.md files than skills. Bundled plugins nest
# their own, so this walks the tree rather than globbing skills/*/SKILL.md — a depth-2 glob
# found 12 of the 14 and reported itself finished.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
PASSED=0; FAILED=0

# Print `ok`, `quoted`, or `AMBIGUOUS` for the description in $1, or nothing if there is
# no frontmatter. Only the first frontmatter block is considered.
verdict() {
  awk '
    NR==1 { if ($0 !~ /^---[[:space:]]*$/) exit; infm=1; next }
    infm && /^---[[:space:]]*$/ { exit }
    infm && /^description:/ {
      v=substr($0,13)
      sub(/^[[:space:]]+/,"",v)
      if (v ~ /^["'"'"']/) { print "quoted"; exit }
      if (v ~ /: /)        { print "AMBIGUOUS"; exit }
      print "ok"; exit
    }
  ' "$1"
}

echo "=== SKILL.md frontmatter: no unquoted \": \" in description ==="

BAD=""; N=0
while IFS= read -r f; do
  v="$(verdict "$f")"
  [ -n "$v" ] || continue
  N=$((N+1))
  [ "$v" = "AMBIGUOUS" ] && BAD="$BAD${f#$ROOT/}"$'\n'
done < <(find "$ROOT" -name SKILL.md -not -path '*/.git/*' | sort)

if [ -z "$BAD" ]; then
  PASSED=$((PASSED+1)); printf '  ok    all %d frontmatter blocks are unambiguous\n' "$N"
else
  FAILED=$((FAILED+1)); printf '  FAIL  %d file(s) would be SKIPPED at install:\n' "$(printf '%s' "$BAD" | grep -c .)"
  printf '%s' "$BAD" | while read -r l; do [ -n "$l" ] && printf '          %s\n' "$l"; done
  printf '        fix: quote the value — description: "Stage: what it does"\n'
fi

# The check must be able to fail, or it is decoration. Plant one and watch it.
CAN="$(mktemp -d)"
trap 'rm -rf "$CAN"' EXIT
mkdir -p "$CAN/x"
printf -- '---\nname: x\ndescription: A thing: and another\n---\nbody\n' > "$CAN/x/SKILL.md"
if [ "$(verdict "$CAN/x/SKILL.md")" = "AMBIGUOUS" ]; then
  PASSED=$((PASSED+1)); printf '  ok    canary: an unquoted colon IS detected\n'
else
  FAILED=$((FAILED+1)); printf '  FAIL  canary not detected — this check cannot fail\n'
fi
printf -- '---\nname: x\ndescription: "A thing: and another"\n---\nbody\n' > "$CAN/x/SKILL.md"
if [ "$(verdict "$CAN/x/SKILL.md")" = "quoted" ]; then
  PASSED=$((PASSED+1)); printf '  ok    canary: quoting it clears the finding\n'
else
  FAILED=$((FAILED+1)); printf '  FAIL  quoted form still flagged — the fix it prescribes does not work\n'
fi

echo
printf '%d passed, %d failed\n' "$PASSED" "$FAILED"

# The assertion-count contract read by run-tests.sh. Exit status alone cannot tell
# "asserted every one of these" from "asserted nothing" — both exit 0 — so the count
# is DECLARED here rather than parsed out of the summary line above it.
echo "ASSERTIONS: $((PASSED + FAILED))"
[ "$FAILED" -eq 0 ] || exit 1
