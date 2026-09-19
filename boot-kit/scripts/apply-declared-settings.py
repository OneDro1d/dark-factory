#!/usr/bin/env python3
"""apply-declared-settings.py — merge a record's `install.settings` into a live settings.json, ADD-ONLY.

Called by rehydrate.sh section 4c. First written as one kit's own script and moved here so that
every kit which installs through rehydrate.sh gets it by moving a pin, not by copying a file.

⚠️ OPT-IN, and nothing is set by default. A record that declares no `install.settings` block is a
stated no-op: this script prints one line and exits 0. The values themselves (e.g.
`autoCompactWindow`, `env.CLAUDE_CODE_SUBAGENT_MODEL`) are a behaviour choice that belongs to the
record's owner, never to this engine.

Semantics, and why:
  * A key the record declares and the live file lacks is ADDED.
  * A key already present KEEPS ITS VALUE and is reported, never overwritten. The operator's own
    choice wins, and a reinstall can never silently undo a deliberate local setting.
  * An object value (e.g. `env`) merges per sub-key with the same rule.
  * `$`-prefixed keys are documentation and are never written.
  * Unparseable live JSON is a REFUSAL (exit 1), never an overwrite.
  * --dry-run reports and writes nothing. A real write leaves a timestamped backup first.
Per-notepad override is the harness's own precedence: a notepad's .claude/settings.json outranks
the user file this writes, and `env` merges per variable.

Usage: apply-declared-settings.py --lock <loom.lock.json> --live <settings.json> [--dry-run]
Exit:  0 applied or nothing to do · 1 refused (bad live JSON) · 2 usage/lock error
"""
import argparse
import json
import os
import shutil
import sys
import time


def merge(cur, want):
    added, kept = [], []
    for k, v in want.items():
        if k.startswith("$"):
            continue
        if isinstance(v, dict):
            have = cur.get(k)
            if have is not None and not isinstance(have, dict):
                kept.append("%s (not an object here: %r)" % (k, have))
                continue
            have = dict(have or {})
            for sk, sv in v.items():
                if sk.startswith("$"):
                    continue
                if sk in have:
                    if have[sk] != sv:
                        kept.append("%s.%s = %r (declared %r)" % (k, sk, have[sk], sv))
                else:
                    have[sk] = sv
                    added.append("%s.%s = %r" % (k, sk, sv))
            cur[k] = have
        elif k in cur:
            if cur[k] != v:
                kept.append("%s = %r (declared %r)" % (k, cur[k], v))
        else:
            cur[k] = v
            added.append("%s = %r" % (k, v))
    return added, kept


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--lock", required=True)
    ap.add_argument("--live", required=True)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args(argv)
    try:
        want = (json.load(open(a.lock)).get("install") or {}).get("settings") or {}
    except Exception as e:
        print("! cannot read install.settings from %s: %s" % (a.lock, e))
        return 2
    if not [k for k in want if not k.startswith("$")]:
        print("   this record declares no install.settings — nothing to add")
        return 0
    try:
        cur = json.load(open(a.live)) if os.path.exists(a.live) else {}
    except ValueError as e:
        print("! %s is not valid JSON (%s) — REFUSING to touch it" % (a.live, e))
        return 1
    added, kept = merge(cur, want)
    for x in added:
        print("   + %s" % x)
    for x in kept:
        print("   = kept yours: %s" % x)
    if not added:
        print("   every declared setting is already present — no change")
        return 0
    if a.dry_run:
        print("   (dry run — nothing written)")
        return 0
    if os.path.exists(a.live):
        shutil.copy2(a.live, "%s.bak-%s" % (a.live, time.strftime("%Y%m%d%H%M%S")))
    tmp = a.live + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cur, f, indent=2)
        f.write("\n")
    os.replace(tmp, a.live)
    print("   wrote %d setting(s); backup beside the file" % len(added))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
