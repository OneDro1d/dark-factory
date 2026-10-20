#!/usr/bin/env bash
# agent-home.sh — optional per-agent HOME, so several pairs (or several agents) can share ONE workspace.
#
# Set `<role>.agent_home: /some/dir` in pair.yaml (builder.agent_home / tester.agent_home). Everything the kit
# installs or keeps per workspace lives under $HOME (~/.claude hooks + settings, the chat-listener state, the
# config pointer, ~/.cache, ~/.kube, the hub login), so an agent started with its own HOME is fully isolated from
# every other agent in the same workspace: no shared hooks, no shared listener lock, no shared watchdog files.
#
#   bash agent-home.sh init  [--dry-run]    create the folder and link the sign-ins it must share (see below)
#   bash agent-home.sh path                 print the folder ("" when agent_home is not set)
#   bash agent-home.sh env                  print `HOME=… PAIR_CONFIG=…` for a command prefix
#
# Shared by link, never copied: the Claude sign-in (.claude.json, .claude/.credentials.json), the GitHub CLI login
# and the git identity — the same person owns every agent in the workspace. NOT shared: hooks, settings.json,
# skills, agents, listener state, the kubeconfig, MCP hub logins. Those are per agent on purpose.
set -euo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REAL_HOME="$(getent passwd "$(id -un)" | cut -d: -f6)"
PC() { HOME="$REAL_HOME" python3 "$KIT/kit/lib/pairconf.py" "$@"; }
ROLE="$(PC role)"
case "$ROLE" in builder|tester) ;; *) echo "this host ($(hostname)) is neither builder.host nor tester.host in $(PC path)"; exit 1 ;; esac
AH="$(PC get "$ROLE.agent_home" 2>/dev/null || true)"
AH="${AH/#\~/$REAL_HOME}"
CFG="$(PC path)"

case "${1:-path}" in
  path) echo "$AH" ;;
  env)  echo "HOME=${AH:-$REAL_HOME} PAIR_CONFIG=$CFG" ;;
  init)
    DRY=0; [ "${2:-}" = "--dry-run" ] && DRY=1
    [ -n "$AH" ] || { echo "$ROLE.agent_home is not set in $CFG — this agent uses the workspace home; nothing to do."; exit 0; }
    case "$AH" in /*) ;; *) echo "$ROLE.agent_home must be an absolute path (got '$AH')"; exit 1 ;; esac
    [ "$AH" != "$REAL_HOME" ] || { echo "$ROLE.agent_home is the real home — nothing to isolate"; exit 0; }
    run() { if [ "$DRY" = 1 ]; then echo "[dry-run] $*"; else "$@"; fi; }
    run mkdir -p "$AH" "$AH/.claude" "$AH/.config" "$AH/.cache" "$AH/.kube"
    run chmod 700 "$AH"
    link() {   # link <path relative to home>: only when the real one exists and ours does not
      local rel="$1"
      [ -e "$REAL_HOME/$rel" ] || { echo "skip  $rel (not present in $REAL_HOME — sign in there first if this agent needs it)"; return 0; }
      [ -e "$AH/$rel" ] || [ -L "$AH/$rel" ] && { echo "keep  $rel"; return 0; }
      run mkdir -p "$(dirname "$AH/$rel")"
      run ln -s "$REAL_HOME/$rel" "$AH/$rel"; echo "link  $rel"
    }
    # MCP servers: when `<role>.mcp_servers` is set, this agent gets its OWN .claude.json holding ONLY those servers,
    # copied from the owner's definitions (user-scope ~/.claude.json, plus every file in `<role>.mcp_from`, e.g. a
    # project .mcp.json). Nothing else is copied — so a server that must stay out of reach (e.g. a production hub) never
    # reaches this agent. Without it, the owner's whole .claude.json is linked as before.
    MCPS="$(PC get "$ROLE.mcp_servers" 2>/dev/null || true)"
    if [ -n "$MCPS" ] && [ "$MCPS" != "[]" ]; then
      if [ "$DRY" = 1 ]; then echo "[dry-run] build $AH/.claude.json with only: $MCPS"; else
      REAL_HOME="$REAL_HOME" AH="$AH" KIT="$KIT" ROLE="$ROLE" python3 - <<'PY'
import json, os, pathlib, sys
sys.path.insert(0, os.environ["KIT"] + "/kit/lib")
import pairconf
cfg = pairconf.load(); role = os.environ["ROLE"]
want = pairconf.get(cfg, f"{role}.mcp_servers", []) or []
deny = [str(x) for x in (pairconf.get(cfg, "guard.deny_mcp", []) or [])]
srcs = [pathlib.Path(os.environ["REAL_HOME"]) / ".claude.json"] + [pathlib.Path(os.path.expanduser(p)) for p in (pairconf.get(cfg, f"{role}.mcp_from", []) or [])]
found = {}
for s in srcs:
    try: d = json.loads(s.read_text())
    except Exception: continue
    for n, v in (d.get("mcpServers") or {}).items():
        found.setdefault(n, v)
bad = [n for n in want if n in deny]
if bad: sys.exit(f"{role}.mcp_servers lists {bad}, which guard.deny_mcp forbids")
missing = [n for n in want if n not in found]
if missing: sys.exit(f"{role}.mcp_servers: no definition found for {missing} (looked in {[str(s) for s in srcs]})")
real = {}
try: real = json.loads((pathlib.Path(os.environ["REAL_HOME"]) / ".claude.json").read_text())
except Exception: pass
keep = ("hasCompletedOnboarding", "lastOnboardingVersion", "installMethod", "oauthAccount", "userID", "machineID", "firstStartTime", "migrationVersion")
out = {k: real[k] for k in keep if k in real}
out["mcpServers"] = {n: found[n] for n in want}
dest = pathlib.Path(os.environ["AH"]) / ".claude.json"
if dest.is_symlink(): dest.unlink()      # an earlier init linked the owner's whole file: replace it
dest.write_text(json.dumps(out, indent=2) + "\n"); dest.chmod(0o600)
print(f"built {dest}: MCP servers = {', '.join(want)} (definitions copied, mode 600; nothing else from the owner's config)")
PY
      fi
    else
      link .claude.json
    fi
    link .claude/.credentials.json
    link .config/gh
    link .gitconfig
    echo "agent home ready: $AH   (start with: bash $KIT/kit/scripts/start-agent.sh)"
    ;;
  *) echo "usage: agent-home.sh init [--dry-run] | path | env"; exit 2 ;;
esac
