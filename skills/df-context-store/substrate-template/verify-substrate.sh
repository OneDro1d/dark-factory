#!/usr/bin/env bash
# verify-substrate.sh — acceptance check for the DF Substrate Template (VR1-VR8).
# The test list IS the PO validation rules; green is the bar. Hardened after a blind
# adversary gate found 5 ways the existence-only checks were fooled — each check below
# now asserts CONTENT, not mere presence. Run after emitting or editing the template.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DC="$HERE/dotclaude"
SKILLDIR="$(cd "$HERE/.." && pwd)"   # the df-context-store skill dir (template is bundled inside it)
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

# havemin <relpath-under-dotclaude> <min-lines> [must-contain-regex]
havemin() {
  local f="$DC/$1" min="$2" re="${3:-}"
  if [ ! -s "$f" ]; then bad "missing/empty: dotclaude/$1"; return; fi
  local n; n=$(wc -l < "$f")
  if [ "$n" -lt "$min" ]; then bad "too thin ($n<$min lines): dotclaude/$1"; return; fi
  if [ -n "$re" ] && ! grep -qE "$re" "$f"; then bad "content check failed ($re): dotclaude/$1"; return; fi
  ok "valid ($n lines): dotclaude/$1"
}

echo "== VR1: required files present AND non-trivial (not empty stubs) =="
for a in investigator root-cause-analyzer feature-architect implementer validator knowledge-keeper ; do
  havemin "agents/$a.md" 10 '^name:'
done
havemin "agents/README.md" 20 'investigator'
havemin "context/README.md" 8
havemin "context/SERVICE-MAP.md" 5
havemin "context/DATA-FLOW.md" 10 'authority'
havemin "context/FINDINGS.md" 5
havemin "context/DECISIONS.md" 5
havemin "context/AGENT-CONTRACTS.md" 25 'validation_report'
havemin "skills/contract-check/SKILL.md" 8
havemin "skills/contract-check/check_contract.py" 50 'def validate'
havemin "skills/contract-check/check_contract_test.py" 20
havemin "skills/commit-sync/SKILL.md" 8
[ -x "$DC/hooks/pre-commit" ] && ok "exists+exec: hooks/pre-commit" || bad "missing/not-executable: dotclaude/hooks/pre-commit"
[ -x "$DC/hooks/ensure-gate.sh" ] && ok "exists+exec: hooks/ensure-gate.sh (self-arm)" || bad "missing/not-executable: dotclaude/hooks/ensure-gate.sh"
if [ -s "$DC/settings.json" ] && grep -q 'SessionStart' "$DC/settings.json" && grep -q 'ensure-gate.sh' "$DC/settings.json"; then ok "settings.json: SessionStart → ensure-gate.sh"; else bad "settings.json missing or no SessionStart→ensure-gate.sh wiring"; fi
[ -s "$HERE/README.md" ] && ok "exists: README.md" || bad "missing: README.md"
[ -s "$HERE/CLAUDE-stanza.md" ] && ok "exists: CLAUDE-stanza.md" || bad "missing: CLAUDE-stanza.md"

echo "== VR2: no source-project leakage (denylist + home paths + id/spelling families) =="
# THE DENYLIST IS SUPPLIED, NOT HARDCODED (2026-08-25).
#
# Until now this line carried the source project REAL identifiers - its service-name
# family, its column names, its record-type spellings and its estate name - inline, in a
# file published in a public repo. A leak detector that spells out the nouns it is hunting
# publishes them itself, which is the same defect landmarks.example.conf already solved by
# keeping placeholders in the committed file and the real list in a gitignored sibling.
# publish-gate found it the day P1 learned to match the estate name bare.
#
# It is deliberately NOT defaulted to placeholder nouns. A denylist of invented words
# matches nothing and this check would then pass on every substrate forever - an inert
# check reporting green is the most repeated failure in this repo history, and it is worse
# than no check at all. Unconfigured is therefore a FAILURE with an instruction, never ok.
#
# Supply it either way:
#   SUBSTRATE_DENYLIST=... bash verify-substrate.sh
#   or `cp substrate-denylist.example.conf substrate-denylist.conf` and edit it (the .conf
#   name is gitignored; the .example is committed and holds the shape, never real nouns).
DENY_FILE="$HERE/substrate-denylist.conf"
DENY="${SUBSTRATE_DENYLIST:-}"
[ -n "$DENY" ] || { [ -f "$DENY_FILE" ] && DENY="$(grep -v '^[[:space:]]*#' "$DENY_FILE" | grep -v '^[[:space:]]*$' | head -1)"; }

# Home paths are UNIVERSAL leak shapes, not source-project nouns, so they stay inline and
# keep working with no configuration at all.
HOMEPATHS='/home/[a-z]|/Users/[A-Za-z]'

if [ -z "$DENY" ]; then
  bad "VR2 cannot run: no source-project denylist configured — cp substrate-denylist.example.conf substrate-denylist.conf and edit it (or set SUBSTRATE_DENYLIST)"
  LEAK="$(grep -rEinl --exclude-dir=__pycache__ --exclude='*.pyc' "$HOMEPATHS" "$DC" 2>/dev/null || true)"
  [ -z "$LEAK" ] || { bad "home-path leakage found in:"; printf '%s\n' "$LEAK"; }
else
  LEAK="$(grep -rEinl --exclude-dir=__pycache__ --exclude='*.pyc' "$DENY|$HOMEPATHS" "$DC" 2>/dev/null || true)"
  if [ -z "$LEAK" ]; then ok "no leaked tokens/home-paths in dotclaude/"; else bad "leakage found in:"; printf '%s\n' "$LEAK"; fi
fi

echo "== VR3: contract-check tool is REAL + green + actually enforces =="
if python3 "$DC/skills/contract-check/check_contract_test.py" >/tmp/_cc.out 2>&1; then
  N="$(grep -Eo 'Ran [0-9]+ tests' /tmp/_cc.out | grep -Eo '[0-9]+' | tail -1)"
  if [ "${N:-0}" -ge 8 ]; then ok "checker suite green (Ran $N tests, >=8)"; else bad "checker suite too few tests (Ran ${N:-0}, need >=8) — stubbed?"; fi
else
  bad "checker suite failed:"; tail -3 /tmp/_cc.out
fi
CC="$DC/skills/contract-check/check_contract.py"
printf 'INTENDED: x\nTESTED: y\nRESULT: looks good, all green\nVERDICT: PASS\n' > /tmp/_bad_rep.txt
printf 'INTENDED: x\nTESTED: y\nRESULT: 12 passed, 0 failed\nVERDICT: PASS\n' > /tmp/_good_rep.txt
python3 "$CC" validation_report /tmp/_bad_rep.txt 2>/dev/null | grep -q REJECT && ok "checker REJECTs a forged PASS (enforces)" || bad "checker did NOT reject a forged PASS — gutted/non-functional"
python3 "$CC" validation_report /tmp/_good_rep.txt 2>/dev/null | grep -q '^OK' && ok "checker accepts a valid report" || bad "checker rejects a valid report — broken"

echo "== VR4: CLAUDE-stanza carries read-first + dispatch table + standing rules =="
S="$HERE/CLAUDE-stanza.md"
grep -qi 'read the context store first' "$S" && ok "stanza: read-first" || bad "stanza: no read-first protocol"
grep -q 'AGENT-CONTRACTS' "$S" && ok "stanza: AGENT-CONTRACTS pointer" || bad "stanza: no AGENT-CONTRACTS pointer"
grep -q 'investigator' "$S" && grep -q 'feature-architect' "$S" && grep -q 'validator' "$S" && ok "stanza: dispatch table present" || bad "stanza: dispatch table missing"
grep -qiE 'verify, don.t trust|re-run|its own auditor' "$S" && ok "stanza: verify rule present" || bad "stanza: verify rule missing"
grep -qiE 'no guessing|escalate' "$S" && ok "stanza: no-guessing rule present" || bad "stanza: no-guessing rule missing"

echo "== VR5: AGENT-CONTRACTS defines real contracts + pure/effect + verification =="
A="$DC/context/AGENT-CONTRACTS.md"
grep -qi 'pure' "$A" && grep -qi 'effect' "$A" && ok "contracts: pure/effect" || bad "contracts: missing pure/effect"
grep -qi 'unforgeable' "$A" && ok "contracts: unforgeable-evidence rule" || bad "contracts: missing verification rule"
C=0
for k in evidence_bundle root_cause design_spec validation_report knowledge_entry ; do grep -q "$k" "$A" && C=$((C+1)); done
[ "$C" -ge 4 ] && ok "contracts: $C/5 hand-off contracts named" || bad "contracts: only $C/5 contract rows (table gutted?)"

echo "== VR6: ledgers are clean skeletons — placeholder present AND no real entries =="
CITE='[A-Za-z0-9_]+\.[A-Za-z0-9]+:[0-9]+'   # a real file:line; placeholders use <...>
for f in context/FINDINGS.md context/DECISIONS.md context/SERVICE-MAP.md context/DATA-FLOW.md ; do
  grep -q '<' "$DC/$f" || { bad "no placeholder (not a skeleton?): $f"; continue; }
  if grep -qE "$CITE" "$DC/$f"; then bad "real file:line entry found (pre-populated): $f"; else ok "clean skeleton: $f"; fi
done

echo "== VR7: skill wiring — df-context-store references the bundled substrate =="
SKILL="$SKILLDIR/SKILL.md"
[ -s "$SKILL" ] && ok "df-context-store SKILL.md present (bundled with template)" || bad "df-context-store SKILL.md missing alongside template"
grep -q 'substrate-template' "$SKILL" && ok "SKILL references the bundled substrate-template" || bad "SKILL.md does not reference substrate-template"

echo "== VR8: gate self-arms (ensure-gate.sh) AND actually enforces =="
HOOK="$DC/hooks/pre-commit"
GATE="$DC/hooks/ensure-gate.sh"
if [ ! -x "$HOOK" ] || [ ! -x "$GATE" ]; then
  bad "pre-commit or ensure-gate.sh not executable — cannot test"
else
  SBX="$(mktemp -d)"
  (
    cd "$SBX" || exit 1
    git init -q
    git config user.email t@t.test
    git config user.name tester
    mkdir -p .claude/context .claude/hooks
    cp "$HOOK" .claude/hooks/pre-commit
    cp "$GATE" .claude/hooks/ensure-gate.sh
    chmod +x .claude/hooks/pre-commit .claude/hooks/ensure-gate.sh
    : > .claude/context/SERVICE-MAP.md
    : > .claude/context/DATA-FLOW.md
    # self-arm via the hook (NOT a manual git config) — proves the every-clone carrier
    sh .claude/hooks/ensure-gate.sh >/dev/null 2>&1
    echo "ARM=$(git config --get core.hooksPath 2>/dev/null || echo none)"
    git add -A
    git commit -qm init --no-verify
    # CASE A — trigger file (schema.sql) staged, NO doc → gate must BLOCK
    echo "select 1;" > schema.sql
    git add schema.sql
    if git commit -qm "schema only" >/dev/null 2>&1; then echo "A=ALLOWED"; else echo "A=BLOCKED"; fi
    # CASE B — same change but a map doc also staged → gate must ALLOW
    echo "- entry" >> .claude/context/SERVICE-MAP.md
    git add .claude/context/SERVICE-MAP.md schema.sql
    if git commit -qm "schema + map" >/dev/null 2>&1; then echo "B=ALLOWED"; else echo "B=BLOCKED"; fi
  ) > "$SBX/_out" 2>/dev/null
  grep -q 'ARM=.claude/hooks' "$SBX/_out" && ok "ensure-gate.sh self-armed core.hooksPath (no manual step)" || bad "ensure-gate.sh did NOT self-arm core.hooksPath"
  grep -q 'A=BLOCKED' "$SBX/_out" && ok "gate BLOCKS an undocumented structural change" || bad "gate did NOT block an undocumented structural change — not enforcing"
  grep -q 'B=ALLOWED' "$SBX/_out" && ok "gate ALLOWS the change once the doc is staged" || bad "gate blocks even WITH the doc staged — false-positive/broken"
  rm -rf "$SBX"
fi

echo
echo "Ran $((pass+fail)) checks, $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
