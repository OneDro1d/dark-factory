#!/usr/bin/env bash
# mcp-register.sh — OWNER runs this (needs sudo): copy ONE named MCP server definition from the owner's own config into
# another Linux user's Claude config in this workspace (e.g. give the tester the dev hub). The definition may carry an
# auth header; it is moved file-to-file by Python and NEVER printed. Only the named server is copied.
#
#   sudo bash mcp-register.sh <target-user> <server-name> [--from <file>] [--dry-run]
#   e.g.  sudo bash mcp-register.sh wong synapse-pwwdev --from /home/coder/Code/.mcp.json
#
# Sources searched in order: --from (a .mcp.json), then the owner's ~/.claude.json (user-scope servers).
# The target's ~/.claude.json is created (mode 600, owned by the target) or merged; nothing else in it is touched.
# Prefer the target signing in itself where the server supports OAuth (`claude mcp add ...` then /mcp): then no
# credential is copied at all. Use this only when that is not possible.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
TARGET="${1:-}"; NAME="${2:-}"; shift 2 || true
FROM=""; DRY=0
while [ $# -gt 0 ]; do case "$1" in --from) FROM="${2:-}"; shift 2 ;; --dry-run) DRY=1; shift ;; *) echo "unknown: $1"; exit 2 ;; esac; done
[ -n "$TARGET" ] && [ -n "$NAME" ] || { sed -n 2,14p "$0"; exit 2; }
id "$TARGET" >/dev/null 2>&1 || { echo "no such user: $TARGET"; exit 1; }
OWNER="${SUDO_USER:-coder}"
THOME="$(getent passwd "$TARGET" | cut -d: -f6)"; OHOME="$(getent passwd "$OWNER" | cut -d: -f6)"
[ "$TARGET" != "$OWNER" ] || { echo "target is the owner itself"; exit 1; }
TARGET="$TARGET" NAME="$NAME" FROM="$FROM" DRY="$DRY" THOME="$THOME" OHOME="$OHOME" python3 -I - <<'PY'
import json, os, pathlib, pwd, sys
t, name, dry = os.environ["TARGET"], os.environ["NAME"], os.environ["DRY"] == "1"
srcs = [p for p in [os.environ["FROM"], os.environ["OHOME"] + "/.claude.json"] if p]
defn = None
for s in srcs:
    try: d = json.load(open(s))
    except Exception: continue
    if name in (d.get("mcpServers") or {}):
        defn = d["mcpServers"][name]; used = s; break
if defn is None:
    sys.exit(f"no MCP server named {name!r} in {srcs}")
dest = pathlib.Path(os.environ["THOME"]) / ".claude.json"
cur = {}
if dest.exists():
    cur = json.loads(dest.read_text() or "{}")
had = name in (cur.get("mcpServers") or {})
cur.setdefault("mcpServers", {})[name] = defn
from urllib.parse import urlsplit
_host = urlsplit(str(defn.get("url") or "")).hostname or "-"      # host only: a URL can carry a token in its path/query
print(f"{'would register' if dry else 'registering'} {name!r} ({defn.get('type')} {_host}) for {t} from {used}; "
      f"headers/credentials: {'present, copied, not shown' if defn.get('headers') else 'none'}; "
      f"{'replacing an existing entry' if had else 'new entry'}")
if dry: sys.exit(0)
dest.write_text(json.dumps(cur, indent=2) + "\n")
u = pwd.getpwnam(t); os.chown(dest, u.pw_uid, u.pw_gid); dest.chmod(0o600)
print(f"ok   {dest} (mode 600, owner {t})")
PY
