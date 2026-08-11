#!/usr/bin/env bash
# run-tests.sh — discover + run every agent-notepad test, print one total summary.
#
# Discovers tests/test_*.sh (plain shell, self-tallying via assert.sh) and
# tests/test_*.py (pytest test_* functions). Runs the shell tests directly; runs
# the python tests with pytest when available, otherwise with the dependency-free
# tests/_pyrun.py fallback (bash + python3 + jq only). Aggregates case counts across
# both and prints a grand PASS/FAIL summary. Exit 0 iff everything passed.
#
# Always runs in STUB mode (no live palace, no real remote, no real ~/.claude):
#   AGENT_NOTEPAD_MEM_STUB=1   AGENT_NOTEPAD_NO_PULL=1
#   AGENT_NOTEPAD_STUB_LOG -> a throwaway sandbox file
#   AGENT_NOTEPAD_INSTALL_HOME -> a throwaway temp HOME (guards install.sh)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

SANDBOX="$(mktemp -d)"
export AGENT_NOTEPAD_MEM_STUB=1
export AGENT_NOTEPAD_NO_PULL=1
export AGENT_NOTEPAD_STUB_LOG="$SANDBOX/.stub-mem.log"
export AGENT_NOTEPAD_INSTALL_HOME="$SANDBOX/home"
mkdir -p "$AGENT_NOTEPAD_INSTALL_HOME"

echo "agent-notepad test run  (STUB mode; sandbox=$SANDBOX)"
echo "============================================================"

SH_PASS=0 SH_FAIL=0 SH_FILES=0
PY_PASS=0 PY_FAIL=0 PY_FILES=0
SUITE_FAIL=0

ESC="$(printf '\033')"
# _count <mode> <raw-output>  -> echoes "<passed> <failed>", ANSI-stripped.
# Works for either harness summary shape:
#   "<N> cases: <P> passed, <F> failed"   or   "<P> passed, <F> failed"
_count() {
  local raw clean line p f
  raw="$2"
  clean="$(printf '%s\n' "$raw" | sed "s/${ESC}\[[0-9;]*m//g")"
  line="$(printf '%s\n' "$clean" | grep -E '[0-9]+ passed' | tail -1)"
  p="$(printf '%s' "$line" | grep -oE '[0-9]+ passed' | grep -oE '^[0-9]+')"
  # sum every "<n> failed"/"<n> error" occurrence on the line
  f="$(printf '%s' "$line" | grep -oE '[0-9]+ (failed|error)' | grep -oE '^[0-9]+' | awk '{s+=$1} END{print s+0}')"
  case "$p" in ''|*[!0-9]*) p=0 ;; esac
  case "$f" in ''|*[!0-9]*) f=0 ;; esac
  printf '%s %s' "$p" "$f"
}

# --- shell tests -------------------------------------------------------------
for t in "$HERE"/test_*.sh; do
  [ -e "$t" ] || continue
  SH_FILES=$((SH_FILES + 1))
  echo
  echo "----- $(basename "$t") -----------------------------------------"
  out="$(bash "$t" 2>&1)"; rc=$?
  printf '%s\n' "$out"
  read -r p f <<<"$(_count sh "$out")"
  SH_PASS=$((SH_PASS + p)); SH_FAIL=$((SH_FAIL + f))
  [ "$rc" -ne 0 ] && SUITE_FAIL=1
done

# --- python tests ------------------------------------------------------------
PY_FILES_LIST=()
for t in "$HERE"/test_*.py; do
  [ -e "$t" ] || continue
  PY_FILES_LIST+=("$t")
done
PY_FILES=${#PY_FILES_LIST[@]}

if [ "$PY_FILES" -gt 0 ]; then
  echo
  echo "----- python tests ---------------------------------------------"
  if python3 -c "import pytest" >/dev/null 2>&1; then
    echo "(using pytest)"
    out="$(python3 -m pytest "${PY_FILES_LIST[@]}" -q 2>&1)"; rc=$?
  else
    echo "(pytest unavailable -> dependency-free _pyrun.py fallback)"
    out="$(python3 "$HERE/_pyrun.py" "${PY_FILES_LIST[@]}" 2>&1)"; rc=$?
  fi
  printf '%s\n' "$out"
  read -r p f <<<"$(_count py "$out")"
  PY_PASS=$((PY_PASS + p)); PY_FAIL=$((PY_FAIL + f))
  [ "$rc" -ne 0 ] && SUITE_FAIL=1
fi

# --- grand summary -----------------------------------------------------------
TOTAL_PASS=$((SH_PASS + PY_PASS))
TOTAL_FAIL=$((SH_FAIL + PY_FAIL))
TOTAL_FILES=$((SH_FILES + PY_FILES))

echo
echo "============================================================"
echo "TOTAL: $TOTAL_FILES test files"
echo "  shell : $SH_PASS passed, $SH_FAIL failed  ($SH_FILES files)"
echo "  python: $PY_PASS passed, $PY_FAIL failed  ($PY_FILES files)"
echo "  ------------------------------------------"
if [ "$TOTAL_FAIL" -eq 0 ] && [ "$SUITE_FAIL" -eq 0 ]; then
  echo "  RESULT: PASS  ($TOTAL_PASS passed, 0 failed)"
  rm -rf "$SANDBOX"
  exit 0
else
  echo "  RESULT: FAIL  ($TOTAL_PASS passed, $TOTAL_FAIL failed)"
  rm -rf "$SANDBOX"
  exit 1
fi
