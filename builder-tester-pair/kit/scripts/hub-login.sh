#!/usr/bin/env bash
# hub-login.sh — the OWNER runs this in each agent's workspace terminal (not an agent) to give THAT workspace's
# agent its OWN MCP hub login (Teams / Jira / Slack / Engram through one hub client). Nothing is copied from the
# other workspace: each workspace signs in separately, so each agent's token lives only in its own home.
#
#   bash kit/scripts/hub-login.sh            # register the MCP server, device-code sign-in, check the login is saved
#   bash kit/scripts/hub-login.sh --check    # only check that a saved login exists (never prints it)
#   bash kit/scripts/hub-login.sh --dry-run  # print the commands, run nothing
#
# Settings (pair.yaml, block `hub:`):
#   server_name   MCP server name as Claude shows it (tools become mcp__<server_name>__*)
#   url           hub URL; also passed to the client in the <url_env> variable (the client may otherwise
#                 default to another host and sign in to nothing)
#   client_bin    path to the hub client binary (e.g. on the shared disk)
#   client_args   list; arguments for the MCP proxy run ("{url}" is replaced by `url`)
#   url_env       environment variable the client reads the URL from (e.g. TRILIX_SERVER_URL)
#   home_dir      isolated HOME for the client, where its login is kept (default ~/.<server_name>-home)
#   login_args    list; the sign-in command (default ["login", "--device"] — device code, no local browser needed)
#   login_check   path inside home_dir of the saved login, checked for presence only (e.g. .<client>/config.json)
#
# Refuses to run unless this host is builder.host or tester.host (decided by `hostname`, not an env var).
set -euo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE=run
case "${1:-}" in
  "") ;;
  --check) MODE=check ;;
  --dry-run|-n) MODE=dry ;;
  -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
  *) echo "unknown argument: $1" >&2; exit 2 ;;
esac

# Settings → shell variables. Every value is shlex-quoted by Python, so a value cannot inject a command.
eval "$(python3 - "$KIT" <<'PY'
import os, shlex, sys
sys.path.insert(0, sys.argv[1] + "/kit/lib")
import pairconf
cfg = pairconf.load()
g = lambda k, d=None: pairconf.get(cfg, k, d)
server = str(g("hub.server_name") or "")
url = str(g("hub.url") or "")
def lst(v, d):
    if v in (None, "", []):
        v = d
    if isinstance(v, str):
        v = v.split()
    return [str(x).replace("{url}", url) for x in v]
home = os.path.expanduser(str(g("hub.home_dir") or (f"~/.{server}-home" if server else "")))
out = {
    "ROLE": pairconf.role(cfg),
    "SERVER": server, "URL": url,
    "BIN": os.path.expanduser(str(g("hub.client_bin") or "")),
    "URL_ENV": str(g("hub.url_env") or ""),
    "HUB_HOME": home,
    "LOGIN_CHECK": str(g("hub.login_check") or ""),
    "CFG_PATH": cfg["_path"],
}
for k, v in out.items():
    print(f"{k}={shlex.quote(v)}")
print("CLIENT_ARGS=(" + " ".join(shlex.quote(a) for a in lst(g("hub.client_args"), [])) + ")")
print("LOGIN_ARGS=(" + " ".join(shlex.quote(a) for a in lst(g("hub.login_args"), ["login", "--device"])) + ")")
PY
)"

die() { echo "hub-login: $*" >&2; exit 1; }
[ "$ROLE" = builder ] || [ "$ROLE" = tester ] || \
  die "this host ($(hostname)) is neither builder.host nor tester.host in $CFG_PATH — run it in an agent's workspace"
[ -n "$SERVER" ] || die "hub.server_name is not set in $CFG_PATH"
[ -n "$URL" ]    || die "hub.url is not set in $CFG_PATH"
[ -n "$BIN" ]    || die "hub.client_bin is not set in $CFG_PATH"
[ -n "$URL_ENV" ] && { [[ "$URL_ENV" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "hub.url_env is not a variable name: $URL_ENV"; }
case "$HUB_HOME" in "$HOME"|"$HOME/"|/|"") die "hub.home_dir must be its own folder, not your home ($HUB_HOME)";; esac

ENVS=(-e "HOME=$HUB_HOME"); RUNENV=("HOME=$HUB_HOME")
[ -n "$URL_ENV" ] && { ENVS+=(-e "$URL_ENV=$URL"); RUNENV+=("$URL_ENV=$URL"); }

saved() {  # presence only: the file exists and is not empty. Its content is never read or printed.
  [ -n "$LOGIN_CHECK" ] || { echo "  (hub.login_check not set — cannot confirm the login was saved)"; return 2; }
  if [ -s "$HUB_HOME/$LOGIN_CHECK" ]; then echo "  login saved: $HUB_HOME/$LOGIN_CHECK exists (content not shown)"; return 0; fi
  echo "  no login saved at $HUB_HOME/$LOGIN_CHECK"; return 1
}
show() { printf '  $'; printf ' %q' "$@"; printf '\n'; }

echo "hub-login: $ROLE workspace ($(hostname)), server '$SERVER' → $URL"
if [ "$MODE" = check ]; then saved; exit $?; fi
[ "$MODE" = dry ] || [ -x "$BIN" ] || die "hub client not found or not executable: $BIN (hub.client_bin)"
command -v claude >/dev/null 2>&1 || [ "$MODE" = dry ] || die "claude CLI not on PATH"

# The server name goes BEFORE the -e flags: `-e` takes several values and would swallow the name otherwise.
ADD=(claude mcp add -s user "$SERVER" "${ENVS[@]}" -- "$BIN" "${CLIENT_ARGS[@]}")
LOGIN=(env "${RUNENV[@]}" "$BIN" "${LOGIN_ARGS[@]}")

if [ "$MODE" = dry ]; then
  echo "would run:"
  show mkdir -p "$HUB_HOME"; show chmod 700 "$HUB_HOME"
  show claude mcp remove -s user "$SERVER"
  show "${ADD[@]}"
  show "${LOGIN[@]}"
  echo "  then check (presence only): ${LOGIN_CHECK:+$HUB_HOME/$LOGIN_CHECK}"
  echo "undo: claude mcp remove -s user $(printf %q "$SERVER") ; rm -rf $(printf %q "$HUB_HOME")"
  exit 0
fi

echo "1/3 register the MCP server for this workspace's agent (its own isolated home: $HUB_HOME)"
mkdir -p "$HUB_HOME"; chmod 700 "$HUB_HOME"
claude mcp remove -s user "$SERVER" >/dev/null 2>&1 || true
"${ADD[@]}"

echo
echo "2/3 sign in (device code — open the link it prints on your laptop, enter the code, sign in as yourself)"
"${LOGIN[@]}"

echo
echo "3/3 check the login was saved"
if saved; then echo "done — restart Claude in this workspace so the agent picks up '$SERVER'."
else echo "sign-in did not save a login — re-run, or check the client's output above"; fi
echo "undo: claude mcp remove -s user $(printf %q "$SERVER") ; rm -rf $(printf %q "$HUB_HOME")"
