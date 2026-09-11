#!/usr/bin/env bash
# test-fetch-never-prompts.sh — lock-verify L6 and rehydrate's re-fetch never wait at a prompt.
#
# ⛔ WHAT IT PROTECTS. Measured 2026-09-11 on a kit's first install: lock-verify L6 ran a plain
# `git fetch` of a PRIVATE layer on a machine where gh was logged in but git had no credential
# helper (`gh auth setup-git` never run, and the runbook never asks for it). git did not fail.
# It prompted for a password on the terminal, stderr went to /dev/null, and the install sat in
# L6 for ten minutes printing nothing. rehydrate's re-fetch of an existing vendor dir is the
# same call.
#
# Both fetches must now run with GIT_TERMINAL_PROMPT=0 (fail at once, never wait) and, where
# gh is installed, offer gh's login as a credential helper. A git shim first on PATH records
# the environment and arguments every fetch actually ran with: the prompt is the one thing a
# test cannot wait on, so the suite asserts the mechanism that removes it.
#
# Usage: bash boot-kit/scripts/tests/test-fetch-never-prompts.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
LV="${LOCK_VERIFY:-$SCRIPTS/lock-verify.sh}"
RH="${REHYDRATE:-$SCRIPTS/rehydrate.sh}"
[ -f "$LV" ] || { echo "missing $LV"; exit 2; }
[ -f "$RH" ] || { echo "missing $RH"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 2; }
REALGIT="$(command -v git)" || { echo "git required"; exit 2; }
command -v gh >/dev/null 2>&1 && HOST_HAS_GH=1 || HOST_HAS_GH=0

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in: $3" ;; esac; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fetchprompt.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
GITC=(-c user.email=test@example.com -c user.name=test)

SHIM="$TMP/shim"; mkdir -p "$SHIM"
cat > "$SHIM/git" <<EOF
#!/usr/bin/env bash
case " \$* " in
  *" fetch "*) printf 'PROMPT=[%s] ARGS=[%s]\n' "\${GIT_TERMINAL_PROMPT-<unset>}" "\$*" >> "$TMP/git.log" ;;
esac
exec "$REALGIT" "\$@"
EOF
chmod +x "$SHIM/git"

# A local bare origin, and an instance whose vendored upstream is a clone of it at its head.
"$REALGIT" init -q --bare "$TMP/origin.git"
"$REALGIT" init -q "$TMP/seed"
: > "$TMP/seed/README"
"$REALGIT" "${GITC[@]}" -C "$TMP/seed" add -A
"$REALGIT" "${GITC[@]}" -C "$TMP/seed" commit -q -m seed
"$REALGIT" -C "$TMP/seed" push -q "$TMP/origin.git" HEAD:refs/heads/main
mkinst() {  # mkinst <dir>
  mkdir -p "$1/vendor"
  "$REALGIT" clone -q "$TMP/origin.git" "$1/vendor/layer"
  local sha; sha="$("$REALGIT" -C "$1/vendor/layer" rev-parse HEAD)"
  jq -n --arg c "$sha" '{vendorDir:"vendor",
      upstreams:{layer:{repo:"acme/layer",commit:$c}},
      install:{skills:[],skillSources:{},hooks:[],hookSources:{}}}' > "$1/loom.lock.json"
  : > "$1/install.sh"
}

echo "=== F1: lock-verify L6 fetches without ever prompting ==="
mkinst "$TMP/lv"
: > "$TMP/git.log"
OUT1="$(env -u GIT_TERMINAL_PROMPT PATH="$SHIM:$PATH" bash "$LV" --lock "$TMP/lv/loom.lock.json" 2>&1)"
# A suffix, not "$TMP/...": mktemp under a TMPDIR ending in "/" yields a "//" the scripts
# never print, and a full-path match then reports a fetch that ran as one that did not.
LOG1="$(grep -F "/lv/vendor/layer " "$TMP/git.log" 2>/dev/null)"
[ -n "$LOG1" ] && ok "F1 L6 fetched the vendored layer" || bad "F1 L6 fetched the vendored layer" "no fetch recorded: $(cat "$TMP/git.log")"
contains "F1 the fetch ran with GIT_TERMINAL_PROMPT=0" "PROMPT=[0]" "$LOG1"
if [ "$HOST_HAS_GH" -eq 1 ]; then
  contains "F1 the fetch offered gh's login as a credential helper" \
    'credential.https://github.com.helper=!gh auth git-credential' "$LOG1"
else
  echo "  skip F1 gh helper: gh not installed on this host"
fi
contains "F1 L6 still verifies the pin" "L6 all 1 pin(s) reachable" "$OUT1"

echo "=== F2: rehydrate's re-fetch of an existing vendor dir never prompts ==="
mkinst "$TMP/rh"
: > "$TMP/git.log"
( cd "$TMP/rh" && env -u GIT_TERMINAL_PROMPT -u LOOM_LOCK PATH="$SHIM:$PATH" \
    LOOM_LIVE="$TMP/rh/live" LOOM_BIN="$TMP/rh/bin" bash "$RH" > "$TMP/rh.out" 2>&1 )
LOG2="$(grep -F "/rh/vendor/layer " "$TMP/git.log" 2>/dev/null)"
[ -n "$LOG2" ] && ok "F2 rehydrate re-fetched the vendored layer" || bad "F2 rehydrate re-fetched the vendored layer" "no fetch recorded: $(tail -5 "$TMP/rh.out" | tr '\n' ' ')"
contains "F2 the fetch ran with GIT_TERMINAL_PROMPT=0" "PROMPT=[0]" "$LOG2"
if [ "$HOST_HAS_GH" -eq 1 ]; then
  contains "F2 the fetch offered gh's login as a credential helper" \
    'credential.https://github.com.helper=!gh auth git-credential' "$LOG2"
fi

echo
printf 'fetch never prompts: %d ok, %d failed\n' "$PASS" "$FAIL"
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
