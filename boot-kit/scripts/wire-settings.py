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
  WIRES     ONLY what --lock declares. The template is SHARED across instances; the lockfile
            is PER-INSTANCE and is the authority. Skips are printed, never silent.
  PRUNES    with --prune-broken only, and only an entry that is BOTH wired AND missing its
            file -- a chain that errors on every event, where nothing is lost by removing it
            because the file it names is not there to run. That is the sole removal this tool
            will make, and it is repair, not clobbering.

Idempotent: a second run adds nothing and says so.

usage:
  wire-settings.py --template <settings.json.template> --live <settings.json>
                   --lock <instance lockfile> [--home <dir>] [--dry-run] [--prune-broken]

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

    ⚠️ AND EXPAND $HOME FIRST. A rendered template gives an ABSOLUTE path under the viewer's
    home; a hand-wired live entry may give the same file as `$HOME/.claude/hooks/...`. Those
    are one file, and lock-verify L9 already normalises both spellings for this same reason.

    ⚠️ THIS PARAGRAPH ONCE SPELLED THAT ABSOLUTE PATH OUT and the publish gate rejected it
    (P6, machine-local identifiers). It was right, and `audit-kit-gaps.py` already carries the
    identical lesson from earlier the same day: **a rule against machine-local absolute paths
    does not carve out the prose explaining the rule.** An example is not an exemption, and
    Tier 1 is the public repo -- the illustration would have shipped a real machine's layout
    to every reader.
    """
    home = os.environ.get("HOME", "")
    c = command.replace("${HOME}", home).replace("$HOME", home)
    return c.split()[0] if c.split() else ""


def count_hooks(chains):
    return sum(len((g or {}).get("hooks", []) or []) for gs in chains.values() for g in gs or [])


def filter_hooks(chains, declared, dropped=None):
    """Keep only template entries this lockfile DECLARES.

    ⚠️ `declared is None` means no --lock was given, so nothing can be filtered and the whole
    template is wired -- the old behaviour, kept ONLY for that case. It is not the safe default
    and callers should always pass --lock; install.sh and rehydrate.sh do.
    """
    if declared is None:
        return dict(chains)
    out = {}
    for event, groups in chains.items():
        keep = []
        for g in groups or []:
            hooks = []
            for h in (g or {}).get("hooks", []) or []:
                cmd = (h or {}).get("command")
                base = os.path.basename(hook_path(cmd)) if cmd else ""
                if base and base not in declared:
                    if dropped is not None:
                        dropped.append("%s  %s" % (event, base))
                    continue
                hooks.append(h)
            if hooks:
                ng = dict(g)
                ng["hooks"] = hooks
                keep.append(ng)
        if keep:
            out[event] = keep
    return out


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
    # ⚠️ THE LOCKFILE IS THE AUTHORITY AND THE FIRST VERSION IGNORED IT. The settings template
    # is SHARED across instances; the lockfile is PER-INSTANCE. Wiring the whole template puts
    # hooks into a machine that never installs them -- a chain that breaks on every event.
    #
    # Measured on the Poland Coder 2026-09-03, the day #84 shipped: three template entries
    # (catalyst-release-discipline-scoped.sh, handoff-sessionstart-load.py,
    # handoff-precompact.py) were wired there and declared by NOTHING in that lockfile -- that
    # box has no catalyst lane, and its own $hookBumpNote records removing the catalyst hooks
    # on 2026-08-31. lock-verify L9 caught it from the other side: "wired in settings but NOT
    # PRESENT on disk -- the chain breaks every session".
    #
    # **Lockfiles are the authority; installers are only mechanism.** This tool was a mechanism
    # that ignored the lockfile.
    ap.add_argument("--lock", default="",
                    help="instance lockfile; ONLY hooks it declares are wired")
    ap.add_argument("--prune-broken", action="store_true",
                    help="also REMOVE wired entries whose target file is absent (repair)")
    a = ap.parse_args()

    declared = None
    if a.lock:
        try:
            ld = json.loads(open(a.lock, encoding="utf-8").read())
        except Exception as e:
            print("FATAL: cannot read --lock %s: %s" % (a.lock, e), file=sys.stderr)
            return 1
        h = (ld.get("install") or {}).get("hooks") or []
        if isinstance(h, dict):
            h = list(h.keys())
        declared = {os.path.basename(x) for x in h}

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
        # ⚠️ THIS BRANCH USED TO SAY "writing" UNDER --dry-run AND WRITE NOTHING. Caught by
        # test-rehydrate-wires-hooks case D, which is the whole reason the assertion matches
        # the wiring phrase rather than a hook name. A dry run that reports a write it did not
        # perform is the same lie as an install that reports a wiring it did not do -- smaller,
        # and in the same direction.
        # ⚠️ FILTER HERE TOO. A fresh machine is exactly where wiring the whole shared
        # template does the most damage: nothing is wired yet, so every undeclared entry the
        # template carries lands at once and breaks the chain on the first session.
        seeded = dict(tmpl)
        seeded["hooks"] = filter_hooks(tmpl.get("hooks") or {}, declared)
        skipped = count_hooks(tmpl.get("hooks") or {}) - count_hooks(seeded["hooks"])
        suffix = " (dry run — nothing written)" if a.dry_run else ""
        print("   no live settings.json — writing the rendered template%s" % suffix)
        if not a.dry_run:
            os.makedirs(os.path.dirname(a.live) or ".", exist_ok=True)
            open(a.live, "w", encoding="utf-8").write(json.dumps(seeded, indent=2) + "\n")
        print("   wired %d hook(s) across %d event chain(s)%s"
              % (count_hooks(seeded["hooks"]), len(seeded["hooks"]), suffix))
        if skipped:
            print("   skipped %d template entr(y/ies) this lockfile does not declare — wiring"
                  " them would break the chain every session" % skipped)
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
    undeclared = []
    live.setdefault("hooks", {})
    for event, groups in filter_hooks(tmpl.get("hooks") or {}, declared,
                                      dropped=undeclared).items():
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

    # ---- repair: entries already wired here whose target file is absent ----
    # ⚠️ THIS IS THE ONLY REMOVAL THIS TOOL WILL EVER MAKE, and it is gated three ways: the
    # entry must be wired, its file must NOT exist, and --prune-broken must be passed. Such an
    # entry is not the operator's working config -- it is a chain that errors on every event,
    # and nothing is lost by removing it because the file it names is not there to run.
    broken = []
    for event, groups in (live.get("hooks") or {}).items():
        for g in groups or []:
            for h in (g or {}).get("hooks", []) or []:
                cmd = (h or {}).get("command")
                if cmd and not os.path.exists(hook_path(cmd)):
                    broken.append((event, h, os.path.basename(hook_path(cmd))))
    if broken:
        if a.prune_broken:
            for event, h, base in broken:
                for g in live["hooks"].get(event, []):
                    if h in (g.get("hooks") or []):
                        g["hooks"].remove(h)
                print("   - PRUNED %s  %s (wired, file absent — the chain broke every session)"
                      % (event, base))
            live["hooks"] = {e: [g for g in gs if g.get("hooks")]
                             for e, gs in live["hooks"].items()}
            live["hooks"] = {e: gs for e, gs in live["hooks"].items() if gs}
            pruned = True
        else:
            print("   ⚠️ %d wired entr(y/ies) point at a file that is NOT on this machine —"
                  " the chain breaks every session:" % len(broken))
            for _, _, base in broken:
                print("     ! %s" % base)
            print("     re-run with --prune-broken to remove them (backed up first).")
            pruned = False
    else:
        pruned = False

    if added or pruned:
        if not a.dry_run:
            # ⚠️ NOT `utcnow()`. It is deprecated and PRINTS A WARNING mid-run on Python 3.12+,
            # which landed in the middle of this tool's output on the Poland Coder — noise from
            # the one tool whose entire job is to say clearly what it changed. A warning nobody
            # can distinguish from a finding trains the reader to skim both.
            stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
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

    if undeclared:
        # ⚠️ REPORTED, NEVER SILENT. A skip nobody can see is indistinguishable from a check
        # that never ran -- the defect class this whole session was spent removing.
        print("   NOT wired (%d) — in the shared template, not declared by THIS lockfile:"
              % len(undeclared))
        for line in sorted(set(undeclared)):
            print("     - %s" % line)
        print("     the template is shared across instances; the lockfile is per-instance and"
              " is the authority.")

    if noted:
        # Not a failure. The operator may have chosen these deliberately.
        print("   note: template also differs on %s — NOT changed, that is your file"
              % ", ".join(sorted(noted)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
