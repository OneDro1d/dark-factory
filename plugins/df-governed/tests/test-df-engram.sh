#!/usr/bin/env bash
# test-df-engram.sh — the Engram writer that survives the three fault shapes.
#
# ⛔ WHY THIS SUITE IS SHAPED AROUND FAILURE. The estate already ran this experiment by hand and
# the record is `pending-engram/README.md` in the onedroid notepad: 9 timed-out `engram_write`
# calls, of which at least 3 HAD COMMITTED; a read-back run seconds later found nothing, the write
# was retried, and duplicates were created and later deleted by hand. Measured lag between a
# timeout and the document being findable: ~60-90 s.
#
#   THE RULE THIS PINS: a timeout carries NO information either way. The tool must park the write
#   as UNPROVEN, never retry in the same run, and reconcile later by an IDEMPOTENCY KEY that is in
#   the document body — so a retry that finds its own earlier write does not write it twice.
#
# Hermetic: no network. DF_ENGRAM_TRANSPORT names a script the CLI execs instead of curl; the
# fixtures below play the hub, including the shapes that broke it for real.
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(cd "$SELF/.." && pwd)"
CLI="$PLUGIN/bin/df-engram"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output" ;; esac; }
absent()   { case "$3" in *"$2"*) bad "$1" "'$2' unexpectedly present" ;; *) ok "$1" ;; esac; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/dfengram.XXXXXX")"
trap 'rm -rf "$T"' EXIT
NP="$T/np"; mkdir -p "$NP"; printf '# NOTES\n' > "$NP/NOTES.md"

# ---- transports: each plays one hub behaviour. Called as: <transport> <tool> <json-args-file>
mk_transport() { # mk_transport <name> <body>
  local p="$T/$1"; printf '#!/usr/bin/env bash\n%s\n' "$2" > "$p"; chmod +x "$p"; printf '%s' "$p"
}
OK_T="$(mk_transport ok-transport '
case "$1" in
  *engram_write) printf "{\"id\":\"doc-111\",\"embedded_count\":1}\n" ;;
  *engram_search) printf "{\"results\":[]}\n" ;;
  *engram_link) printf "{\"status\":\"linked\"}\n" ;;
  *) printf "{}\n" ;;
esac')"
TIMEOUT_T="$(mk_transport timeout-transport '
case "$1" in
  *engram_write) printf "RPC request timed out\n" >&2; exit 7 ;;
  *engram_search) printf "{\"results\":[]}\n" ;;
  *) printf "{}\n" ;;
esac')"
# The nasty one: the write timed out but COMMITTED, so a later search finds the key.
LANDED_T="$(mk_transport landed-transport '
case "$1" in
  *engram_search) printf "{\"results\":[{\"document_id\":\"doc-222\",\"document_title\":\"t\",\"content\":\"ENGRAM-KEY REPLACEKEY\"}]}\n" ;;
  *engram_write) printf "{\"id\":\"doc-should-not-happen\"}\n" ;;
  *) printf "{}\n" ;;
esac')"

echo "=== A: present and self-describing ==="
[ -x "$CLI" ] && ok "A: bin/df-engram is executable" || bad "A: executable" "not +x"
OUT="$("$CLI" --help 2>&1)"; contains "A: --help names the queue" "pending-engram" "$OUT"

echo "=== B: the file is written BEFORE the hub call, and carries an idempotency key ==="
OUT="$(DF_ENGRAM_TRANSPORT="$OK_T" "$CLI" --notepad "$NP" write --title "B finding" --kind knowledge \
        --collection loom-behaviors --body "a durable thing worth keeping" 2>&1)"
eq "B: exit 0" "$?" "0"
F="$(ls "$NP"/pending-engram/*.md 2>/dev/null | head -1)"
[ -n "$F" ] && ok "B: a queue file exists" || bad "B: queue file" "none in $NP/pending-engram"
BODY="$(cat "$F" 2>/dev/null)"
contains "B: it carries an idempotency key" "key: " "$BODY"
contains "B: the key is also IN the document body, so search can find it" "ENGRAM-KEY" "$BODY"
contains "B: a successful write records the id" "id: doc-111" "$BODY"
contains "B: and the status" "status: written" "$BODY"

echo "=== C: ⛔ a TIMEOUT parks as UNPROVEN, never as failed, and never retries in the same run ==="
OUT="$(DF_ENGRAM_TRANSPORT="$TIMEOUT_T" "$CLI" --notepad "$NP" write --title "C finding" --kind knowledge \
        --collection loom-behaviors --body "written while the hub times out" 2>&1)"
RC=$?
eq "C: exit 0 — a parked write is not a failure of the turn" "$RC" "0"
FC="$(grep -l 'C finding' "$NP"/pending-engram/*.md | head -1)"
BODY="$(cat "$FC")"
contains "C: parked UNPROVEN" "status: UNPROVEN" "$BODY"
absent   "C: never recorded as not-written" "status: absent" "$BODY"
contains "C: the output says a timeout proves nothing" "proves nothing" "$OUT"
N_C="$(grep -l 'C finding' "$NP"/pending-engram/*.md | wc -l | tr -d ' ')"
eq "C: exactly ONE queue file for it (no retry wrote a second)" "$N_C" "1"

echo "=== D: ⛔ reconcile finds the write that DID land, and does not write it again ==="
KEY="$(sed -n 's/^key: //p' "$FC")"
sed -i.bak "s/REPLACEKEY/$KEY/" "$LANDED_T"
OUT="$(DF_ENGRAM_TRANSPORT="$LANDED_T" DF_ENGRAM_MIN_AGE=0 "$CLI" --notepad "$NP" reconcile 2>&1)"
contains "D: it reports the landed document" "doc-222" "$OUT"
BODY="$(cat "$FC")"
contains "D: the queue file records the id it found" "id: doc-222" "$BODY"
contains "D: and flips to written" "status: written" "$BODY"
absent   "D: the duplicate write never happened" "doc-should-not-happen" "$BODY"

echo "=== E: reconcile respects the indexing lag — a fresh UNPROVEN is left alone ==="
DF_ENGRAM_TRANSPORT="$TIMEOUT_T" "$CLI" --notepad "$NP" write --title "E finding" --kind knowledge \
  --collection loom-behaviors --body "just parked" >/dev/null 2>&1
OUT="$(DF_ENGRAM_TRANSPORT="$LANDED_T" "$CLI" --notepad "$NP" reconcile 2>&1)"
contains "E: it says why it waited" "too recent" "$OUT"
FE="$(grep -l 'E finding' "$NP"/pending-engram/*.md | head -1)"
contains "E: still UNPROVEN" "status: UNPROVEN" "$(cat "$FE")"

echo "=== F: no token, no silent no-op ==="
OUT="$(env -u DF_ENGRAM_TRANSPORT -u SYNAPSE_ONEDROID_PAT "$CLI" --notepad "$NP" write --title "F" \
        --kind knowledge --collection loom-behaviors --body "x" 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "F: it refuses without a token" || bad "F: refuses without a token" "rc=$RC"
contains "F: and names the variable" "SYNAPSE_ONEDROID_PAT" "$OUT"
FF="$(grep -l '^title: F$' "$NP"/pending-engram/*.md 2>/dev/null | head -1)"
[ -n "$FF" ] && ok "F: the finding is still QUEUED on disk — never lost to a missing token" \
             || bad "F: queued anyway" "no file"

printf 'passed %s  failed %s\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %s\n' "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
