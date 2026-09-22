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
# Engram itself — what it is and how a machine reaches it — is documented in one place:
# [Engram](../../../starter-kit/instance/AUTHENTICATION.md#engram)
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

echo "=== F: no endpoint or no token — refuse loudly, and still keep the finding ==="
OUT="$(cd "$T" && env -u DF_ENGRAM_TRANSPORT -u DF_ENGRAM_HUB -u DF_ENGRAM_SERVER "$CLI" --notepad "$NP" \
        write --title "F" --kind knowledge --collection loom-behaviors --body "x" 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "F: it refuses with nothing configured" || bad "F: refuses" "rc=$RC"
contains "F: and names what to set" "DF_ENGRAM_HUB" "$OUT"
OUT2="$(cd "$T" && env -u DF_ENGRAM_TRANSPORT -u DF_ENGRAM_TOKEN_VAR DF_ENGRAM_HUB=https://example.invalid/mcp \
        "$CLI" --notepad "$NP" write --title "F2" --kind knowledge --collection loom-behaviors --body "x" 2>&1)"
contains "F: with a hub but no token it names the token variable" "is not set" "$OUT2"

echo "=== G: ⛔ Tier 1 is PUBLIC — no estate endpoint may be hardcoded here ==="
# The first version of this file defaulted HUB to a real hub URL carrying an estate's private id.
# The publish gate's P4 caught it before merge. This keeps it caught HERE, where it is cheaper.
HITS="$(grep -nE 'https?://[a-z0-9.-]+' "$CLI" | grep -v 'example\.invalid' | grep -c . || true)"
eq "G: the source hardcodes no endpoint" "$HITS" "0"
contains "G: it resolves one from the environment instead" "DF_ENGRAM_SERVER" "$(cat "$CLI")"
FF="$(grep -l '^title: F$' "$NP"/pending-engram/*.md 2>/dev/null | head -1)"
[ -n "$FF" ] && ok "F: the finding is still QUEUED on disk — never lost to a missing token" \
             || bad "F: queued anyway" "no file"

### ---------------------------------------------------------------------------------------------
### THE GRAPH HALF. A record nobody can reach from anywhere is not memory, it is a landfill.
###
### ⛔ THIS HALF WAS NEARLY NOT BUILT, AND THE REASON IS WORTH KEEPING. On 2026-09-09 the estate
### measured the graph layer INERT: `engram_link` returned `projection: "pending"`, and 45 s later
### `engram_neighbors` and `engram_traverse` both returned `{"nodes": [], "relationships": []}`,
### while `engram_search_graph` reported `graph_available: true` with `graph_score: 0` on every hit
### — a false green. Engram `dde3d4fd`.
###
### RE-MEASURED 2026-09-22 before writing a line of this: `projection: "complete"`, the edge reads
### back from `engram_neighbors` IMMEDIATELY, `engram_traverse` returns real paths, and
### `search_graph` reports `graph_score: 0.52` with a NEW `graph_contributed: true` field — which is
### what makes the old false green falsifiable at last. The 2026-09-09 finding is STALE, not wrong:
### it was true when it was taken. THE LESSON IS THE ORDER — re-probe the layer, then build on it.
###
### These transports log every call, so the assertions below read WHAT WAS SENT to the hub, never
### what the CLI says it sent. A tool's own summary of its behaviour is not evidence of it.
### ---------------------------------------------------------------------------------------------
export DFE_LOG="$T/calls.log"
: > "$DFE_LOG"
NPA="$T/npa"; mkdir -p "$NPA"; printf '# NOTES\n' > "$NPA/NOTES.md"
printf 'Objective: prove the anchors.\n' > "$NPA/SCOPE.md"

# ⚠️ EVERY ID HERE IS DISTINCT ON PURPOSE. The first draft of this fixture handed the same id back
# for the notepad anchor AND the new record, so every edge the CLI tried was a self-edge, correctly
# refused — and three assertions failed against CORRECT code. A fixture that cannot tell two nodes
# apart cannot test a graph.
D_ID="11111111-1111-1111-1111-111111111111"   # the record a write returns
A_ID="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"   # the NOTEPAD anchor
M_ID="55555555-5555-5555-5555-555555555555"   # the MISSION anchor
V_ID="22222222-2222-2222-2222-222222222222"   # findable ONLY by the paraphrase (vector leg)
K_ID="44444444-4444-4444-4444-444444444444"   # findable ONLY by the title   (keyword leg)

# One transport for the whole graph half. It hands back a DIFFERENT neighbour per search leg, which
# is how the suite proves two searches actually ran rather than trusting that they did.
GRAPH_T="$(mk_transport graph-transport '
printf "%s %s\n" "$1" "$(tr -d "\n" < "$2")" >> "$DFE_LOG"
Q="$(cat "$2")"
case "$1" in
  *engram_write)
     case "$Q" in
       *Mission:*)  printf "{\"id\":\"55555555-5555-5555-5555-555555555555\"}\n" ;;
       *Notepad:*)  printf "{\"id\":\"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\"}\n" ;;
       *)           printf "{\"id\":\"11111111-1111-1111-1111-111111111111\"}\n" ;;
     esac ;;
  *engram_search_graph)
     printf "{\"results\":[{\"object_id\":\"66666666-6666-6666-6666-666666666666\",\"title\":\"graph neighbour\"}]}\n" ;;
  *engram_search)
     case "$Q" in
       *PARAPHRASE*) printf "{\"results\":[{\"document_id\":\"22222222-2222-2222-2222-222222222222\",\"document_title\":\"vector-leg neighbour\",\"score\":0.91}]}\n" ;;
       *)            printf "{\"results\":[{\"document_id\":\"44444444-4444-4444-4444-444444444444\",\"document_title\":\"keyword-leg neighbour\",\"score\":0.82}]}\n" ;;
     esac ;;
  *engram_link) printf "{\"status\":\"linked\",\"projection\":\"complete\"}\n" ;;
  *) printf "{}\n" ;;
esac')"

# ⚠️ These read the TRANSPORT LOG, and they match from_id and to_id by POSITION, not by "the id
# appears somewhere in the line". An earlier version grepped the line for both ids, which cannot
# distinguish a self-edge from a correct one when from_id is the same node — it reported a self-link
# that was never sent.
linked() { # linked <relation> <to_id> -> was an edge of this relation sent TO this node?
  grep "engram_link" "$DFE_LOG" 2>/dev/null | grep "\"relation\": \"$1\"" | \
    grep -q "\"to_id\": \"$2\""
}
edge() { # edge <relation> <from_id> <to_id>: the whole triple, in one logged call
  grep "engram_link" "$DFE_LOG" 2>/dev/null | grep "\"relation\": \"$1\"" | \
    grep "\"from_id\": \"$2\"" | grep -q "\"to_id\": \"$3\""
}

echo "=== H: the notepad anchor is created ONCE and its id is recorded on disk ==="
OUT="$(DF_ENGRAM_TRANSPORT="$GRAPH_T" "$CLI" --notepad "$NPA" anchor 2>&1)"; RC=$?
eq "H: exit 0" "$RC" "0"
AJ="$NPA/.df/engram-anchor.json"
[ -f "$AJ" ] && ok "H: .df/engram-anchor.json exists" || bad "H: anchor file" "missing $AJ"
contains "H: it records the notepad anchor id" "$A_ID" "$(cat "$AJ" 2>/dev/null)"
contains "H: the anchor doc is titled for the notepad" "Notepad:" "$(cat "$DFE_LOG")"
N_W="$(grep -c 'engram_write' "$DFE_LOG" || true)"
eq "H: exactly one write so far" "$N_W" "1"
OUT="$(DF_ENGRAM_TRANSPORT="$GRAPH_T" "$CLI" --notepad "$NPA" anchor 2>&1)"
N_W2="$(grep -c 'engram_write' "$DFE_LOG" || true)"
eq "H: ⛔ re-running writes NO second anchor (idempotent)" "$N_W2" "1"
contains "H: and it says the anchor is already recorded" "already" "$OUT"

echo "=== I: a mission anchor exists per mission and hangs off the notepad anchor ==="
OUT="$(DF_ENGRAM_TRANSPORT="$GRAPH_T" "$CLI" --notepad "$NPA" anchor --mission M-TEST-1 2>&1)"
contains "I: the mission anchor id is recorded under the mission" "$M_ID" "$(cat "$AJ")"
contains "I: keyed by mission id" "M-TEST-1" "$(cat "$AJ")"
edge FROM_NOTEPAD "$M_ID" "$A_ID" \
  && ok "I: FROM_NOTEPAD runs mission-anchor -> notepad-anchor" \
  || bad "I: FROM_NOTEPAD edge" "not in $DFE_LOG"

echo "=== J: ⛔ a write is WIRED IN: notepad, mission, and BOTH search legs' neighbours ==="
: > "$DFE_LOG"
OUT="$(DF_ENGRAM_TRANSPORT="$GRAPH_T" "$CLI" --notepad "$NPA" write --title "J finding" \
        --kind knowledge --collection loom-behaviors --body "the body of a durable finding" \
        --mission M-TEST-1 --relates-query "PARAPHRASE of the finding in one sentence" 2>&1)"
eq "J: exit 0" "$?" "0"
N_S="$(grep -c 'engram_search ' "$DFE_LOG" || true)"
eq "J: ⛔ TWO searches ran, not one" "$N_S" "2"
edge RECORDED_BY_NOTEPAD "$D_ID" "$A_ID" \
  && ok "J: RECORDED_BY_NOTEPAD runs record -> notepad anchor" \
  || bad "J: RECORDED_BY_NOTEPAD" "not sent"
linked FROM_MISSION "$M_ID" && ok "J: FROM_MISSION -> the mission anchor" \
                            || bad "J: FROM_MISSION" "not sent"
linked RELATES_TO "$V_ID" && ok "J: RELATES_TO the neighbour only the PARAPHRASE finds (vector leg)" \
                          || bad "J: vector-leg neighbour" "not linked"
linked RELATES_TO "$K_ID" && ok "J: RELATES_TO the neighbour only the TITLE finds (keyword leg)" \
                          || bad "J: keyword-leg neighbour" "not linked"
FJ="$(grep -l 'J finding' "$NPA"/pending-engram/*.md | head -1)"
contains "J: the queue file records what was linked" "links: " "$(cat "$FJ")"

echo "=== K: ⛔ never link a document to ITSELF ==="
# ⚠️ THE CONTROL IS THE POINT. An earlier draft of this section asserted only "no self-edge", and
# it passed against a CLI that sent no edges AT ALL — a check that cannot fail. So the fixture now
# returns the new document AND a real neighbour: the neighbour MUST be linked (proving the linking
# path ran) while the self-hit MUST NOT be.
: > "$DFE_LOG"
SELF_T="$(mk_transport self-transport '
printf "%s %s\n" "$1" "$(tr -d "\n" < "$2")" >> "$DFE_LOG"
case "$1" in
  *engram_write)  printf "{\"id\":\"11111111-1111-1111-1111-111111111111\"}\n" ;;
  *engram_search) printf "{\"results\":[{\"document_id\":\"11111111-1111-1111-1111-111111111111\",\"document_title\":\"itself\",\"score\":0.99},{\"document_id\":\"44444444-4444-4444-4444-444444444444\",\"document_title\":\"a real neighbour\",\"score\":0.80}]}\n" ;;
  *engram_link)   printf "{\"status\":\"linked\"}\n" ;;
  *) printf "{}\n" ;;
esac')"
DF_ENGRAM_TRANSPORT="$SELF_T" "$CLI" --notepad "$NPA" write --title "K finding" --kind knowledge \
  --collection loom-behaviors --body "a finding whose top hit is itself" >/dev/null 2>&1
linked RELATES_TO "$K_ID" && ok "K: CONTROL — the real neighbour in the same result set IS linked" \
                          || bad "K: control" "no edge at all was sent, so the next check is vacuous"
edge RELATES_TO "$D_ID" "$D_ID" && bad "K: self-link" "the doc was linked to itself" \
                                || ok "K: the search hit that IS the new document is skipped"

echo "=== L: ⛔ an UNPROVEN write links NOTHING, and reconcile wires it up once it learns the id ==="
: > "$DFE_LOG"
TIMEOUT_L="$(mk_transport timeout-log-transport '
printf "%s %s\n" "$1" "$(tr -d "\n" < "$2")" >> "$DFE_LOG"
case "$1" in
  *engram_write) printf "RPC request timed out\n" >&2; exit 7 ;;
  *) printf "{\"results\":[]}\n" ;;
esac')"
DF_ENGRAM_TRANSPORT="$TIMEOUT_L" "$CLI" --notepad "$NPA" write --title "L finding" --kind knowledge \
  --collection loom-behaviors --body "parked, so nothing to link to" --mission M-TEST-1 >/dev/null 2>&1
N_L="$(grep -c 'engram_link' "$DFE_LOG" || true)"
eq "L: ⛔ no link was attempted without an id" "$N_L" "0"
FL="$(grep -l 'L finding' "$NPA"/pending-engram/*.md | head -1)"
KEYL="$(sed -n 's/^key: //p' "$FL")"
: > "$DFE_LOG"
LANDED_L="$(mk_transport landed-log-transport '
printf "%s %s\n" "$1" "$(tr -d "\n" < "$2")" >> "$DFE_LOG"
case "$1" in
  *engram_search) printf "{\"results\":[{\"document_id\":\"11111111-1111-1111-1111-111111111111\",\"document_title\":\"t\",\"content\":\"ENGRAM-KEY '"$KEYL"'\"}]}\n" ;;
  *engram_link)   printf "{\"status\":\"linked\"}\n" ;;
  *) printf "{}\n" ;;
esac')"
OUT="$(DF_ENGRAM_TRANSPORT="$LANDED_L" DF_ENGRAM_MIN_AGE=0 "$CLI" --notepad "$NPA" reconcile 2>&1)"
linked RECORDED_BY_NOTEPAD "$A_ID" \
  && ok "L: reconcile links the record once the id is known" \
  || bad "L: reconcile links" "no RECORDED_BY_NOTEPAD after reconcile"
contains "L: and the queue file records it" "links: " "$(cat "$FL")"

echo "=== M: a FAILED link never un-writes the record, and never passes silently ==="
: > "$DFE_LOG"
BADLINK_T="$(mk_transport badlink-transport '
printf "%s %s\n" "$1" "$(tr -d "\n" < "$2")" >> "$DFE_LOG"
case "$1" in
  *engram_write)  printf "{\"id\":\"11111111-1111-1111-1111-111111111111\"}\n" ;;
  *engram_search) printf "{\"results\":[]}\n" ;;
  *engram_link)   printf "graph unavailable\n" >&2; exit 9 ;;
  *) printf "{}\n" ;;
esac')"
OUT="$(DF_ENGRAM_TRANSPORT="$BADLINK_T" "$CLI" --notepad "$NPA" write --title "M finding" \
        --kind knowledge --collection loom-behaviors --body "written, but the graph is down" 2>&1)"
eq "M: exit 0 — the record IS written; the graph is a second concern" "$?" "0"
FM="$(grep -l 'M finding' "$NPA"/pending-engram/*.md | head -1)"
contains "M: status stays written" "status: written" "$(cat "$FM")"
contains "M: the failure is on the record, not swallowed" "FAILED" "$(cat "$FM")"
contains "M: and it is said out loud" "link" "$OUT"

echo "=== N: recall returns ids and titles, and respects a byte budget ==="
: > "$DFE_LOG"
OUT="$(DF_ENGRAM_TRANSPORT="$GRAPH_T" "$CLI" --notepad "$NPA" recall "PARAPHRASE of a topic" 2>&1)"
contains "N: it prints a short id" "22222222" "$OUT"
contains "N: and the title next to it" "vector-leg neighbour" "$OUT"
N_SR="$(grep -c 'engram_search ' "$DFE_LOG" || true)"
eq "N: ⛔ recall also runs BOTH legs" "$N_SR" "2"
contains "N: and expands through the graph" "graph neighbour" "$OUT"
OUT="$(DF_ENGRAM_TRANSPORT="$GRAPH_T" "$CLI" --notepad "$NPA" recall "PARAPHRASE topic" --budget 80 2>&1)"
NB="$(printf '%s' "$OUT" | wc -c | tr -d ' ')"
[ "$NB" -le 80 ] && ok "N: --budget 80 is respected ($NB bytes)" \
                 || bad "N: budget" "$NB bytes > 80"

echo "=== O: ⛔ the graph claim in this file is DATED, because it was false once ==="
# ⚠️ "grep for 2026-09-22" was the first version of this and it passed on the file's UNRELATED date
# line — a date is not a claim. It must assert the SENTENCE that would have to change if the graph
# went inert again, so a future reader can see what was measured and when.
contains "O: the source dates the graph re-measurement" "re-measured 2026-09-22" "$(cat "$CLI")"
contains "O: and names the stale finding it supersedes" "dde3d4fd" "$(cat "$CLI")"
contains "O: and keeps the falsifiable field that ended the false green" "graph_contributed" "$(cat "$CLI")"

printf 'passed %s  failed %s\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %s\n' "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
