#!/usr/bin/env bash
# restore-home.sh — put back the parts of a rebuilt workspace's HOME that are NOT secrets and that the kit's install
# does not already recreate: the agent's auto-memory and the helper binaries. Run in the agent's workspace.
#
#   bash kit/scripts/restore-home.sh            # restore this role's memory snapshot + binaries (never overwrites)
#   bash kit/scripts/restore-home.sh --save     # refresh this role's memory snapshot from ~/.claude (before a rebuild)
#   bash kit/scripts/restore-home.sh --dry-run  # print what it would copy
#
# Settings (pair.yaml, block `restore:`, all optional):
#   memory_snapshot: {builder: <dir>, tester: <dir>}   per-role snapshot folder on the shared disk
#   bins: [{name: <file in ~/.local/bin>, from: <path on the shared disk>}]
#
# It handles NO secrets, on purpose: logins, tokens and kubeconfigs are re-created by sign-in steps (docs/SETUP.md
# "A brand-new or rebuilt workspace"). Only *.md memory notes are copied, and only when their TEXT does not look like a
# secret (kit/bin/textguard.py, both on --save and on restore; names are not judged — a note about secrets is fine).
# A binary whose name looks like a credential file is skipped. Claude's memory folder is keyed by the folder
# Claude starts in (paths.shared_root), so the slug is derived from it — a folder under the wrong slug is never loaded.
set -euo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE=restore
case "${1:-}" in
  "") ;;
  --save) MODE=save ;;
  --dry-run|-n) MODE=dry ;;
  -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
  *) echo "unknown argument: $1" >&2; exit 2 ;;
esac

exec python3 - "$KIT" "$MODE" <<'PY'
import os, pathlib, re, shutil, sys
kit, mode = sys.argv[1], sys.argv[2]
sys.path.insert(0, kit + "/kit/lib"); sys.path.insert(0, kit + "/kit/bin")
import pairconf, textguard
cfg = pairconf.load()
g = lambda k, d=None: pairconf.get(cfg, k, d)
role = pairconf.role(cfg)
if role not in ("builder", "tester"):
    sys.exit(f"restore-home: this host is neither builder.host nor tester.host in {cfg['_path']}")
root = str(g("paths.shared_root") or "")
if not root:
    sys.exit("restore-home: paths.shared_root is not set")
slug = re.sub(r"[^A-Za-z0-9]", "-", os.path.abspath(os.path.expanduser(root)))
memdir = pathlib.Path.home() / ".claude" / "projects" / slug / "memory"
snap = (g("restore.memory_snapshot") or {}).get(role) if isinstance(g("restore.memory_snapshot"), dict) else None
snap = pathlib.Path(os.path.expanduser(snap)) if snap else None
CRED = re.compile(r"(^|[._-])(token|tokens|secret|secrets|credential|credentials|password|passwd|kubeconfig|vault)"
                  r"([._-]|$)|\.(env|pem|key|p12|pfx|conf)$|^\.?(netrc|npmrc|pgpass)$|^id_(rsa|ed25519|ecdsa)", re.I)
dry = mode == "dry"
print(f"restore-home: {role} on this host; memory folder {memdir}")

if mode == "save":
    if not snap:
        sys.exit(f"restore-home: restore.memory_snapshot.{role} is not set")
    if not memdir.is_dir():
        sys.exit(f"restore-home: no memory folder at {memdir}")
    snap.mkdir(parents=True, exist_ok=True)
    n = skipped = 0
    for f in sorted(memdir.glob("*.md")):
        if textguard.bad(f.read_text(errors="replace")):   # content check: a note ABOUT secrets is fine, a secret is not
            print(f"  REFUSED {f.name}: its text looks like a secret — fix the file, then save again"); skipped += 1
            continue
        shutil.copy2(f, snap / f.name); n += 1
    print(f"  saved {n} memory files to {snap}" + (f"; {skipped} refused" if skipped else ""))
    sys.exit(1 if skipped else 0)

# restore: memory (never overwrites a file that already exists)
if snap and snap.is_dir():
    n = 0
    for f in sorted(snap.glob("*.md")):
        if textguard.bad(f.read_text(errors="replace")):   # content check: a note ABOUT secrets is fine, a secret is not
            print(f"  REFUSED {f.name}: its text looks like a secret — not restored"); continue
        dest = memdir / f.name
        if dest.exists():
            continue
        if dry:
            print(f"  would copy {f} -> {dest}")
        else:
            memdir.mkdir(parents=True, exist_ok=True); shutil.copy2(f, dest)
        n += 1
    print(f"  memory: {n} file(s) {'to restore' if dry else 'restored'} from {snap} (existing files kept)")
elif snap:
    print(f"  memory: no snapshot at {snap} — this agent starts with empty auto-memory")
else:
    print(f"  memory: restore.memory_snapshot.{role} not set — skipped")

# restore: binaries
bindir = pathlib.Path.home() / ".local" / "bin"
for b in g("restore.bins") or []:
    name, src = str(b.get("name", "")), pathlib.Path(os.path.expanduser(str(b.get("from", ""))))
    if not name or "/" in name or CRED.search(name):
        print(f"  skip bin {name!r}: not a plain, non-credential file name"); continue
    dest = bindir / name
    if dest.exists():
        print(f"  bin {name}: already present"); continue
    if not src.is_file():
        print(f"  bin {name}: source missing ({src})"); continue
    if dry:
        print(f"  would copy {src} -> {dest} (mode 755)")
    else:
        bindir.mkdir(parents=True, exist_ok=True); shutil.copy2(src, dest); dest.chmod(0o755)
        print(f"  bin {name}: installed from {src}")
print("undo: remove the copied files (memory: " + str(memdir) + "; bins: " + str(bindir) + ")")
PY
