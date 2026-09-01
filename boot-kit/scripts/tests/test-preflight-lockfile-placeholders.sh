#!/usr/bin/env bash
# test-preflight-lockfile-placeholders.sh — a kit must be able to say it was never bootstrapped.
#
# WHY THIS EXISTS. The shipped ESO kit carries, measured 2026-09-01:
#     machine.platform = "Darwin"        baked in from the machine that GENERATED the kit
#     machine.home     = "__HOME_DIR__"  an unsubstituted bootstrap placeholder
#     codeRoot         = "__CODE_ROOT__" likewise
# The template's own comment says "anything still bearing one after a bootstrap is a value
# nobody supplied, and the installer says so rather than defaulting it". Nothing said so, and
# the install still reported LOCKED.
#
# ⚠️ THE OUTSIDE REPORT MISDIAGNOSED THIS AND THE CORRECTION MATTERS. It said "no tool reads
# that field today, which is the only reason it went unnoticed". A tool does read it —
# find_lock() matches candidate lockfiles on the machine block. What hides it is the
# single-candidate FAST PATH: `if len(cands) == 1` returns before the comparison, and a
# personal kit has exactly one lockfile. So the failure is LATENT, not absent. The day a kit
# gains a second instance lockfile — which is exactly what the Coder workspaces do — the
# match runs, nothing matches, and preflight cannot resolve a lockfile at all.
#
# ⚠️ THE SCAN IS NOT SCOPED TO `machine`, AND CASE B IS WHY. A first draft checked only that
# block and missed codeRoot="__CODE_ROOT__" — the worse instance, because every repo probe
# then searches a directory that does not exist and reports every repo as missing. A check
# scoped to where the bug was first noticed finds that bug and no other of the same kind.
#
# Verdict is UNKNOWN throughout, deliberately: a placeholder is not a disagreement with
# reality, it is a value nobody ever supplied.
#
# Usage: bash boot-kit/scripts/tests/test-preflight-lockfile-placeholders.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
PF="${DF_PREFLIGHT:-$SCRIPTS/df-preflight.py}"
[ -f "$PF" ] || { echo "missing $PF"; exit 2; }
command -v jq >/dev/null || { echo "jq required"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
NP="$TMP/notepad"; mkdir -p "$NP" "$TMP/code"
jq -n '{repos:[]}' > "$NP/repos.manifest.json"

ME_PLATFORM="$(python3 -c 'import platform;print(platform.system())')"
ME_HOME="$HOME"

probe() { # $1 = lock path -> writes $TMP/pf.json
  ( cd "$NP" && LOOM_LOCK="$1" python3 "$PF" --report --json "$TMP/pf.json" >/dev/null 2>&1 )
  return 0
}
det() { jq -r --arg t "$1" '.findings[]|select(.check=="lockfile" or .check=="machine")|select(.target==$t)|.detail' "$TMP/pf.json"; }
vrd() { jq -r --arg t "$1" '.findings[]|select(.check=="lockfile" or .check=="machine")|select(.target==$t)|.verdict' "$TMP/pf.json"; }

echo "=== A: a correctly bootstrapped lockfile is quiet ==="
A="$TMP/a.lock.json"
jq -n --arg p "$ME_PLATFORM" --arg h "$ME_HOME" --arg cr "$TMP/code" \
  '{codeRoot:$cr, codeLayout:{}, upstreams:{}, machine:{platform:$p, home:$h}}' > "$A"
probe "$A"
[ "$(vrd identity)" = "ok" ] && ok "A: machine identity ok" || bad "A: identity ok" "got '$(vrd identity)'"
[ -z "$(vrd placeholders)" ] && ok "A: no placeholder finding" || bad "A: no placeholder finding" "one was raised"

echo "=== B: placeholders are found OUTSIDE the machine block too ==="
B="$TMP/b.lock.json"
jq -n --arg p "$ME_PLATFORM" \
  '{codeRoot:"__CODE_ROOT__", codeLayout:{}, upstreams:{}, machine:{platform:$p, home:"__HOME_DIR__"}}' > "$B"
probe "$B"
[ "$(vrd placeholders)" = "unknown" ] && ok "B: verdict is unknown, not drift" \
                                     || bad "B: verdict unknown" "got '$(vrd placeholders)'"
case "$(det placeholders)" in *codeRoot=__CODE_ROOT__*) ok "B: catches codeRoot (outside machine)" ;;
  *) bad "B: catches codeRoot" "not named" ;; esac
case "$(det placeholders)" in *machine.home=__HOME_DIR__*) ok "B: catches machine.home" ;;
  *) bad "B: catches machine.home" "not named" ;; esac

echo "=== C: a baked platform from another machine is reported ==="
C="$TMP/c.lock.json"
OTHER=Windows; [ "$ME_PLATFORM" = "Windows" ] && OTHER=Linux
jq -n --arg p "$OTHER" --arg h "$ME_HOME" --arg cr "$TMP/code" \
  '{codeRoot:$cr, codeLayout:{}, upstreams:{}, machine:{platform:$p, home:$h}}' > "$C"
probe "$C"
[ "$(vrd identity)" = "unknown" ] && ok "C: mismatch is unknown, not drift" \
                                 || bad "C: mismatch unknown" "got '$(vrd identity)'"
case "$(det identity)" in *"$OTHER"*) ok "C: names the recorded value" ;;
  *) bad "C: names recorded value" "not named" ;; esac

echo "=== D: a lockfile with no machine block says so ==="
D="$TMP/d.lock.json"
jq -n --arg cr "$TMP/code" '{codeRoot:$cr, codeLayout:{}, upstreams:{}}' > "$D"
probe "$D"
[ "$(vrd block)" = "unknown" ] && ok "D: reported unknown" || bad "D: reported unknown" "got '$(vrd block)'"
case "$(det block)" in *"second appears"*) ok "D: says when it will start to matter" ;;
  *) bad "D: says when it matters" "no forward-looking line" ;; esac

echo ""
echo "PASS=$PASS FAIL=$FAIL"
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
