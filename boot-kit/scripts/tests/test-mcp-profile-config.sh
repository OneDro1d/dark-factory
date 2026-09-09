#!/usr/bin/env bash
# test-mcp-profile-config.sh — the config that gives a headless iteration its hubs back.
#
# ⛔ THE BUG THIS GUARDS. df-supervisor passes `--setting-sources project`; MCP servers live at
# USER scope in ~/.claude.json; so every worker ran with NO MCP — no tracker, no memory, no
# observability — and could not report it, because a worker with no tracker cannot write to the
# tracker. The failure is SILENT BY CONSTRUCTION, which is exactly why it needs a test and not
# a validation run: the thing that would notice is the thing that is missing.
#
# Enrolled by GLOB, per tests/README.md — a suite is enrolled by existing.
#
# Usage: bash boot-kit/scripts/tests/test-mcp-profile-config.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
GATE="${MCP_PROFILE_CONFIG:-$SCRIPTS/mcp-profile-config.py}"
[ -f "$GATE" ] || { echo "missing $GATE"; exit 2; }
command -v python3 >/dev/null || { echo "python3 required"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output" ;; esac; }
absent()   { case "$3" in *"$2"*) bad "$1" "'$2' unexpectedly present" ;; *) ok "$1" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mcpcfg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

CFG="$WORK/claude.json"
cat > "$CFG" <<'JSON'
{
  "mcpServers": {
    "onedroid":     {"url": "https://x/hub/a/mcp", "headers": {"Authorization": "Bearer LITERALTOKEN1"}},
    "onedroid-dev": {"url": "https://x/hub/b/mcp", "headers": {"Authorization": "Bearer ${DF_TEST_TOKEN_SET}"}},
    "hub-b":        {"url": "https://x/hub/c/mcp", "headers": {"Authorization": "Bearer LITERALTOKEN2"}},
    "onedroid-nx":  {"url": "https://x/hub/d/mcp", "headers": {"Authorization": "Bearer ${DF_TEST_TOKEN_UNSET}"}}
  }
}
JSON

# ---- 1. the profile's hubs, and ONLY the profile's hubs ----------------------
# Same rule as df-preflight.probe_mcp (a hub belongs to a profile when its NAME STARTS WITH the
# profile string), on purpose: a hub must not be in scope for the preflight and out of scope
# for the worker that preflight just cleared.
OUT="$(DF_TEST_TOKEN_SET=x DF_TEST_TOKEN_UNSET=y python3 "$GATE" \
        --profile onedroid --config "$CFG" --out "$WORK/out.json" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then ok "M1 exits 0 on a matching profile"; else bad "M1 exits 0" "rc=$RC"; fi
BODY="$(cat "$WORK/out.json" 2>/dev/null)"
contains "M1 the profile hub is kept"          '"onedroid"'     "$BODY"
contains "M1 the profile's dev hub is kept"    '"onedroid-dev"' "$BODY"
absent   "M1 another estate's hub is NOT kept" '"hub-b"'        "$BODY"
if printf '%s' "$BODY" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null
then ok "M1 the written config is valid JSON"; else bad "M1 valid JSON" "parse failed"; fi

# ---- 2. never print a token -------------------------------------------------
# ⚠️ This script's output is read into supervisor.log, which is committed.
absent "M2 a literal token never reaches stdout/stderr" "LITERALTOKEN1" "$OUT"

# ---- 3. the file is private -------------------------------------------------
MODE="$(python3 -c "import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777))" \
        "$WORK/out.json" 2>/dev/null)"
if [ "$MODE" = "0o600" ]; then ok "M3 the config is written 0600"
else bad "M3 the config is written 0600" "got $MODE"; fi

# ---- 4. REFUSE rather than write an empty config ----------------------------
# {"mcpServers":{}} with --strict-mcp-config is indistinguishable at runtime from the very bug
# this script exists to fix — and it would look like the fix had been applied.
python3 "$GATE" --profile nosuch --config "$CFG" --out "$WORK/none.json" >/dev/null 2>&1; RC=$?
if [ "$RC" -eq 4 ]; then ok "M4 exits 4 when no hub matches"; else bad "M4 exits 4" "rc=$RC"; fi
if [ -f "$WORK/none.json" ]; then bad "M4 nothing is written" "a file was written anyway"
else ok "M4 nothing is written"; fi

# ---- 5. the secret guard ----------------------------------------------------
# ⛔ These values are LITERAL bearer tokens on at least one machine in this estate (measured
# 2026-09-05). The natural home for a per-mission file is the mission dir; the mission dir is
# inside the notepad; the notepad is pushed every session. The obvious choice is the leaking
# one, so only a hard refusal catches it.
mkdir -p "$WORK/repo/sub"
git -c init.defaultBranch=main -C "$WORK/repo" init -q 2>/dev/null
python3 "$GATE" --profile onedroid --config "$CFG" --out "$WORK/repo/sub/out.json" \
        >/dev/null 2>&1; RC=$?
if [ "$RC" -eq 5 ]; then ok "M5 exits 5 for a path inside a git work tree"
else bad "M5 exits 5 inside a repo" "rc=$RC"; fi
if [ -f "$WORK/repo/sub/out.json" ]; then bad "M5 no token-bearing file in a repo" "written"
else ok "M5 no token-bearing file in a repo"; fi

# ---- 6. an unset token var is REPORTED, never silent ------------------------
# A hub whose var is unset is CONFIGURED AND DEAD: children boot cleanly, fail every call, and
# keep looping. That is the documented stripped-environment failure this estate already paid
# for, so it warns — and it does NOT warn about a var that is set.
ERR="$(unset DF_TEST_TOKEN_UNSET; DF_TEST_TOKEN_SET=x python3 "$GATE" \
        --profile onedroid --config "$CFG" --out "$WORK/o2.json" 2>&1 >/dev/null)"
contains "M6 the unset var is named"      "DF_TEST_TOKEN_UNSET" "$ERR"
absent   "M6 a var that IS set is quiet"  "DF_TEST_TOKEN_SET,"  "$ERR"

# ---- 7. a missing/broken config is reported, not guessed at -----------------
python3 "$GATE" --profile onedroid --config "$WORK/nope.json" --out "$WORK/o3.json" \
        >/dev/null 2>&1; RC=$?
if [ "$RC" -eq 2 ]; then ok "M7 exits 2 on an unreadable config"; else bad "M7 exits 2" "rc=$RC"; fi

echo ""
# ══ B24: mcp.profiles — a lockfile entry beats the name-prefix guess ═════════════════════
# The prefix rule above is a GUESS. When the instance lockfile DECLARES which servers serve
# an estate, that record is used instead — hubs (an exact server list) or a claude.ai
# connector (which appears in no file, so nothing is written; a PLAN line is printed instead).

# ---- 8. no entry for the profile: the OLD rule runs, plus one INFO line -----
LOCK_NOENTRY="$WORK/noentry.lock.json"
cat > "$LOCK_NOENTRY" <<'JSON'
{"mcp": {"profiles": {}}}
JSON
OUT8="$(python3 "$GATE" --profile onedroid --config "$CFG" --lock "$LOCK_NOENTRY" \
        --out "$WORK/o8.json" 2>&1)"; RC8=$?
if [ "$RC8" -eq 0 ]; then ok "L1 no mcp.profiles entry: exits 0 (prefix rule still runs)"
else bad "L1 no mcp.profiles entry: exits 0" "rc=$RC8: $OUT8"; fi
contains "L2 the INFO line names the undeclared profile" "mcp.profiles is undeclared for profile 'onedroid'" "$OUT8"
contains "L3 the INFO line is marked INFO"                "INFO"                                            "$OUT8"
BODY8="$(cat "$WORK/o8.json" 2>/dev/null)"
contains "L4 the prefix-rule hub is still kept" '"onedroid"' "$BODY8"

# ---- 9. kind hubs: EXACTLY the declared servers, not the prefix guess -------
LOCK_HUBS="$WORK/hubs.lock.json"
cat > "$LOCK_HUBS" <<'JSON'
{"mcp": {"profiles": {"onedroid": {"kind": "hubs", "servers": ["onedroid", "hub-b"]}}}}
JSON
OUT9="$(python3 "$GATE" --profile onedroid --config "$CFG" --lock "$LOCK_HUBS" \
        --out "$WORK/o9.json" 2>&1)"; RC9=$?
if [ "$RC9" -eq 0 ]; then ok "H1 hubs-from-lock exits 0"; else bad "H1 hubs-from-lock exits 0" "rc=$RC9: $OUT9"; fi
BODY9="$(cat "$WORK/o9.json" 2>/dev/null)"
contains "H2 the declared onedroid hub is kept" '"onedroid"' "$BODY9"
contains "H3 the declared hub-b IS kept (it is declared, prefix would exclude it)" '"hub-b"' "$BODY9"
absent   "H4 onedroid-dev is NOT kept (not in the declared list)" '"onedroid-dev"' "$BODY9"
absent   "H5 no INFO line when the profile IS declared" "mcp.profiles is undeclared" "$OUT9"

# ---- 10. kind hubs: a missing server exits 2, naming it, writes nothing ------
LOCK_MISSING="$WORK/missing.lock.json"
cat > "$LOCK_MISSING" <<'JSON'
{"mcp": {"profiles": {"onedroid": {"kind": "hubs", "servers": ["onedroid", "no-such-hub"]}}}}
JSON
OUT10="$(python3 "$GATE" --profile onedroid --config "$CFG" --lock "$LOCK_MISSING" \
         --out "$WORK/o10.json" 2>&1)"; RC10=$?
if [ "$RC10" -eq 2 ]; then ok "H6 a missing declared hub exits 2"; else bad "H6 a missing declared hub exits 2" "rc=$RC10"; fi
contains "H7 the refusal names the missing hub" "no-such-hub" "$OUT10"
if [ -f "$WORK/o10.json" ]; then bad "H8 nothing is written when a declared hub is missing" "a file was written anyway"
else ok "H8 nothing is written when a declared hub is missing"; fi

# ---- 11. kind connector: NO file written, a PLAN line on stdout -------------
LOCK_CONN="$WORK/connector.lock.json"
cat > "$LOCK_CONN" <<'JSON'
{"mcp": {"profiles": {"onedroid": {"kind": "connector", "servers": ["claude.ai Example"], "toolPrefix": "mcp__claude_ai_Example__"}}}}
JSON
OUT11="$(python3 "$GATE" --profile onedroid --config "$CFG" --lock "$LOCK_CONN" \
         --out "$WORK/o11.json" 2>&1)"; RC11=$?
if [ "$RC11" -eq 0 ]; then ok "C1 connector plan exits 0"; else bad "C1 connector plan exits 0" "rc=$RC11: $OUT11"; fi
if [ -f "$WORK/o11.json" ]; then bad "C2 no --mcp-config file is written for a connector" "a file was written"
else ok "C2 no --mcp-config file is written for a connector"; fi
PLAN_LINE="$(printf '%s\n' "$OUT11" | grep '^PLAN ')"
if [ -n "$PLAN_LINE" ]; then ok "C3 a PLAN line is printed"; else bad "C3 a PLAN line is printed" "none found in: $OUT11"; fi
PLAN_JSON="${PLAN_LINE#PLAN }"
if printf '%s' "$PLAN_JSON" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null
then ok "C4 the PLAN payload is valid JSON"; else bad "C4 the PLAN payload is valid JSON" "parse failed: $PLAN_JSON"; fi
PLAN_MODE="$(printf '%s' "$PLAN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("mode"))')"
[ "$PLAN_MODE" = "connector" ] && ok "C5 plan mode is connector" || bad "C5 plan mode is connector" "got '$PLAN_MODE'"
PLAN_NAME="$(printf '%s' "$PLAN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name"))')"
[ "$PLAN_NAME" = "claude.ai Example" ] && ok "C6 plan names the connector server exactly" || bad "C6 plan names the connector server exactly" "got '$PLAN_NAME'"
PLAN_PREFIX="$(printf '%s' "$PLAN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("allowPrefix"))')"
[ "$PLAN_PREFIX" = "mcp__claude_ai_Example__" ] && ok "C7 allowPrefix is sanitised exactly ('claude.ai Example' -> 'claude_ai_Example')" \
                                                 || bad "C7 allowPrefix sanitised" "got '$PLAN_PREFIX'"
DISALLOW_HAS() { printf '%s' "$PLAN_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin).get('disallow', [])
sys.exit(0 if '$1' in d else 1)
"; }
if DISALLOW_HAS "mcp__onedroid__*"; then ok "C8 disallow denies the onedroid hub"; else bad "C8 disallow denies the onedroid hub" "absent"; fi
if DISALLOW_HAS "mcp__onedroid-dev__*"; then ok "C9 disallow denies onedroid-dev (sanitised, hyphen kept)"; else bad "C9 disallow denies onedroid-dev (sanitised, hyphen kept)" "absent"; fi
if DISALLOW_HAS "mcp__hub-b__*"; then ok "C10 disallow denies hub-b (sanitised, hyphen kept)"; else bad "C10 disallow denies hub-b (sanitised, hyphen kept)" "absent"; fi
if DISALLOW_HAS "mcp__plugin_*"; then ok "C11 disallow always includes mcp__plugin_*"; else bad "C11 disallow always includes mcp__plugin_*" "absent"; fi
absent "C12 a literal token never reaches stdout for a connector plan" "LITERALTOKEN1" "$OUT11"

# ---- 12. LOOM_LOCK is honoured when --lock is absent ---------------------------
# ⛔ MEASURED 2026-09-08 ON THE ESO LAPTOP (audit B-3): with LOOM_LOCK exported and no --lock,
# this script exited 4 "mcp.profiles is undeclared" because resolve_machine_lock() looked two
# levels above the VENDORED engine and found no lockfile. df-supervisor never passed --lock, so
# every supervised mission on a vendored kit ran with NO MCP plan and said so only in a WARN.
# LOOM_LOCK is how df-preflight and df-mission are told which instance this is; it sits between
# the explicit flag and the path-derived guess. The same connector lockfile as C1, by env only.
OUT12="$(LOOM_LOCK="$LOCK_CONN" python3 "$GATE" --profile onedroid --config "$CFG" \
         --out "$WORK/o12.json" 2>&1)"; RC12=$?
if [ "$RC12" -eq 0 ]; then ok "E1 LOOM_LOCK alone resolves the record (exit 0)"; else bad "E1 LOOM_LOCK alone resolves the record" "rc=$RC12: $OUT12"; fi
contains "E2 and the plan is the connector one, not the prefix fallback" "PLAN " "$OUT12"
absent   "E3 no undeclared-profile INFO when the env names the record" "mcp.profiles is undeclared" "$OUT12"
# Explicit --lock still wins over the env: a wrong LOOM_LOCK must not override a right flag.
OUT13="$(LOOM_LOCK="$LOCK_MISSING" python3 "$GATE" --profile onedroid --config "$CFG" --lock "$LOCK_CONN" \
         --out "$WORK/o13.json" 2>&1)"; RC13=$?
if [ "$RC13" -eq 0 ]; then ok "E4 --lock outranks LOOM_LOCK"; else bad "E4 --lock outranks LOOM_LOCK" "rc=$RC13: $OUT13"; fi
contains "E5 the flag's record produced the plan" "PLAN " "$OUT13"

# ---- 14. a connector profile needs NO mcpServers -- the refusal order was wrong -----
# ⛔ MEASURED 2026-09-08 ON THE HOMELAB CODER: ~/.claude.json there holds no mcpServers (the
# connector estate's normal shape; credentials come from shared storage), and this script
# refused "no mcpServers" BEFORE reading the lockfile — so a declared `kind: connector`
# profile could never be reached, LOOM_LOCK or not, and df-worker refused to launch while
# quoting a declaration the record already carried. Servers are needed by `hubs` and by the
# prefix fallback; a connector plan is built from whatever servers exist, including none.
EMPTYCFG="$WORK/empty.json"
printf '{}\n' > "$EMPTYCFG"
OUT14="$(python3 "$GATE" --profile onedroid --config "$EMPTYCFG" --lock "$LOCK_CONN" \
         --out "$WORK/o14.json" 2>&1)"; RC14=$?
if [ "$RC14" -eq 0 ]; then ok "F1 connector + no mcpServers exits 0"; else bad "F1 connector + no mcpServers exits 0" "rc=$RC14: $OUT14"; fi
contains "F2 and prints the connector PLAN" "PLAN " "$OUT14"
absent   "F3 no 'no mcpServers' refusal for a connector" "no mcpServers" "$OUT14"
OUT15="$(python3 "$GATE" --profile onedroid --config "$EMPTYCFG" --lock "$LOCK_HUBS" \
         --out "$WORK/o15.json" 2>&1)"; RC15=$?
if [ "$RC15" -eq 3 ]; then ok "F4 hubs + no mcpServers still exits 3"; else bad "F4 hubs + no mcpServers still exits 3" "rc=$RC15: $OUT15"; fi
contains "F5 and still says why" "no mcpServers" "$OUT15"
OUT16="$(python3 "$GATE" --profile onedroid --config "$WORK/does-not-exist.json" --lock "$LOCK_CONN" \
         --out "$WORK/o16.json" 2>&1)"; RC16=$?
if [ "$RC16" -eq 0 ]; then ok "F6 connector + ABSENT config file exits 0"; else bad "F6 connector + absent config exits 0" "rc=$RC16: $OUT16"; fi
OUT17="$(python3 "$GATE" --profile onedroid --config "$WORK/does-not-exist.json" --lock "$LOCK_HUBS" \
         --out "$WORK/o17.json" 2>&1)"; RC17=$?
if [ "$RC17" -eq 2 ]; then ok "F7 hubs + absent config still exits 2 (cannot read)"; else bad "F7 hubs + absent config exits 2" "rc=$RC17: $OUT17"; fi

# ---- 15. two records claim this machine: narrow by CODER_WORKSPACE_NAME -------------
# ⛔ MEASURED 2026-09-08 ON THE HOMELAB CODER: two instance records of one kit both say
# {Linux, /home/coder} (hostname is deliberately not a key -- a Coder pod is renamed on every
# restart), so resolve_machine_lock() could not break the tie, fell to the prefix rule, and
# df-worker refused. Each record already carried install.identity.workspace, measured by
# identify.sh from CODER_WORKSPACE_NAME. Use it. Record A is a hubs profile naming a hub the
# config lacks (exit 2 if chosen); record B is the connector (PLAN if chosen) -- so which
# record won is visible in the outcome, not inferred.
ME_PLATFORM="$(python3 -c 'import platform;print(platform.system())')"
KIT2="$WORK/kit2"
mkdir -p "$KIT2/instances/a" "$KIT2/instances/b"
python3 - "$KIT2" "$ME_PLATFORM" "$HOME" <<'PY'
import json, sys
kit, plat, home = sys.argv[1:4]
a = {"machine": {"platform": plat, "home": home},
     "install": {"identity": {"workspace": "ws-a", "deploymentId": "dep-1"}},
     "mcp": {"profiles": {"onedroid": {"kind": "hubs", "servers": ["no-such-hub"]}}}}
b = {"machine": {"platform": plat, "home": home},
     "install": {"identity": {"workspace": "ws-b", "deploymentId": "dep-1"}},
     "mcp": {"profiles": {"onedroid": {"kind": "connector", "servers": ["onedroid"]}}}}
json.dump(a, open(kit + "/instances/a/loom.lock.json", "w"))
json.dump(b, open(kit + "/instances/b/loom.lock.json", "w"))
PY
OUT18="$(env -u LOOM_LOCK CODER_WORKSPACE_NAME=ws-b python3 "$GATE" --profile onedroid --config "$CFG" \
         --kit-root "$KIT2" --out "$WORK/o18.json" 2>&1)"; RC18=$?
if [ "$RC18" -eq 0 ]; then ok "G1 CODER_WORKSPACE_NAME=ws-b picks record b (exit 0)"; else bad "G1 CODER_WORKSPACE_NAME=ws-b picks record b" "rc=$RC18: $OUT18"; fi
contains "G2 and it is b's connector plan" "PLAN " "$OUT18"
OUT19="$(env -u LOOM_LOCK CODER_WORKSPACE_NAME=ws-a python3 "$GATE" --profile onedroid --config "$CFG" \
         --kit-root "$KIT2" --out "$WORK/o19.json" 2>&1)"; RC19=$?
if [ "$RC19" -eq 2 ]; then ok "G3 CODER_WORKSPACE_NAME=ws-a picks record a (its missing hub, exit 2)"; else bad "G3 ws-a picks record a" "rc=$RC19: $OUT19"; fi
contains "G4 a's refusal names a's missing hub" "no-such-hub" "$OUT19"
OUT20="$(env -u LOOM_LOCK -u CODER_WORKSPACE_NAME -u CODER_AGENT_URL python3 "$GATE" --profile onedroid --config "$CFG" \
         --kit-root "$KIT2" --out "$WORK/o20.json" 2>&1)"; RC20=$?
contains "G5 no workspace in env: the tie stays and the prefix rule says so" "mcp.profiles is undeclared" "$OUT20"
OUT21="$(env -u LOOM_LOCK CODER_WORKSPACE_NAME=ws-none python3 "$GATE" --profile onedroid --config "$CFG" \
         --kit-root "$KIT2" --out "$WORK/o21.json" 2>&1)"; RC21=$?
contains "G6 a workspace name that matches NO record learns nothing (tie stays)" "mcp.profiles is undeclared" "$OUT21"

# ---- 16. a connector plan denies the OTHER estates from the LOCKFILE, not only mcpServers ---
# ⛔ MEASURED 2026-09-08 ON THE HOMELAB CODER: ~/.claude.json there holds no mcpServers, so the
# connector plan's disallow list was [mcp__plugin_*] alone, and a headless worker scoped to the
# one estate's connector reported the other two estates' tools RESOLVABLE. Account-level
# connectors appear in no file; the other estates' names exist only in the record's own
# mcp.profiles. Estate names below are placeholders — this repo is public.
LOCK_3EST="$WORK/three-estates.lock.json"
cat > "$LOCK_3EST" <<'JSON'
{"mcp": {"profiles": {
  "onedroid":  {"kind": "connector", "servers": ["onedroid"]},
  "estate-b":  {"kind": "connector", "servers": ["claude.ai Estate B"]},
  "estate-c":  {"kind": "hubs",      "servers": ["hub-c", "hub-c-dev"]}
}}}
JSON
OUT22="$(python3 "$GATE" --profile onedroid --config "$EMPTYCFG" --lock "$LOCK_3EST" \
         --out "$WORK/o22.json" 2>&1)"; RC22=$?
if [ "$RC22" -eq 0 ]; then ok "H1 connector plan with an empty config exits 0"; else bad "H1 connector plan with an empty config exits 0" "rc=$RC22: $OUT22"; fi
# (case 17 below reuses H1's kit-less shape as its control: a lone --lock names one file, so
#  the union is that file alone and no "other record" WARN may appear -- see I6.)
PLAN_JSON="${OUT22#*PLAN }"; PLAN_JSON="${PLAN_JSON%%$'\n'*}"
if DISALLOW_HAS "mcp__claude_ai_Estate_B__*"; then ok "H2 the other CONNECTOR estate is denied (from the lockfile)"; else bad "H2 the other connector estate is denied" "absent: $PLAN_JSON"; fi
if DISALLOW_HAS "mcp__hub-c__*"; then ok "H3 the other HUBS estate is denied (from the lockfile, hyphen kept)"; else bad "H3 the other hubs estate is denied" "absent: $PLAN_JSON"; fi
if DISALLOW_HAS "mcp__hub-c-dev__*"; then ok "H4 every server of the other hubs profile is denied (hyphens kept)"; else bad "H4 every server of the other hubs profile is denied" "absent: $PLAN_JSON"; fi
if DISALLOW_HAS "mcp__onedroid__*"; then bad "H5 the worker's OWN connector is never denied" "mcp__onedroid__* in disallow"; else ok "H5 the worker's OWN connector is never denied"; fi
if DISALLOW_HAS "mcp__plugin_*"; then ok "H6 mcp__plugin_* still denied"; else bad "H6 mcp__plugin_* still denied" "absent"; fi
absent "I6 a lone --lock has no other record to learn from: no 'other record' WARN" "does not declare" "$OUT22"

# ---- 17. the deny list is the union of EVERY record in the kit, not the resolved one alone ---
# ⛔ MEASURED 2026-09-08, THIRD HOMELAB RUN: the Coder's own record declared two estates;
# the kit's ROOT record (the laptop's) also declared the third estate's connector; connectors are
# account-level so it was live on the Coder -- and a worker scoped to onedroid called the third
# estate's tools with zero denials. Case 16 above passed throughout, because it measured the
# resolved record alone. Against the previous tree I1 is green and I2, I3 are red.
# Root record: platform "NoSuchOS" so it can never resolve as THIS machine; instance record c
# matches this machine and is picked by CODER_WORKSPACE_NAME. Estate names are placeholders.
KIT3="$WORK/kit3"
mkdir -p "$KIT3/instances/c"
python3 - "$KIT3" "$ME_PLATFORM" "$HOME" <<'PY'
import json, sys
kit, plat, home = sys.argv[1:4]
root = {"machine": {"platform": "NoSuchOS", "home": "/nowhere"},
        "mcp": {"profiles": {"onedroid": {"kind": "hubs", "servers": ["onedroid", "onedroid-dev"]},
                             "estate-b": {"kind": "connector", "servers": ["claude.ai Estate B"]}}}}
c = {"machine": {"platform": plat, "home": home},
     "install": {"identity": {"workspace": "ws-c", "deploymentId": "dep-3"}},
     "mcp": {"profiles": {"onedroid": {"kind": "connector", "servers": ["onedroid"]},
                          "estate-c": {"kind": "hubs", "servers": ["hub-c"]}}}}
json.dump(root, open(kit + "/loom.lock.json", "w"))
json.dump(c, open(kit + "/instances/c/loom.lock.json", "w"))
PY
OUT23="$(env -u LOOM_LOCK CODER_WORKSPACE_NAME=ws-c python3 "$GATE" --profile onedroid --config "$EMPTYCFG" \
         --kit-root "$KIT3" --out "$WORK/o23.json" 2>&1)"; RC23=$?
if [ "$RC23" -eq 0 ]; then ok "I1 the instance record resolves and plans (exit 0)"; else bad "I1 the instance record resolves and plans" "rc=$RC23: $OUT23"; fi
PLAN_JSON="${OUT23#*PLAN }"; PLAN_JSON="${PLAN_JSON%%$'\n'*}"
if DISALLOW_HAS "mcp__hub-c__*"; then ok "I2 the resolved record's own other estate is denied (hyphen kept)"; else bad "I2 the resolved record's own other estate is denied" "absent: $PLAN_JSON"; fi
if DISALLOW_HAS "mcp__claude_ai_Estate_B__*"; then ok "I3 an estate only the ROOT record names is denied too"; else bad "I3 an estate only the ROOT record names is denied too" "absent: $PLAN_JSON"; fi
if DISALLOW_HAS "mcp__onedroid__*"; then bad "I4 the worker's own connector is never denied" "mcp__onedroid__* in disallow"; else ok "I4 the worker's own connector is never denied"; fi
if DISALLOW_HAS "mcp__onedroid-dev__*"; then bad "I5 the same PROFILE's servers in another record are not denied (same estate)" "mcp__onedroid-dev__* in disallow"; else ok "I5 the same PROFILE's servers in another record are not denied (same estate)"; fi
contains "I7 a WARN names the PROFILE the resolved record did not declare, with its servers" "does not declare estate-b (claude.ai Estate B)" "$OUT23"
contains "I8 and points at df-preflight for that profile" "df-preflight --profile estate-b" "$OUT23"
# The same kit, resolved from --lock instead of --kit-root: the union root is derived from the
# lock's own path (<kit>/instances/<n>/loom.lock.json), the way df-worker + LOOM_LOCK reach it.
OUT24="$(python3 "$GATE" --profile onedroid --config "$EMPTYCFG" --lock "$KIT3/instances/c/loom.lock.json" \
         --out "$WORK/o24.json" 2>&1)"; RC24=$?
PLAN_JSON="${OUT24#*PLAN }"; PLAN_JSON="${PLAN_JSON%%$'\n'*}"
if DISALLOW_HAS "mcp__claude_ai_Estate_B__*"; then ok "I9 --lock alone: the kit root is derived from the lock path and the union still holds"; else bad "I9 --lock alone derives the kit root" "absent: $PLAN_JSON"; fi
# A kit that names NO other estate anywhere: the plan says so, loudly, instead of a silent [plugin_*].
KIT4="$WORK/kit4"
mkdir -p "$KIT4"
printf '{"mcp": {"profiles": {"onedroid": {"kind": "connector", "servers": ["onedroid"]}}}}\n' > "$KIT4/loom.lock.json"
OUT25="$(env -u LOOM_LOCK python3 "$GATE" --profile onedroid --config "$EMPTYCFG" --kit-root "$KIT4" \
         --out "$WORK/o25.json" 2>&1)"; RC25=$?
if [ "$RC25" -eq 0 ]; then ok "I10 a single-estate kit still plans (exit 0)"; else bad "I10 a single-estate kit still plans" "rc=$RC25: $OUT25"; fi
contains "I11 and WARNs that no other estate is denied" "covers no other estate" "$OUT25"

echo ""
# ---- S1: sanitise_name -- dots and spaces fold to `_`, a hyphen survives, together ---------
# ⛔ MEASURED 2026-09-09 on two machines: the old regex ([^A-Za-z0-9]) folded EVERY
# non-alphanumeric char, hyphen included, so a hub named `onedroid-dev` was denied under a
# prefix (`mcp__onedroid_dev__*`) nothing exposes while the real `mcp__onedroid-dev__*`
# stayed reachable. One name mixing all three char classes proves the fix covers them
# together, not just the hyphen in isolation.
LOCK_S1="$WORK/s1.lock.json"
cat > "$LOCK_S1" <<'JSON'
{"mcp": {"profiles": {
  "onedroid": {"kind": "connector", "servers": ["onedroid"]},
  "estate-s": {"kind": "hubs", "servers": ["a.b c-d"]}
}}}
JSON
EMPTYCFG_S1="$WORK/empty-s1.json"
printf '{}\n' > "$EMPTYCFG_S1"
OUTS1="$(python3 "$GATE" --profile onedroid --config "$EMPTYCFG_S1" --lock "$LOCK_S1" \
         --out "$WORK/os1.json" 2>&1)"; RCS1=$?
if [ "$RCS1" -eq 0 ]; then ok "S1 sanitise_name: a mixed-char server name still plans (exit 0)"
else bad "S1 sanitise_name: a mixed-char server name still plans" "rc=$RCS1: $OUTS1"; fi
PLAN_JSON="${OUTS1#*PLAN }"; PLAN_JSON="${PLAN_JSON%%$'\n'*}"
if DISALLOW_HAS "mcp__a_b_c-d__*"; then ok "S1 'a.b c-d' sanitises to 'a_b_c-d' (dot and space fold, hyphen survives)"
else bad "S1 'a.b c-d' sanitises to 'a_b_c-d'" "absent: $PLAN_JSON"; fi

echo ""
# ══ --session-deny: every estate ANY record in the kit names, this record does not ══════
# ⛔ MEASURED 2026-09-09. A Coder workspace of one estate signed into a claude.ai account that
# also carried another estate's connector; the connector appears in NO file on the box, so a
# hand-rolled `claude -p` (not the worker path above) reached it with zero denials. This mode
# writes the SAME kind of list `other_estates()` computes for a worker, but across every
# profile the resolved record has — not scoped to one — for a session that is not either.
SD_ROOT="$WORK/sdkit"
mkdir -p "$SD_ROOT/instances/x"
cat > "$SD_ROOT/root.lock.json" <<'JSON'
{"mcp": {"profiles": {
  "a": {"kind": "hubs", "servers": ["hub-a", "hub-a-dev"]},
  "b": {"kind": "connector", "servers": ["claude.ai Estate B"]}
}}}
JSON
cat > "$SD_ROOT/instances/x/loom.lock.json" <<'JSON'
{"mcp": {"profiles": {"a": {"kind": "hubs", "servers": ["hub-a", "hub-a-dev"]}}}}
JSON

echo "=== SD1: instance x resolved -- root names an estate x does not, denied ==="
SD1OUT="$(python3 "$GATE" --session-deny "$WORK/sd1.json" --lock "$SD_ROOT/instances/x/loom.lock.json" --kit-root "$SD_ROOT" 2>&1)"; SD1RC=$?
if [ "$SD1RC" -eq 0 ]; then ok "SD1 exits 0"; else bad "SD1 exits 0" "rc=$SD1RC: $SD1OUT"; fi
SD1BODY="$(cat "$WORK/sd1.json" 2>/dev/null)"
EXPECT1='{
  "deniedMcpServers": [
    {
      "serverName": "claude.ai Estate B"
    }
  ]
}'
if [ "$SD1BODY" = "$(printf '%s\n' "$EXPECT1")" ]; then ok "SD1 writes exactly one denied server, sorted, indent=2, trailing newline"
else bad "SD1 exact file content" "got: $SD1BODY"; fi
contains "SD1 stderr names the root record as the source" "$SD_ROOT/root.lock.json" "$SD1OUT"
contains "SD1 stderr names the denied server" "claude.ai Estate B" "$SD1OUT"

echo "=== SD2: the root record itself resolved -- empty list, exit 0 ==="
SD2OUT="$(python3 "$GATE" --session-deny "$WORK/sd2.json" --lock "$SD_ROOT/root.lock.json" --kit-root "$SD_ROOT" 2>&1)"; SD2RC=$?
if [ "$SD2RC" -eq 0 ]; then ok "SD2 exits 0"; else bad "SD2 exits 0" "rc=$SD2RC: $SD2OUT"; fi
SD2BODY="$(cat "$WORK/sd2.json" 2>/dev/null)"
if python3 -c "import json,sys; d=json.load(open('$WORK/sd2.json')); sys.exit(0 if d.get('deniedMcpServers')==[] else 1)"
then ok "SD2 the list is empty"; else bad "SD2 the list is empty" "got: $SD2BODY"; fi

echo "=== SD3: no --lock, LOOM_LOCK set -- same as SD1 ==="
SD3OUT="$(env -u LOOM_LOCK LOOM_LOCK="$SD_ROOT/instances/x/loom.lock.json" python3 "$GATE" \
          --session-deny "$WORK/sd3.json" --kit-root "$SD_ROOT" 2>&1)"; SD3RC=$?
if [ "$SD3RC" -eq 0 ]; then ok "SD3 LOOM_LOCK alone: exits 0"; else bad "SD3 exits 0" "rc=$SD3RC: $SD3OUT"; fi
contains "SD3 LOOM_LOCK alone: the denied server matches SD1" '"claude.ai Estate B"' "$(cat "$WORK/sd3.json" 2>/dev/null)"

echo "=== SD4: a kit with one record only -- empty list + the WARN line ==="
SD4_ROOT="$WORK/sdsolo"
mkdir -p "$SD4_ROOT"
cp "$SD_ROOT/root.lock.json" "$SD4_ROOT/loom.lock.json"
SD4OUT="$(python3 "$GATE" --session-deny "$WORK/sd4.json" --lock "$SD4_ROOT/loom.lock.json" --kit-root "$SD4_ROOT" 2>&1)"; SD4RC=$?
if [ "$SD4RC" -eq 0 ]; then ok "SD4 exits 0"; else bad "SD4 exits 0" "rc=$SD4RC: $SD4OUT"; fi
if python3 -c "import json,sys; d=json.load(open('$WORK/sd4.json')); sys.exit(0 if d.get('deniedMcpServers')==[] else 1)"
then ok "SD4 the list is empty"; else bad "SD4 the list is empty" "got: $(cat "$WORK/sd4.json")"; fi
contains "SD4 the WARN line: no other record to compare against" "WARN no other record under" "$SD4OUT"

echo "=== SD5: neither --profile nor --session-deny -- non-zero, names both flags ==="
SD5OUT="$(python3 "$GATE" 2>&1)"; SD5RC=$?
if [ "$SD5RC" -ne 0 ]; then ok "SD5 exits non-zero"; else bad "SD5 exits non-zero" "rc=0"; fi
contains "SD5 the message names --profile" "--profile" "$SD5OUT"
contains "SD5 the message names --session-deny" "--session-deny" "$SD5OUT"

printf 'passed %d  failed %d\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
