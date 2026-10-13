#!/usr/bin/env bash
# ensure-workspace.sh — make sure the builder's and/or the tester's workspace exists.
# The owner's rule: if it can create the workspace by itself, create it; else give the person the steps.
#
#   ensure-workspace.sh [builder|tester|both] [--yes] [--dry-run]     (default: both)
#   ensure-workspace.sh --selftest
#
# Settings (pair.yaml, read with kit/lib/pairconf.py):
#   <role>.workspace          the Coder workspace name                     (required)
#   <role>.host               `hostname` inside it — on that host the workspace obviously exists; coder is not called
#   <role>.coder_template     the Coder template to create it from         (blank = never create; print the steps)
#   <role>.coder_parameters   template parameters, a map name -> value, e.g. {namespace: jane-pay-tester-01, size: large}
#   <role>.onboarding         optional path (relative to pair.yaml, else to the kit) of an ADMIN manifest / runbook
#                             that must be applied first (e.g. namespace + home share + quota). Shown, never applied.
#   owner.coder_user          the Coder user that owns the workspace (create <user>/<workspace>)
#   owner.coder_url           the Coder URL for the `coder login` step (blank = $CODER_URL, else a placeholder)
#
# "Can create" = `coder` on PATH AND `coder whoami` succeeds AND `coder list -o json` works AND the template is in
# `coder templates list -o json`. Then: an existing workspace is reported (exit 0); a missing one is created after
# a [y/N] question (or --yes), and the script waits (bounded: ENSURE_WS_TIMEOUT s, default 900) until it is running.
# Otherwise it prints numbered steps for a person. It never runs `coder delete`, `coder ssh`, kubectl or az, never
# applies the onboarding file, and never reads or prints a token (coder's own output is not echoed).
#
# Exit: 0 every asked workspace exists (or was created and is running) · 2 steps were printed (nothing failed)
#       1 error (bad arguments, no pair.yaml, a create that failed).
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
SELF="$HERE/$(basename "$0")"
LIB="$HERE/../lib"
KIT="$(cd "$HERE/../.." && pwd)"
CODER="${ENSURE_WS_CODER:-coder}"          # the selftest points this at a name that does not exist
TIMEOUT="${ENSURE_WS_TIMEOUT:-900}"
POLL="${ENSURE_WS_POLL:-10}"

usage() { sed -n '2,6p' "$SELF" | sed 's/^# \{0,1\}//'; }

conf() { python3 "$LIB/pairconf.py" get "$1" 2>/dev/null; }

# the template parameters as "name=value" lines, from a map (or a JSON string of one, or a list of name=value)
params() {
  python3 - "$1" <<'PY'
import json, sys
raw = sys.argv[1].strip()
if not raw:
    sys.exit(0)
try:
    v = json.loads(raw)
except ValueError:
    v = raw
if isinstance(v, str):
    s = v.strip()
    try:
        v = json.loads(s) if s.startswith(("{", "[")) else [x.strip() for x in s.split(",") if x.strip()]
    except ValueError:
        sys.exit("coder_parameters is not valid JSON: give a map, e.g. {\"namespace\": \"x\", \"size\": \"large\"}")
if isinstance(v, dict):
    for k, x in v.items():
        print(f"{k}={'' if x is None else str(x).lower() if isinstance(x, bool) else x}")
elif isinstance(v, list):
    for x in v:
        if "=" not in str(x):
            sys.exit(f"coder_parameters item {x!r} is not name=value")
        print(x)
else:
    sys.exit("coder_parameters must be a map name -> value")
PY
}

# status of <workspace> (owned by <user>, when given) in `coder list -o json` on stdin: running | stopped | … | MISSING
ws_status() {
  python3 -c '
import json, sys
ws, user = sys.argv[1], sys.argv[2]
try:
    rows = json.load(sys.stdin) or []
except ValueError:
    print("ERROR"); sys.exit(0)
for r in rows:
    r = r.get("Workspace", r) if isinstance(r, dict) else {}
    if r.get("name") != ws:
        continue
    owner = r.get("owner_name") or r.get("owner") or ""
    if user and owner and owner != user:
        continue
    print((r.get("latest_build") or {}).get("status") or "unknown"); sys.exit(0)
print("MISSING")' "$1" "$2"
}

# does `coder templates list -o json` (stdin) contain <template>?
has_template() {
  python3 -c '
import json, sys
try:
    rows = json.load(sys.stdin) or []
except ValueError:
    sys.exit(1)
names = set()
for r in rows:
    if isinstance(r, dict):
        t = r.get("Template", r)
        names.add(t.get("name")); names.add(t.get("display_name"))
sys.exit(0 if sys.argv[1] in names else 1)' "$1"
}

list_ws() {  # coder list -o json, for the owner when known (default search is owner:me)
  if [ -n "$USER_C" ]; then "$CODER" list -o json --search "owner:$USER_C" 2>/dev/null
  else "$CODER" list -o json 2>/dev/null; fi
}

onboarding_path() {  # resolve <role>.onboarding: absolute, next to pair.yaml, else in the kit
  local p="$1" base
  [ -z "$p" ] && return 0
  p="${p/#\~/$HOME}"
  case "$p" in /*) echo "$p"; return 0 ;; esac
  base="$(dirname "$PAIR")"
  if [ -e "$base/$p" ]; then echo "$base/$p"; else echo "$KIT/$p"; fi
}

onboarding_text() {  # how to apply it — TEXT for the admin; this script never runs it
  local f="$1"
  case "$f" in
    *.yaml|*.yml|*.json) echo "kubectl apply -f $f        # by a cluster admin, with THEIR identity" ;;
    *.sh)                echo "bash $f        # by an admin, after reading it" ;;
    *)                   echo "follow $f        # an admin runbook" ;;
  esac
}

print_steps() {  # print_steps <role> <why>
  local role="$1" why="$2" n=1 onb
  echo "   cannot create it from here: $why"
  echo "   STEPS for a person:"
  onb="$(onboarding_path "$ONB")"
  if [ -n "$onb" ]; then
    printf '   %d. Admin onboarding first (once): %s%s\n' $n "$onb" "$([ -e "$onb" ] || echo '   (NOT FOUND — fix '"$role"'.onboarding)')"
    printf '        %s\n' "$(onboarding_text "$onb")"; n=$((n+1))
  fi
  printf '   %d. Sign in to Coder (your laptop, or a workspace — see the last step):  coder login %s\n' $n "$URL_C"; n=$((n+1))
  if [ -n "$TPL" ]; then
    printf '   %d. Create it:  %s\n' $n "$CMD_TEXT"
  else
    printf '   %d. Create it from your Coder template (none set: ./setup-pair set %s.coder_template <template>), e.g.\n' $n "$role"
    printf '        %s\n' "$CMD_TEXT"
  fi
  n=$((n+1))
  printf '   %d. Open it (Coder dashboard, or: coder ssh %s) and run:  cd %s/builder-tester-agents && ./setup --steps\n' \
    $n "$TARGET" "$ROOT"; n=$((n+1))
  printf '   %d. Then, on the BUILDER workspace (%s):  coder logout --yes        # the builder must not reach the tester\n' \
    $n "${BUILDER_WS:-builder}"
}

ensure_role() {  # -> 0 exists/created · 2 steps printed · 1 error
  local role="$1" status pl
  WS="$(conf "$role.workspace")"; HOST_R="$(conf "$role.host")"; TPL="$(conf "$role.coder_template")"
  ONB="$(conf "$role.onboarding")"
  echo
  echo "── $role workspace: ${WS:-<not set>}"
  if [ -z "$WS" ]; then
    echo "   STEPS: name it first:  ./setup-pair set $role.workspace <name>   then run this again"
    return 2
  fi
  TARGET="${USER_C:+$USER_C/}$WS"
  if [ -n "$HOST_R" ] && [ "$HOST_R" = "$THIS_HOST" ]; then
    echo "   exists — this is it (hostname $THIS_HOST = $role.host); coder not called"
    return 0
  fi
  if ! pl="$(params "$(conf "$role.coder_parameters")")"; then
    echo "   ERROR: $role.coder_parameters is not a map name -> value" >&2
    return 1
  fi
  CREATE=("$CODER" create "$TARGET" --template "${TPL:-<template>}")
  while IFS= read -r kv; do [ -n "$kv" ] && CREATE+=(--parameter "$kv"); done <<<"$pl"
  CREATE+=(--yes)
  CMD_TEXT="coder$(printf ' %q' "${CREATE[@]:1}")"
  CMD_TEXT="${CMD_TEXT//\\<template\\>/<template>}"

  # --- can this process create it?
  if ! command -v "$CODER" >/dev/null 2>&1; then print_steps "$role" "the coder CLI is not installed here"; return 2; fi
  if ! "$CODER" whoami >/dev/null 2>&1; then
    print_steps "$role" "not signed in to Coder here${IS_BUILDER:+ (this is the builder: it stays signed out)}"; return 2
  fi
  local listing
  if ! listing="$(list_ws)"; then print_steps "$role" "\`coder list\` failed (no permission to see $TARGET?)"; return 2; fi
  status="$(ws_status "$WS" "$USER_C" <<<"$listing")"
  case "$status" in
    ERROR)   print_steps "$role" "\`coder list -o json\` returned something unreadable"; return 2 ;;
    MISSING) ;;
    *)       echo "   exists — $TARGET is $status"
             [ "$status" = running ] || echo "   (not running: start it in the Coder dashboard, or: coder start $TARGET)"
             return 0 ;;
  esac
  echo "   not found in your Coder workspaces"
  [ -n "$TPL" ] || { print_steps "$role" "no $role.coder_template set"; return 2; }
  if ! "$CODER" templates list -o json 2>/dev/null | has_template "$TPL"; then
    print_steps "$role" "template '$TPL' is not in \`coder templates list\` (wrong name, or you cannot use it)"; return 2
  fi

  # --- it can: show, ask, create, wait
  local onb; onb="$(onboarding_path "$ONB")"
  if [ -n "$onb" ]; then
    echo "   NOTE: admin onboarding must be applied first: $onb$([ -e "$onb" ] || echo '  (NOT FOUND)')"
    echo "         $(onboarding_text "$onb")"
    echo "         (without it the workspace build can fail; this script never applies it)"
  fi
  echo "   will run:  $CMD_TEXT"
  if [ "$DRY" = 1 ]; then echo "   dry run: not created"; return 2; fi
  if [ "$YES" != 1 ]; then
    if [ ! -t 0 ]; then echo "   not a terminal and no --yes: not created. Run it yourself, or re-run with --yes."; return 2; fi
    read -r -p "   create it now? [y/N] " a
    case "${a,,}" in y|yes) ;; *) echo "   not created — run the command above when ready"; return 2 ;; esac
  fi
  local crc=0
  "${CREATE[@]}" >/dev/null 2>&1 || crc=$?
  if [ "$crc" != 0 ]; then
    echo "   ERROR: coder create failed (exit $crc). Check the template parameters and the admin onboarding." >&2
    print_steps "$role" "coder create failed"
    return 1
  fi
  echo "   created — waiting for it to be running (up to ${TIMEOUT}s)"
  local waited=0
  while :; do
    status="$(list_ws | ws_status "$WS" "$USER_C")"
    case "$status" in
      running) echo "   running: $TARGET"; break ;;
      failed|canceled|deleted) echo "   ERROR: the build is $status — see the build log in the Coder dashboard" >&2; return 1 ;;
    esac
    if [ "$waited" -ge "$TIMEOUT" ]; then
      echo "   still '$status' after ${TIMEOUT}s — watch it in the Coder dashboard, then do the next step"
      echo "   next, in that workspace:  cd $ROOT/builder-tester-agents && ./setup --steps"
      return 2
    fi
    sleep "$POLL"; waited=$((waited + POLL))
    [ "$POLL" -gt 0 ] || waited=$((waited + 1))
  done
  echo "   next, in that workspace:  cd $ROOT/builder-tester-agents && ./setup --steps"
  [ -n "$IS_BUILDER" ] && echo "   then HERE (the builder):  coder logout --yes        # the builder must not reach the tester"
  return 0
}

# --------------------------------------------------------------------------- selftest
selftest() {
  local T bad=0 out rc ALL=""
  T="$(mktemp -d)"
  mkdir -p "$T/bin" "$T/onboarding"
  cat >"$T/bin/coder" <<'STUB'
#!/usr/bin/env bash
# fake coder: state in $STUB_DIR; records every call; refuses anything but whoami/list/templates/create
echo "$*" >>"$STUB_DIR/calls"
logged() { [ -f "$STUB_DIR/logged_in" ]; }
case "$1" in
  whoami)    logged && { echo "authenticated, session STUB-SECRET-TOKEN-123"; exit 0; }; echo "not logged in" >&2; exit 1 ;;
  list)      logged || exit 1; cat "$STUB_DIR/workspaces.json" ;;
  templates) logged || exit 1; cat "$STUB_DIR/templates.json" ;;
  create)    logged || exit 1; printf '%s\n' "$@" >"$STUB_DIR/create_args"
             printf '[{"name": "%s", "owner_name": "%s", "latest_build": {"status": "running"}}]\n' "${2#*/}" "${2%%/*}" \
               >"$STUB_DIR/workspaces.json" ;;
  *)         echo "FORBIDDEN $*" >>"$STUB_DIR/forbidden"; exit 99 ;;
esac
STUB
  chmod +x "$T/bin/coder"
  : >"$T/onboarding/tester.yaml"
  cat >"$T/pair.yaml" <<EOF
owner: {name: Jane Doe, coder_user: jane, coder_url: "https://coder.example.com"}
builder: {name: Forge, workspace: pay-builder, host: selftest-builder-host, coder_template: k8s-dev}
tester: {name: Gauge, workspace: pay-tester, host: selftest-tester-host, coder_template: k8s-dev,
         coder_parameters: {namespace: jane-pay-tester-01, size: large}, onboarding: onboarding/tester.yaml}
paths: {shared_root: /fleet/pay}
EOF
  run() {  # run <args...> — with the stub first on PATH and a fresh call log
    : >"$T/calls"; rm -f "$T/create_args"
    out="$(PATH="$T/bin:$PATH" STUB_DIR="$T" PAIR_CONFIG="$T/pair.yaml" ENSURE_WS_POLL=0 ENSURE_WS_TIMEOUT=3 \
           bash "$SELF" "$@" </dev/null 2>&1)"; rc=$?
    ALL+="$out"$'\n'
  }
  check() {  # check <name> <condition...>
    local name="$1"; shift
    if "$@"; then echo "PASS $name"; else echo "FAIL $name"; echo "$out" | sed 's/^/     | /'; bad=$((bad+1)); fi
  }
  has() { grep -qF -- "$1" <<<"$out"; }
  no_create() { [ ! -f "$T/create_args" ] && ! grep -q '^create' "$T/calls"; }

  if [ "$(PATH="$T/bin:$PATH" command -v coder)" != "$T/bin/coder" ]; then echo "FAIL stub coder is not first on PATH"; return 1; fi
  echo '[{"name": "k8s-dev"}]' >"$T/templates.json"; echo '[]' >"$T/workspaces.json"

  rm -f "$T/logged_in"; run tester
  check "(a) not signed in: steps, exit 2" [ "$rc" = 2 ]
  check "(a) steps: onboarding, login, exact create, setup --steps, builder logout" eval \
    'has "Admin onboarding first" && has "kubectl apply -f $T/onboarding/tester.yaml" && has "coder login https://coder.example.com" &&
     has "coder create jane/pay-tester --template k8s-dev --parameter namespace=jane-pay-tester-01 --parameter size=large --yes" &&
     has "./setup --steps" && has "coder logout --yes"'
  check "(a) nothing created" no_create

  touch "$T/logged_in"
  echo '[{"name": "pay-tester", "owner_name": "jane", "latest_build": {"status": "running"}}]' >"$T/workspaces.json"
  run tester
  check "(b) signed in, workspace exists: exit 0 'exists'" eval '[ "$rc" = 0 ] && has "exists — jane/pay-tester is running"'
  check "(b) nothing created" no_create
  check "(b) listed for the owner" grep -q -- '--search owner:jane' "$T/calls"

  echo '[]' >"$T/workspaces.json"; run tester --yes
  check "(c) template present, workspace missing, --yes: exit 0" [ "$rc" = 0 ]
  check "(c) create called with the exact args" eval \
    '[ "$(tr "\n" " " <"$T/create_args")" = "create jane/pay-tester --template k8s-dev --parameter namespace=jane-pay-tester-01 --parameter size=large --yes " ]'
  check "(c) waited until running and printed the next step" eval 'has "running: jane/pay-tester" && has "cd /fleet/pay/builder-tester-agents && ./setup --steps"'

  echo '[]' >"$T/workspaces.json"; echo '[{"name": "other-template"}]' >"$T/templates.json"; run tester --yes
  check "(d) template missing: steps, exit 2" eval '[ "$rc" = 2 ] && has "template '"'"'k8s-dev'"'"' is not in" && has "STEPS for a person"'
  check "(d) nothing created" no_create

  echo '[{"Template": {"name": "k8s-dev"}}]' >"$T/templates.json"; run tester --dry-run --yes
  check "(e) --dry-run: shows the command, creates nothing, exit 2" eval '[ "$rc" = 2 ] && has "dry run: not created" && no_create'
  check "(e) wrapped template rows ({Template: {...}}) are understood" has "will run:"

  run tester
  check "(f) no terminal and no --yes: not created, exit 2" eval '[ "$rc" = 2 ] && has "no --yes" && no_create'

  ENSURE_WS_CODER=coder-not-installed-selftest; export ENSURE_WS_CODER; run tester; unset ENSURE_WS_CODER
  check "(g) no coder CLI: steps, exit 2" eval '[ "$rc" = 2 ] && has "coder CLI is not installed"'

  sed -i "s/host: selftest-builder-host/host: $(hostname)/" "$T/pair.yaml"; run builder
  check "(h) on the builder's own host: exists, coder never called" eval '[ "$rc" = 0 ] && has "this is it" && [ ! -s "$T/calls" ]'

  echo '[]' >"$T/workspaces.json"; run both
  check "(i) both: builder exists here, tester waits on a person -> exit 2" eval '[ "$rc" = 2 ] && has "── builder" && has "── tester"'

  run bogus
  check "(j) bad argument: exit 1" [ "$rc" = 1 ]

  check "never prints what coder whoami says (token canary, all runs)" eval '! grep -q STUB-SECRET-TOKEN <<<"$ALL"'
  check "never ran anything but whoami/list/templates/create" [ ! -e "$T/forbidden" ]
  rm -rf "$T"
  [ "$bad" = 0 ] && echo "ALL PASS" || echo "$bad FAILED"
  [ "$bad" = 0 ]
}

# --------------------------------------------------------------------------- main
WHICH=both; YES=0; DRY=0
for a in "$@"; do
  case "$a" in
    builder|tester|both) WHICH="$a" ;;
    --yes|-y) YES=1 ;;
    --dry-run) DRY=1 ;;
    --selftest) selftest; exit $? ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ensure-workspace: unknown argument '$a'" >&2; usage >&2; exit 1 ;;
  esac
done

PAIR="$(python3 "$LIB/pairconf.py" path 2>/dev/null)" || { echo "ensure-workspace: pair.yaml not found (run ./setup first)" >&2; exit 1; }
THIS_HOST="$(hostname)"
THIS_ROLE="$(python3 "$LIB/pairconf.py" role 2>/dev/null)"
IS_BUILDER=""; [ "$THIS_ROLE" = builder ] && IS_BUILDER=1
USER_C="$(conf owner.coder_user)"
URL_C="$(conf owner.coder_url)"; URL_C="${URL_C:-${CODER_URL:-<your Coder URL>}}"
ROOT="$(conf paths.shared_root)"; ROOT="${ROOT%/}"; ROOT="${ROOT:-<shared_root>}"
BUILDER_WS="$(conf builder.workspace)"
echo "ensure-workspace: pair.yaml $PAIR · this host is the ${THIS_ROLE:-unknown}"

case "$WHICH" in both) ROLES=(builder tester) ;; *) ROLES=("$WHICH") ;; esac
worst=0
for r in "${ROLES[@]}"; do
  ensure_role "$r"; rc=$?
  if [ "$rc" = 1 ]; then worst=1; elif [ "$rc" = 2 ] && [ "$worst" = 0 ]; then worst=2; fi
done
exit "$worst"
