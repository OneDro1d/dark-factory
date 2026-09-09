#!/usr/bin/env bash
# test-preflight-mcp-profiles.sh — mcp.profiles-aware probing, and the connector proposal.
#
# WHY THIS EXISTS. Before B24, probe_mcp() had exactly one rule: a server belongs to a
# profile when its NAME STARTS WITH the profile string. That is a guess, not a fact. When the
# instance lockfile DECLARES `mcp.profiles.<profile>`, this file must probe THAT instead —
# a `hubs` entry via the existing tools/list mechanism, a `connector` entry via a LIVE
# `claude mcp list` (a claude.ai connector appears in no file, so tools/list has nothing to
# call). And when nothing is declared but a live connector visibly matches the profile by
# name, this file must PROPOSE the declaration — the MCP-shaped sibling of the
# self-curation proposal test-preflight-self-curation.sh already covers for uncloned repos.
#
# `claude` is stubbed via a PATH override, never the real binary on the machine running the
# suite — the same discipline test-lock-verify-l13-mcp.sh applies for the same reason.
#
# Usage: bash boot-kit/scripts/tests/test-preflight-mcp-profiles.sh
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

NOTEPAD="$TMP/notepad"; mkdir -p "$NOTEPAD"
jq -n '{repos:[]}' > "$NOTEPAD/repos.manifest.json"

CLAUDE_JSON="$TMP/claude.json"
jq -n '{mcpServers:{"onedroid":{url:"https://example-hub/a", headers:{Authorization:"Bearer LITERALTOKEN"}}}}' \
  > "$CLAUDE_JSON"

# A stub PATH carrying `claude` (the only binary these probes shell out to besides gh/az/
# kubectl, none of which these cases exercise) plus everything df-preflight itself needs.
STUBDIR="$TMP/stubbin"; mkdir -p "$STUBDIR"
for t in bash sh env jq git python3 curl; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$STUBDIR/$t"
done

report() { # $1 = lock json (jq expr), $2 = profile, $3 = claude stub script body (or "" for none)
  local LOCK="$TMP/loom.lock.json"
  jq -n "$1" > "$LOCK"
  rm -f "$STUBDIR/claude"
  if [ -n "$3" ]; then
    printf '%s' "$3" > "$STUBDIR/claude"
    chmod +x "$STUBDIR/claude"
  fi
  ( cd "$NOTEPAD" && PATH="$STUBDIR" HOME="$TMP/fake-home" \
      LOOM_LOCK="$LOCK" python3 "$PF" --report --profile "$2" --json "$TMP/pf.json" \
      >"$TMP/pf.txt" 2>&1 )
  mkdir -p "$TMP/fake-home"
  cp "$CLAUDE_JSON" "$TMP/fake-home/.claude.json"
}
# HOME must carry ~/.claude.json BEFORE the run reads it -- lay it down once, up front.
mkdir -p "$TMP/fake-home"
cp "$CLAUDE_JSON" "$TMP/fake-home/.claude.json"

CLAUDE_CONNECTED='#!/usr/bin/env bash
if [ "$1" = "mcp" ] && [ "$2" = "list" ]; then
  printf "claude.ai Example: https://example.invalid - \xe2\x9c\x94 Connected\n"
  exit 0
fi
exit 1'

CLAUDE_DISCONNECTED='#!/usr/bin/env bash
if [ "$1" = "mcp" ] && [ "$2" = "list" ]; then
  printf "claude.ai Example: https://example.invalid - Disconnected\n"
  exit 0
fi
exit 1'

echo "=== A: kind connector, Connected -> ok ==="
report '{mcp:{profiles:{eso:{kind:"connector", servers:["claude.ai Example"], toolPrefix:"mcp__claude_ai_Example__"}}}}' \
       "eso" "$CLAUDE_CONNECTED"
v="$(jq -r '.findings[]|select(.check=="mcp" and .target=="claude.ai Example")|.verdict' "$TMP/pf.json")"
[ "$v" = "ok" ] && ok "A: verdict is ok" || bad "A: verdict is ok" "got '$v'"

echo "=== B: kind connector, listed but not Connected -> drift ==="
report '{mcp:{profiles:{eso:{kind:"connector", servers:["claude.ai Example"], toolPrefix:"mcp__claude_ai_Example__"}}}}' \
       "eso" "$CLAUDE_DISCONNECTED"
v="$(jq -r '.findings[]|select(.check=="mcp" and .target=="claude.ai Example")|.verdict' "$TMP/pf.json")"
[ "$v" = "drift" ] && ok "B: verdict is drift" || bad "B: verdict is drift" "got '$v'"

echo "=== C: kind connector, claude not on PATH -> unknown, never a silent ok ==="
report '{mcp:{profiles:{eso:{kind:"connector", servers:["claude.ai Example"], toolPrefix:"mcp__claude_ai_Example__"}}}}' \
       "eso" ""
v="$(jq -r '.findings[]|select(.check=="mcp" and .target=="claude.ai Example")|.verdict' "$TMP/pf.json")"
[ "$v" = "unknown" ] && ok "C: verdict is unknown" || bad "C: verdict is unknown" "got '$v'"

echo "=== D: kind hubs, declared server present -> ok, via tools/list machinery ==="
report '{mcp:{profiles:{onedroid:{kind:"hubs", servers:["onedroid"]}}}}' "onedroid" ""
v="$(jq -r '.findings[]|select(.check=="mcp" and .target=="onedroid")|.verdict' "$TMP/pf.json")"
# The stub ~/.claude.json's hub has no reachable URL, so the tools/list call itself will not
# succeed in this sandbox -- but it MUST be attempted via the declared-hubs path, not skipped
# by the prefix rule, and it must not be reported as drift for "not present" (it IS present).
[ "$v" != "" ] && ok "D: the declared hub was probed at all (found a finding for it)" \
              || bad "D: the declared hub was probed at all" "no finding for target 'onedroid'"
d="$(jq -r '.findings[]|select(.check=="mcp" and .target=="onedroid")|.detail' "$TMP/pf.json")"
case "$d" in
  *"not present in"*) bad "D: not reported as missing from mcpServers" "$d" ;;
  *) ok "D: not reported as missing from mcpServers" ;;
esac

echo "=== E: kind hubs, declared server ABSENT from mcpServers -> drift, named ==="
report '{mcp:{profiles:{onedroid:{kind:"hubs", servers:["ghost-hub"]}}}}' "onedroid" ""
v="$(jq -r '.findings[]|select(.check=="mcp" and .target=="ghost-hub")|.verdict' "$TMP/pf.json")"
[ "$v" = "drift" ] && ok "E: verdict is drift" || bad "E: verdict is drift" "got '$v'"
d="$(jq -r '.findings[]|select(.check=="mcp" and .target=="ghost-hub")|.detail' "$TMP/pf.json")"
case "$d" in
  *"not present in"*) ok "E: says it is not present in mcpServers" ;;
  *) bad "E: says it is not present in mcpServers" "$d" ;;
esac

# The proposal is triggered by NAME CONTAINMENT (case-insensitive) between the profile and
# the live connector's name — the ticket's own measured example: profile "eso" against a
# connector literally named "claude.ai ESO".
CLAUDE_CONNECTED_ESO='#!/usr/bin/env bash
if [ "$1" = "mcp" ] && [ "$2" = "list" ]; then
  printf "claude.ai ESO: https://example.invalid - \xe2\x9c\x94 Connected\n"
  exit 0
fi
exit 1'

echo "=== F: no mcp.profiles entry, no hub matches the profile, a connector does -> PROPOSAL ==="
report '{}' "eso" "$CLAUDE_CONNECTED_ESO"
p="$(jq -r '.findings[]|select(.check=="mcp" and .target=="eso")|.proposal.path // "none"' "$TMP/pf.json")"
[ "$p" = "mcp.profiles.eso" ] && ok "F: proposes mcp.profiles.eso" || bad "F: proposes mcp.profiles.eso" "got '$p'"
pk="$(jq -r '.findings[]|select(.check=="mcp" and .target=="eso")|.proposal.value.kind // "none"' "$TMP/pf.json")"
[ "$pk" = "connector" ] && ok "F: proposal kind is connector" || bad "F: proposal kind is connector" "got '$pk'"
ps="$(jq -r '.findings[]|select(.check=="mcp" and .target=="eso")|.proposal.value.servers[0] // "none"' "$TMP/pf.json")"
[ "$ps" = "claude.ai ESO" ] && ok "F: proposal names the exact connector server" || bad "F: proposal names the exact connector server" "got '$ps'"
pt="$(jq -r '.findings[]|select(.check=="mcp" and .target=="eso")|.proposal.value.toolPrefix // "none"' "$TMP/pf.json")"
[ "$pt" = "mcp__claude_ai_ESO__" ] && ok "F: proposal toolPrefix is sanitised exactly ('claude.ai ESO' -> 'claude_ai_ESO')" \
                                   || bad "F: proposal toolPrefix is sanitised exactly" "got '$pt'"
pv="$(jq -r '.findings[]|select(.check=="mcp" and .target=="eso")|.verdict' "$TMP/pf.json")"
[ "$pv" = "drift" ] && ok "F: the proposal finding is drift, not unknown (matches every other proposal's contract)" \
                    || bad "F: proposal verdict is drift" "got '$pv'"

echo "=== G: --apply writes the confirmed proposal into mcp.profiles ==="
LOCK="$TMP/loom.lock.json"
jq '(.findings[]|select(.check=="mcp" and .target=="eso")).confirmed = true' "$TMP/pf.json" > "$TMP/confirmed.json"
LOOM_LOCK="$LOCK" python3 "$PF" --apply "$TMP/confirmed.json" >"$TMP/apply.txt" 2>&1
got_kind="$(jq -r '.mcp.profiles.eso.kind // "none"' "$LOCK")"
[ "$got_kind" = "connector" ] && ok "G: lockfile now declares mcp.profiles.eso.kind=connector" \
                              || bad "G: lockfile declares kind=connector" "got '$got_kind'"
got_srv="$(jq -r '.mcp.profiles.eso.servers[0] // "none"' "$LOCK")"
[ "$got_srv" = "claude.ai ESO" ] && ok "G: lockfile records the exact server name" \
                                 || bad "G: lockfile records the exact server name" "got '$got_srv'"
got_prefix="$(jq -r '.mcp.profiles.eso.toolPrefix // "none"' "$LOCK")"
[ "$got_prefix" = "mcp__claude_ai_ESO__" ] && ok "G: lockfile records the sanitised toolPrefix" \
                                            || bad "G: lockfile records the sanitised toolPrefix" "got '$got_prefix'"

echo "=== H: no mcp.profiles entry, no hub matches, no connector visible -> no proposal ==="
report '{}' "nosuchprofile" "$CLAUDE_CONNECTED"
n="$(jq -r '[.findings[]|select(.check=="mcp" and .target=="nosuchprofile")]|length' "$TMP/pf.json")"
[ "$n" = "0" ] && ok "H: no spurious proposal when no connector name matches" \
              || bad "H: no spurious proposal when no connector name matches" "got $n finding(s)"

# ⛔ MEASURED 2026-09-09 on two machines: the old sanitise_mcp_name regex ([^A-Za-z0-9])
# folded a hyphen the same as a dot or a space, so a hub-config server named `onedroid-dev`
# was proposed/denied under `mcp__onedroid_dev__*` -- a prefix nothing actually exposes.
# sanitise_mcp_name is a second, independent copy of mcp-profile-config.py's sanitise_name;
# both must sanitise the SAME name identically, since a proposal this file writes is what
# mcp-profile-config.py later acts on.
CLAUDE_CONNECTED_HUBC='#!/usr/bin/env bash
if [ "$1" = "mcp" ] && [ "$2" = "list" ]; then
  printf "claude.ai Hub-C: https://example.invalid - \xe2\x9c\x94 Connected\n"
  exit 0
fi
exit 1'

echo "=== S1: sanitise_mcp_name -- a hyphen in the connector name survives the proposal ==="
report '{}' "hub-c" "$CLAUDE_CONNECTED_HUBC"
pt="$(jq -r '.findings[]|select(.check=="mcp" and .target=="hub-c")|.proposal.value.toolPrefix // "none"' "$TMP/pf.json")"
[ "$pt" = "mcp__claude_ai_Hub-C__" ] && ok "S1 proposal toolPrefix keeps the hyphen ('claude.ai Hub-C' -> 'claude_ai_Hub-C')" \
                                     || bad "S1 proposal toolPrefix keeps the hyphen" "got '$pt'"

# ---------------------------------------------------------------------------
# MJ1-MJ5 -- ~/.mcp.json (or $LOOM_MCP_JSON) is a SECOND hub source, unioned with
# ~/.claude.json. MEASURED 2026-09-09: a provisioned Coder workspace declares its estate
# hubs in ~/.mcp.json with bearer tokens and has NO mcpServers in ~/.claude.json at all --
# probe_mcp used to read ~/.claude.json alone and reported that box as fully drifted.
#
# report() above always resets $TMP/fake-home/.claude.json to the shared $CLAUDE_JSON
# fixture after it runs, so these cases need their own harness: one that writes BOTH
# ~/.claude.json and (optionally) ~/.mcp.json / a $LOOM_MCP_JSON target before the probe,
# and puts the shared fixture back afterward so nothing below this section is affected.
# ---------------------------------------------------------------------------
report_mcp2() { # $1=lock jq $2=profile $3=claude.json jq $4=mcp.json jq (or "" = no file)
                # $5=optional LOOM_MCP_JSON path override (else default ~/.mcp.json)
  local LOCK="$TMP/loom.lock.json"
  jq -n "$1" > "$LOCK"
  rm -f "$STUBDIR/claude" "$TMP/fake-home/.mcp.json"
  jq -n "$3" > "$TMP/fake-home/.claude.json"
  local mcpjson_env="" mcpjson_target="${5:-}"
  if [ -n "$4" ]; then
    if [ -n "$mcpjson_target" ]; then
      jq -n "$4" > "$mcpjson_target"
      mcpjson_env="$mcpjson_target"
    else
      jq -n "$4" > "$TMP/fake-home/.mcp.json"
    fi
  fi
  ( cd "$NOTEPAD" && PATH="$STUBDIR" HOME="$TMP/fake-home" \
      LOOM_LOCK="$LOCK" LOOM_MCP_JSON="$mcpjson_env" \
      python3 "$PF" --report --profile "$2" --json "$TMP/pf.json" \
      >"$TMP/pf.txt" 2>&1 )
  cp "$CLAUDE_JSON" "$TMP/fake-home/.claude.json"
  rm -f "$TMP/fake-home/.mcp.json"
}

echo "=== MJ1: kind hubs, hubs only in ~/.mcp.json, ~/.claude.json has none -> no drift ==="
report_mcp2 '{mcp:{profiles:{a:{kind:"hubs", servers:["hub-a","hub-b"]}}}}' \
            "a" \
            '{mcpServers:{}}' \
            '{mcpServers:{"hub-a":{url:"https://example.invalid/hub-a", headers:{Authorization:"Bearer LITERALTOKEN"}},"hub-b":{url:"https://example.invalid/hub-b", headers:{Authorization:"Bearer LITERALTOKEN"}}}}'
d_all="$(jq -r '[.findings[].detail, .notes[]] | join("\n")' "$TMP/pf.json")"
case "$d_all" in
  *"not present in"*) bad "MJ1: no 'not present in' finding" "$d_all" ;;
  *) ok "MJ1: no 'not present in' finding" ;;
esac
case "$d_all" in
  *"no MCP servers configured"*) bad "MJ1: no 'no MCP servers configured' finding" "$d_all" ;;
  *) ok "MJ1: no 'no MCP servers configured' finding" ;;
esac
va="$(jq -r '.findings[]|select(.check=="mcp" and .target=="hub-a")|.verdict' "$TMP/pf.json")"
vb="$(jq -r '.findings[]|select(.check=="mcp" and .target=="hub-b")|.verdict' "$TMP/pf.json")"
[ -n "$va" ] && ok "MJ1: hub-a was probed (finding exists)" || bad "MJ1: hub-a was probed" "no finding"
[ -n "$vb" ] && ok "MJ1: hub-b was probed (finding exists)" || bad "MJ1: hub-b was probed" "no finding"

echo "=== MJ2: same, via LOOM_MCP_JSON pointing elsewhere (no ~/.mcp.json) -> same ==="
ELSEWHERE="$TMP/elsewhere-mcp.json"
report_mcp2 '{mcp:{profiles:{a:{kind:"hubs", servers:["hub-a","hub-b"]}}}}' \
            "a" \
            '{mcpServers:{}}' \
            '{mcpServers:{"hub-a":{url:"https://example.invalid/hub-a", headers:{Authorization:"Bearer LITERALTOKEN"}},"hub-b":{url:"https://example.invalid/hub-b", headers:{Authorization:"Bearer LITERALTOKEN"}}}}' \
            "$ELSEWHERE"
[ ! -f "$TMP/fake-home/.mcp.json" ] && ok "MJ2: no ~/.mcp.json was written (proves the elsewhere path was used)" \
                                     || bad "MJ2: no ~/.mcp.json was written" "it exists"
d_all="$(jq -r '[.findings[].detail, .notes[]] | join("\n")' "$TMP/pf.json")"
case "$d_all" in
  *"not present in"*) bad "MJ2: no 'not present in' finding" "$d_all" ;;
  *) ok "MJ2: no 'not present in' finding" ;;
esac
case "$d_all" in
  *"no MCP servers configured"*) bad "MJ2: no 'no MCP servers configured' finding" "$d_all" ;;
  *) ok "MJ2: no 'no MCP servers configured' finding" ;;
esac
va="$(jq -r '.findings[]|select(.check=="mcp" and .target=="hub-a")|.verdict' "$TMP/pf.json")"
vb="$(jq -r '.findings[]|select(.check=="mcp" and .target=="hub-b")|.verdict' "$TMP/pf.json")"
[ -n "$va" ] && ok "MJ2: hub-a was probed via LOOM_MCP_JSON (finding exists)" || bad "MJ2: hub-a was probed via LOOM_MCP_JSON" "no finding"
[ -n "$vb" ] && ok "MJ2: hub-b was probed via LOOM_MCP_JSON (finding exists)" || bad "MJ2: hub-b was probed via LOOM_MCP_JSON" "no finding"

echo "=== MJ3: a name in both files -> note names the collision, ~/.claude.json's entry wins ==="
report_mcp2 '{mcp:{profiles:{a:{kind:"hubs", servers:["dup-hub"]}}}}' \
            "a" \
            '{mcpServers:{"dup-hub":{url:"https://example.invalid/from-claude", headers:{Authorization:"Bearer LITERALTOKEN"}}}}' \
            '{mcpServers:{"dup-hub":{url:"https://example.invalid/from-mcpjson", headers:{Authorization:"Bearer LITERALTOKEN"}}}}'
notes_all="$(jq -r '.notes[]' "$TMP/pf.json")"
case "$notes_all" in
  *"dup-hub"*) ok "MJ3: a note names the collision" ;;
  *) bad "MJ3: a note names the collision" "$notes_all" ;;
esac
got_url="$(jq -r '.findings[]|select(.check=="mcp" and .target=="dup-hub")|.actual' "$TMP/pf.json")"
[ "$got_url" = "https://example.invalid/from-claude" ] \
  && ok "MJ3: ~/.claude.json's entry (not ~/.mcp.json's) is the one probed" \
  || bad "MJ3: ~/.claude.json's entry is the one probed" "got '$got_url'"

echo "=== MJ4: neither file has servers -> drift text names both paths ==="
report_mcp2 '{mcp:{profiles:{a:{kind:"hubs", servers:["hub-a"]}}}}' \
            "a" \
            '{mcpServers:{}}' \
            '{mcpServers:{}}'
d="$(jq -r '.findings[]|select(.check=="mcp" and .target=="mcpServers")|.detail' "$TMP/pf.json")"
case "$d" in
  *".claude.json"*".mcp.json"*) ok "MJ4: drift text names both ~/.claude.json and ~/.mcp.json" ;;
  *) bad "MJ4: drift text names both paths" "$d" ;;
esac

echo "=== MJ5: undeclared profile, hubs only in ~/.mcp.json -> name-prefix rule finds them ==="
report_mcp2 '{}' \
            "hub" \
            '{mcpServers:{}}' \
            '{mcpServers:{"hub-a":{url:"https://example.invalid/hub-a", headers:{Authorization:"Bearer LITERALTOKEN"}}}}'
v="$(jq -r '.findings[]|select(.check=="mcp" and .target=="hub-a")|.verdict' "$TMP/pf.json")"
[ -n "$v" ] && ok "MJ5: name-prefix rule found hub-a via ~/.mcp.json" || bad "MJ5: name-prefix rule found hub-a" "no finding"
d_all="$(jq -r '[.findings[].detail, .notes[]] | join("\n")' "$TMP/pf.json")"
case "$d_all" in
  *"no MCP servers configured"*) bad "MJ5: no 'no MCP servers configured' finding" "$d_all" ;;
  *) ok "MJ5: no 'no MCP servers configured' finding" ;;
esac

echo ""
echo "PASS=$PASS FAIL=$FAIL"
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
