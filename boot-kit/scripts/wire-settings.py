#!/usr/bin/env python3
"""wire-settings.py — arm the declared hooks in a machine's live settings.json.

⛔ WHY THIS EXISTS. Installing a hook is TWO acts and every installer in this estate did only
the first: it copies the file into `~/.claude/hooks/`, and something must then name that file
in an event chain in `~/.claude/settings.json` before it ever runs. Until now the second act
was a line of prose in the installer's MANUAL section -- `cp the template yourself` -- so
every hook declared since a machine's last hand-copy sat on disk, inert, while the install
printed `install complete`.

That is DECLARED + INSTALLED + NOT WIRED, and it is not hypothetical:

  · measured on coder-eso-aws--loom-neptune-arm after a workspace reset wiped ~/.claude:
    **15 declared, 8 wired** (recorded in the template's own $hookWiringNote).
  · measured on the Poland Coder 2026-09-03: mission-completeness-gate.py declared,
    installed and wired nowhere, because that box's settings.json predated the declaration.

⚠️ **A REQUIRED MANUAL STEP THAT SILENTLY NO-OPS IS NOT A SAFETY FEATURE.** It is the defect,
wearing the costume of caution. The caution that IS warranted is about CLOBBERING: settings.json
is the human's file -- permissions, model, plugins, project config -- so the fix is a merge with
a backup, not a copy. This estate had already written that pattern down before anything used it.

WHAT IT TOUCHES, AND WHAT IT REFUSES TO TOUCH
---------------------------------------------
  ADDS      hook commands from the template that are not already wired for that event.
  NEVER     removes, reorders or rewrites an existing entry.
  NEVER     writes any top-level key but `hooks`. `permissions` is a security posture and
            `outputStyle` changes the operator's UI; a difference in either is REPORTED and
            left alone. An installer that quietly widens permissions is a worse bug than an
            unwired hook.
  REFUSES   to write at all if the live file exists and is not valid JSON. It may be
            recoverable by hand; overwriting it destroys the only copy.

Idempotent: a second run adds nothing and says so.

usage:
  wire-settings.py --template <settings.json.template> --live <settings.json>
                   [--home <dir>] [--dry-run]

Engram is one of the memory stores whose hooks this wires. What it is and how to reach it is
documented in exactly one place:
[Engram](../../starter-kit/instance/AUTHENTICATION.md#engram)
"""
import argparse
import datetime
import json
import os
import shutil
import sys


def hook_path(command):
    """The FILE a chain entry runs, with $HOME spellings expanded and arguments dropped.

    ⚠️ COMPARE THE PATH, NOT THE WHOLE COMMAND. A chain carries arguments; a path does not.
    Comparing full command strings would wire the same hook a second time whenever the
    template's arguments differ from what a human typed -- and a hook that fires twice is a
    worse outcome than one that does not fire, because it looks like it is working.

    ⚠️ AND EXPAND $HOME FIRST. A template renders to `/home/coder/.claude/hooks/x.sh` while a
    hand-wired live entry may say `$HOME/.claude/hooks/x.sh`. Those are one file. lock-verify
    L9 already normalises both spellings for exactly this reason.
    """
    home = os.environ.get("HOME", "")
    c = command.replace("${HOME}", home).replace("$HOME", home)
    return c.split()[0] if c.split() else ""


def wired_paths(settings, event):
    out = set()
    for group in (settings.get("hooks") or {}).get(event, []) or []:
        for h in (group or {}).get("hooks", []) or []:
            cmd = (h or {}).get("command")
            if cmd:
                out.add(hook_path(cmd))
    return out


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--template", required=True)
    ap.add_argument("--live", required=True)
    ap.add_argument("--home", default=os.environ.get("HOME", ""))
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    if not os.path.isfile(a.template):
        print("FATAL: no settings template at %s" % a.template, file=sys.stderr)
        return 1
    rendered = open(a.template, encoding="utf-8").read().replace("__HOME__", a.home)
    try:
        tmpl = json.loads(rendered)
    except ValueError as e:
        print("FATAL: template is not valid JSON after __HOME__ rendering: %s" % e,
              file=sys.stderr)
        return 1

    live_exists = os.path.isfile(a.live) and os.path.getsize(a.live) > 0
    if not live_exists:
        # Nothing to preserve, so the whole rendered template is the right content.
        print("   no live settings.json — writing the rendered template whole")
        if not a.dry_run:
            os.makedirs(os.path.dirname(a.live) or ".", exist_ok=True)
            open(a.live, "w", encoding="utf-8").write(json.dumps(tmpl, indent=2) + "\n")
        print("   wired %d event chain(s)" % len(tmpl.get("hooks") or {}))
        return 0

    try:
        live = json.loads(open(a.live, encoding="utf-8").read())
    except ValueError as e:
        # ⚠️ REFUSE. Claude Code cannot read this file either, so nothing is wired right now --
        # but it is the operator's file and may be one comma from correct. Overwriting it
        # trades a visible breakage for an invisible loss.
        print("FATAL: %s is not valid JSON (%s)" % (a.live, e), file=sys.stderr)
        print("       REFUSING to overwrite it. Fix or move it, then re-run.", file=sys.stderr)
        return 1

    added = []
    live.setdefault("hooks", {})
    for event, groups in (tmpl.get("hooks") or {}).items():
        have = wired_paths(live, event)
        for group in groups or []:
            missing = [h for h in (group or {}).get("hooks", []) or []
                       if (h or {}).get("command")
                       and hook_path(h["command"]) not in have]
            if not missing:
                continue
            newgroup = dict(group)
            newgroup["hooks"] = missing
            live["hooks"].setdefault(event, []).append(newgroup)
            for h in missing:
                have.add(hook_path(h["command"]))
                added.append("%s  %s" % (event, os.path.basename(hook_path(h["command"]))))

    # Differences OUTSIDE hooks are reported and never applied. See the module docstring.
    noted = []
    for k, v in tmpl.items():
        if k == "hooks" or k.startswith("$"):
            continue
        if live.get(k) != v:
            noted.append(k)

    if added:
        if not a.dry_run:
            stamp = datetime.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
            backup = "%s.bak.%s" % (a.live, stamp)
            shutil.copy2(a.live, backup)
            open(a.live, "w", encoding="utf-8").write(json.dumps(live, indent=2) + "\n")
            print("   backup: %s" % backup)
        for line in added:
            print("   + %s" % line)
        print("   wired %d hook(s)%s" % (len(added), " (dry run — nothing written)"
                                         if a.dry_run else ""))
    else:
        print("   every hook the template wires is already wired — no change")

    if noted:
        # Not a failure. The operator may have chosen these deliberately.
        print("   note: template also differs on %s — NOT changed, that is your file"
              % ", ".join(sorted(noted)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
