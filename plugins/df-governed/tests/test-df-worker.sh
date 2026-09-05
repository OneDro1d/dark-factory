#!/usr/bin/env bash
# test-df-worker.sh — the launch contract, asserted against the argv df-worker actually
# assembles, never against a description of it.
#
# WHAT IS BEING GUARDED. A plugin's hooks and bin/ reach a headless child on exactly ONE
# delivery path: the `--plugin-dir` command-line flag. The path everyone assumes works —
# a project `.claude/settings.json` declaring `enabledPlugins` — delivers NOTHING to
# `claude -p`, in either settings mode, and it fails SILENTLY (no stdout warning, no
# stderr, `--debug` adds zero bytes). So a worker launched without `--plugin-dir` is
# ungoverned and cannot say so. That is why every flag below is asserted positionally,
# flag-then-value, rather than by a substring that a reordered or truncated argv would
# still satisfy.
#
# PROBE 2 (from the design) is case P2 here. Its original static form was
# `grep -c -- "--setting-sources" <tier-2>/workers/dispatch.sh`; that repo is not reachable
# from this suite, and the shim there now `exec`s THIS launcher, so the shim's dry-run argv
# IS this argv. The dry-run form is therefore the stronger assertion and the one made.
#
# Enrolled by GLOB — a suite is enrolled by existing.
#
# Usage: bash plugins/df-governed/tests/test-df-worker.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SELF/.." && pwd)"
WORKER="$PLUGIN_ROOT/bin/df-worker"

[ -x "$WORKER" ] || { echo "missing or non-executable $WORKER"; exit 2; }
command -v python3 >/dev/null || { echo "python3 required"; exit 2; }
command -v jq >/dev/null || { echo "jq required"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }

# flag-then-value, adjacent, as separate argv words.
pair() { # label flag value text
  if printf '%s\n' "$4" | awk -v f="$2" -v v="$3" \
       'prev==f && $0==v {found=1} {prev=$0} END{exit !found}'
  then ok "$1"; else bad "$1" "no adjacent [$2] [$3] in argv"; fi
}
nopair() { # label flag value text
  if printf '%s\n' "$4" | awk -v f="$2" -v v="$3" \
       'prev==f && $0==v {found=1} {prev=$0} END{exit !found}'
  then bad "$1" "[$2] [$3] IS present and must not be"; else ok "$1"; fi
}
hasline() { # label exact-line text
  if printf '%s\n' "$3" | grep -Fxq -- "$2"; then ok "$1"
  else bad "$1" "no line exactly '$2'"; fi
}
noline() { # label exact-line text
  if printf '%s\n' "$3" | grep -Fxq -- "$2"; then bad "$1" "line '$2' is present and must not be"
  else ok "$1"; fi
}
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dfworker.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# CANONICAL, because df-worker resolves every path with `cd && pwd` and on this platform
# $TMPDIR is itself a symlink. Comparing a symlinked path against a resolved one is a test
# that fails for a reason that has nothing to do with the launcher.
WORK="$(cd "$WORK" && pwd -P)"

# ── a notepad, a mission, a repo ────────────────────────────────────────────────────────
NP="$WORK/notepad"
mkdir -p "$NP/.df/missions/M-TEST" "$WORK/repo"
printf 'notes\n' > "$NP/NOTES.md"
printf 'the acceptance cases live here and the worker must not reach them\n' > "$NP/SCOPE.md"
printf 'RUNNING\n' > "$NP/.df/missions/M-TEST/state"
printf 'tp\n'      > "$NP/.df/missions/M-TEST/profile"
printf '# mission frame\n'    > "$NP/.df/missions/M-TEST/MISSION.md"
printf '# hard stops\n'       > "$NP/.df/missions/M-TEST/HARD-STOPS.md"
printf 'HOLDOUT CASES\n'      > "$NP/.df/missions/M-TEST/holdout.md"

# The MCP source config the allow-list is scoped from. Never the real one.
CFG="$WORK/claude.json"
cat > "$CFG" <<'JSON'
{
  "mcpServers": {
    "tp-hub":    {"url": "https://example.invalid/a/mcp"},
    "other-hub": {"url": "https://example.invalid/b/mcp"}
  }
}
JSON

run_dry() { # -> stdout+stderr of a dry run from inside the notepad
  ( cd "$NP" && WORKER_MCP_SOURCE="$CFG" "$@" ) 2>&1
}

# ── the launcher's rules, and the deny rules that enforce the same policy ───────────────
# Two files, because estate policy arrives in pieces (branch policy and deploy policy have
# different owners) and a launcher that silently kept only the first would be undetectable.
printf 'GIT — never push to main. Verify the branch first.\n' > "$WORK/git-rules.md"
printf 'DEPLOY — never roll out to a production cluster.\n'   > "$WORK/deploy-rules.md"

# ── case 1: the full launch contract ────────────────────────────────────────────────────
OUT="$(run_dry env WORKER_MCP_PROFILE=tp "$WORKER" dev 12345 "return file:line evidence" \
        --repo "$WORK/repo" \
        --rules "$WORK/git-rules.md" --rules "$WORK/deploy-rules.md" \
        --deny "Bash(git push * main)" --deny "Bash(git push --force *)" \
        --deny "Bash(gh pr merge *)"  --deny "Bash(kubectl apply *)" \
        --dry-run)"; RC=$?
if [ "$RC" -eq 0 ]; then ok "W1 --dry-run exits 0"; else bad "W1 --dry-run exits 0" "rc=$RC: $OUT"; fi

# argv only — the prompt is printed after it and must not satisfy an argv assertion.
ARGV="$(printf '%s\n' "$OUT" | awk '/^---- argv ----$/{a=1;next} /^---- prompt ----$/{a=0} a')"

pair "W2 --plugin-dir names this plugin root"       "--plugin-dir"      "$PLUGIN_ROOT" "$ARGV"
pair "P2 --setting-sources project (PROBE 2)"       "--setting-sources" "project"      "$ARGV"
hasline "W3 --strict-mcp-config is passed"          "--strict-mcp-config"              "$ARGV"
pair "W4 --permission-mode defaults to bypassPermissions" "--permission-mode" "bypassPermissions" "$ARGV"
pair "W5 --max-budget-usd defaults to 100"          "--max-budget-usd"  "100"          "$ARGV"
pair "W6 --output-format json"                      "--output-format"   "json"         "$ARGV"

SCRATCH="$(printf '%s\n' "$OUT" | sed -n 's/^scratch: //p' | head -1)"
if [ -n "$SCRATCH" ] && [ -d "$SCRATCH" ]; then ok "W7 the scratch dir is created"
else bad "W7 the scratch dir is created" "scratch='$SCRATCH'"; fi

pair "W8 --add-dir names the scratch dir"           "--add-dir" "$SCRATCH"    "$ARGV"
pair "W9 --add-dir names the target repo"           "--add-dir" "$WORK/repo"  "$ARGV"

# ⛔ THE HOLDOUT. The notepad root holds the mission's acceptance cases. It must appear in
# no --add-dir, and in no argv word at all — the worker's inability to read it is a
# property of the sandbox, not of its good behaviour.
nopair "W10 the notepad root is in NO --add-dir"    "--add-dir" "$NP"         "$ARGV"
noline "W11 the notepad root is in no argv word"    "$NP"                     "$ARGV"

# ── case 2: the scratch dir is a settings scope of its own ──────────────────────────────
if [ -f "$SCRATCH/.claude/settings.json" ]; then ok "W12 scratch carries .claude/settings.json"
else bad "W12 scratch carries .claude/settings.json" "absent"; fi
if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$SCRATCH/.claude/settings.json" 2>/dev/null
then ok "W13 that settings file is valid JSON"; else bad "W13 that settings file is valid JSON" "parse failed"; fi
if [ -f "$SCRATCH/PROMISE.md" ]; then ok "W14 the promise is written to PROMISE.md"
else bad "W14 the promise is written to PROMISE.md" "absent"; fi
contains "W15 PROMISE.md holds the promise text" "return file:line evidence" "$(cat "$SCRATCH/PROMISE.md" 2>/dev/null)"

# ── case 3: the frame is COPIED, never linked ───────────────────────────────────────────
# A symlink into the mission dir is a path back out into the notepad, and the holdout is
# one directory over. `test ! -L` is the whole point of this case.
for f in MISSION.md HARD-STOPS.md; do
  if [ -f "$SCRATCH/$f" ]; then ok "W16 $f is copied into the scratch"
  else bad "W16 $f is copied into the scratch" "absent"; fi
  if [ ! -L "$SCRATCH/$f" ]; then ok "W17 $f is a real file, not a symlink"
  else bad "W17 $f is a real file, not a symlink" "it is a symlink"; fi
done
if [ ! -e "$SCRATCH/holdout.md" ]; then ok "W18 the holdout is NOT copied in"
else bad "W18 the holdout is NOT copied in" "holdout.md reached the scratch"; fi

# ── case 4: the environment the hooks read ──────────────────────────────────────────────
# claim-gate.py is armed by DF_TICKET and by nothing else; hooks inherit the parent
# environment, so these three lines are the arming mechanism, not decoration.
hasline "W19 env DF_TICKET is exported"  "DF_TICKET=12345"    "$OUT"
hasline "W20 env DF_ROLE is exported"    "DF_ROLE=dev"        "$OUT"
hasline "W21 env DF_MISSION resolves the single RUNNING mission" "DF_MISSION=M-TEST" "$OUT"

# ── case 3b: --rules travels VERBATIM into the brief and onto disk ──────────────────────
# ⛔ THE REGRESSION THIS GUARDS. The per-role git policy and the estate's deploy/cluster
# hard stops used to be templated into the worker prompt by the Tier-2 dispatcher. When
# that dispatcher became a shim they had no home for one revision, and a worker launched
# through it knew nothing about branch policy. They now travel as --rules: authored by the
# estate (which may name its own clusters), transported by this launcher (which is public
# and must not).
BRIEF="$(printf '%s\n' "$OUT" | awk '/^---- prompt ----$/{p=1;next} p')"
contains "R1 the rules heading is in the brief" "## Rules from the launcher (binding)" "$BRIEF"
contains "R2 the first rules file appears verbatim"  "never push to main" "$BRIEF"
contains "R3 the second rules file appears verbatim" "never roll out to a production cluster" "$BRIEF"
# after the promise, before the evidence contract — a worker reads what to deliver, then
# the bounds, then how to prove it.
if printf '%s\n' "$BRIEF" | awk '
  /^PROMISE \(/            {p=NR}
  /Rules from the launcher/{r=NR}
  /^EVIDENCE —/            {e=NR}
  END{exit !(p && r && e && p < r && r < e)}'
then ok "R4 the rules sit after the promise and before the evidence contract"
else bad "R4 rules ordering" "heading is not between PROMISE and EVIDENCE"; fi
contains "R5 RULES.md is written to the scratch" "never push to main" "$(cat "$SCRATCH/RULES.md" 2>/dev/null)"
contains "R6 RULES.md carries BOTH files" "never roll out to a production cluster" "$(cat "$SCRATCH/RULES.md" 2>/dev/null)"
hasline "R7 --dry-run names each rules file" "rules: $WORK/git-rules.md" "$OUT"
hasline "R8 --dry-run names the second rules file" "rules: $WORK/deploy-rules.md" "$OUT"

# ── case 3c: a missing rules file is a REFUSAL ──────────────────────────────────────────
# ⛔ Rules that silently fail to load produce a worker that is confidently ungoverned and
# reports success. That is the failure this ticket exists to end, so it is a non-zero exit
# before anything is created — not a warning on a line nobody reads.
OUT5="$(run_dry env WORKER_MCP_PROFILE=tp "$WORKER" dev 12345 "p" --rules "$WORK/nope.md" --dry-run)"; RC5=$?
if [ "$RC5" -ne 0 ]; then ok "R9 a missing --rules file refuses (non-zero)"
else bad "R9 a missing --rules file refuses" "rc=0"; fi
contains "R10 the refusal names the missing file" "$WORK/nope.md" "$OUT5"
contains "R11 the refusal says it is refusing"    "REFUSING"       "$OUT5"
noline   "R12 nothing was launched"               "---- argv ----" "$OUT5"

# ── case 3d: --deny is the MECHANISM half ───────────────────────────────────────────────
# Text a model reads can be skimmed; a permission rule cannot. The child runs
# `--setting-sources project` from this scratch dir, so this file is the one it loads.
SETTINGS="$SCRATCH/.claude/settings.json"
hasline "D1 --dry-run names each deny rule" "deny: Bash(git push * main)"    "$OUT"
hasline "D2 --dry-run names the merge deny" "deny: Bash(gh pr merge *)"      "$OUT"
if jq -e '.permissions.deny|length>=4' "$SETTINGS" >/dev/null 2>&1
then ok "D3 settings.json carries at least 4 deny rules"
else bad "D3 settings.json carries at least 4 deny rules" "$(jq -c '.permissions' "$SETTINGS" 2>&1)"; fi
for rule in 'Bash(git push * main)' 'Bash(git push --force *)' 'Bash(gh pr merge *)' 'Bash(kubectl apply *)'; do
  if jq -e --arg r "$rule" '.permissions.deny|index($r)!=null' "$SETTINGS" >/dev/null 2>&1
  then ok "D4 deny rule verbatim: $rule"
  else bad "D4 deny rule verbatim: $rule" "absent from .permissions.deny"; fi
done
if jq -e '.hooks' "$SETTINGS" >/dev/null 2>&1; then ok "D5 the hooks object survives beside permissions"
else bad "D5 the hooks object survives" "absent"; fi
# A rule carrying a quote must not produce a settings file Claude Code rejects as a
# Settings Error — i.e. deny rules that silently did not load.
OUT6="$(run_dry env WORKER_MCP_PROFILE=tp "$WORKER" dev 12345 "p" --deny 'Bash(echo "hi" *)' --dry-run)"
S6="$(printf '%s\n' "$OUT6" | sed -n 's/^scratch: //p' | head -1)"
if jq -e '.permissions.deny|length==1' "$S6/.claude/settings.json" >/dev/null 2>&1
then ok "D6 a quote-bearing rule still writes strict JSON"
else bad "D6 a quote-bearing rule still writes strict JSON" "invalid or wrong length"; fi

# ── case 5: the mission's own profile file, when no env override ────────────────────────
OUT2="$(run_dry "$WORKER" dev 12345 "p" --dry-run)"
contains "W22 the mission profile file picks the MCP profile" "mcp-profile: tp" "$OUT2"

# ── case 6: REFUSE when the allow-list cannot be built ──────────────────────────────────
# ⛔ A worker with no tracker cannot report that it has none. Launching anyway produces a
# child that boots clean, writes nothing, and looks like a worker that found nothing to do.
OUT3="$(run_dry env WORKER_MCP_PROFILE=nosuchprofile "$WORKER" dev 12345 "p" --dry-run)"; RC3=$?
if [ "$RC3" -ne 0 ]; then ok "W23 refuses (non-zero) when the MCP profile cannot be built"
else bad "W23 refuses when the MCP profile cannot be built" "rc=0"; fi
contains "W24 the refusal says why" "REFUSING" "$OUT3"
noline   "W25 nothing was launched"  "---- argv ----" "$OUT3"

# ── case 7: two RUNNING missions is ambiguous, and ambiguity is not guessed ─────────────
mkdir -p "$NP/.df/missions/M-OTHER"
printf 'RUNNING\n' > "$NP/.df/missions/M-OTHER/state"
OUT4="$(run_dry env WORKER_MCP_PROFILE=tp "$WORKER" dev 12345 "p" --dry-run)"
hasline "W26 two RUNNING missions leaves DF_MISSION empty" "DF_MISSION=" "$OUT4"

echo ""
# ── case 8: the INSTALLED layout — plugin under ~/.claude/skills, engine elsewhere ────────
# Measured on the first laptop install (2026-09-05): install.plugins[] put this launcher at
# ~/.claude/skills/df-governed/bin/df-worker, so KIT_ROOT resolved to ~/.claude, which has no
# boot-kit/, and the launcher REFUSED every worker. The engine is wherever the installer
# materialised it — and rehydrate.sh links df-mission from that directory onto PATH. So the
# engine dir is: where df-mission really lives, through the symlink.
INST="$WORK/installed"
mkdir -p "$INST/home/.claude/skills" "$INST/engine" "$INST/bin"
cp -R "$(cd "$(dirname "$WORKER")/.." && pwd)" "$INST/home/.claude/skills/df-governed"
cp "$(cd "$(dirname "$WORKER")/../../.." && pwd)/boot-kit/scripts/mcp-profile-config.py" "$INST/engine/mcp-profile-config.py"
printf '#!/usr/bin/env bash\necho df-mission-stub\n' > "$INST/engine/df-mission"
chmod +x "$INST/engine/df-mission"
ln -s "$INST/engine/df-mission" "$INST/bin/df-mission"
IW="$INST/home/.claude/skills/df-governed/bin/df-worker"
OUT8="$(run_dry env PATH="$INST/bin:$PATH" WORKER_MCP_PROFILE=tp "$IW" dev 12345 "p" --dry-run)"
contains "8a installed layout: engine found via df-mission on PATH" "--strict-mcp-config" "$OUT8"
if printf '%s' "$OUT8" | grep -q 'mcp-profile-config.py not found'; then bad "8b no refusal" "refused"; else ok "8b no refusal in the installed layout"; fi
OUT8b="$(run_dry env PATH="/usr/bin:/bin" WORKER_MCP_PROFILE=tp "$IW" dev 12345 "p" --dry-run)"
contains "8c installed layout WITHOUT df-mission on PATH still refuses (fails closed)" "mcp-profile-config.py not found" "$OUT8b"

printf 'passed %d  failed %d\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
