#!/usr/bin/env python3
"""df-record-new.py — a new machine record from an existing one, with every MEASURED fact reset.

WHY THIS EXISTS. Operator, 2026-09-08: "none of the kits should assume any hard-coded reality:
everything should be checked, measured and or asked during the install: mcps, repos, the
machine, gh accounts. reality drifts and if we assume any hard coded state, we will be
incorrect on day2."

A Tier-3 instance record holds two KINDS of fact and they must not be handled alike:

  DECLARATIONS  what this machine SHOULD have — upstream pins, the skill and hook lists,
                which lanes it works. Inheriting these from a sibling is the point: that is
                what makes two machines on one lane the same machine in the ways that matter.

  MEASUREMENTS  what IS true of one physical box — its hostname/home, where its code lives,
                which MCP servers it actually has, what was probed and when. Inheriting these
                is never right. They were true of the SOURCE machine at the moment somebody
                measured it, and they are a lie about the target from the instant it is copied.

`bootstrap.sh` gets this right already: a freshly generated instance ships __CODE_ROOT__, an
empty codeLayout, an empty probed block and NO mcp block — loud placeholders that force a
measurement. But adding a machine to a SHARED instance repo is a different flow, and the
documented procedure for it said `cp <sibling>/loom.lock.json` and edit — which inherits every
measurement by default and relies on the human remembering all of them.

⚠️ IT DID NOT WORK, AND THE FAILURE IS THE REASON THIS SCRIPT EXISTS. A Coder workspace minted
that way on 2026-09-08 carried its sibling's `mcp` block verbatim: four servers that do not
exist there, `kind: hubs` when the box uses a project-scope .mcp.json, and a $comment naming
the OTHER machine's ~/.claude.json. Two of the four blocks were caught (identify.sh refuses a
wrong `machine`; probed self-corrects) and `mcp` was caught only because a human read it.

WHAT IS RESET, AND WHY EACH ONE:
  instance    the record's identity — it is a new machine
  machine     hostname/platform/home. identify.sh REFUSES a mismatch, so an inherited value
              does not silently pass — but it fails at install time with a confusing message
              rather than at write time with an obvious one
  codeRoot    where checkouts live. Wrong here means every repo probe hunts the wrong tree
  codeLayout  lane -> directory. Emptied, not guessed: an empty layout makes df-preflight
              report `unknown`, which is the honest answer. A GUESSED layout reports `drift`
              and sends someone to fix a machine that is fine
  mcp         REMOVED entirely. Absent means "the prefix rule applies and df-preflight will
              propose a measured block"; present-and-wrong means every tool trusts a fiction
  probed      emptied. It is tool-written and self-correcting, but shipping another machine's
              paths makes the first preflight report drift that was never real

WHAT IS KEPT: upstreams (pins are declarations), install.* (the skill/hook lists), lanes,
scope (a deliberate policy about what this machine is NOT for), notRestorable.

USAGE
  df-record-new.py --from <source-lockfile> --instance <name> [--out <path>]
  df-record-new.py --from instances/coder-a/loom.lock.json --instance coder-b \\
                   --out instances/coder-b/loom.lock.json

It prints what it reset. It does NOT create the vendor symlink or MACHINE.md — those are named
in the output so the caller cannot forget them, but a script that half-creates a record is
worse than one that creates none.
"""
import argparse
import json
import os
import sys

PLACEHOLDER = "__MEASURE_ME__"

RESET_NOTE = (
    "RESET by df-record-new.py — this value was NOT inherited from the source record. "
    "It is a MEASUREMENT of one physical machine and must be taken on THIS one. A value "
    "copied from a sibling is a lie about this box from the moment it is written, and it "
    "reads exactly like a correct one."
)


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        sys.exit(f"df-record-new: no such lockfile: {path}")
    except json.JSONDecodeError as e:
        sys.exit(f"df-record-new: {path} is not valid JSON: {e}")


def main():
    ap = argparse.ArgumentParser(prog="df-record-new.py",
                                 description=__doc__.split("\n")[0])
    ap.add_argument("--from", dest="src", required=True, help="an existing record to inherit DECLARATIONS from")
    ap.add_argument("--instance", required=True, help="the new machine's instance name")
    ap.add_argument("--out", help="where to write (default: stdout)")
    ap.add_argument("--force", action="store_true", help="overwrite --out if it exists")
    a = ap.parse_args()

    d = load(a.src)
    reset = []

    # --- identity -----------------------------------------------------------
    if isinstance(d.get("instance"), dict):
        d["instance"]["name"] = a.instance
    else:
        d["instance"] = a.instance
    reset.append(("instance", a.instance))

    # --- measurements -------------------------------------------------------
    # `machine` keeps its $-prefixed documentation and loses every value.
    m = d.get("machine")
    if isinstance(m, dict):
        keep = {k: v for k, v in m.items() if k.startswith("$")}
        for k in m:
            if not k.startswith("$"):
                keep[k] = PLACEHOLDER
        keep["$reset"] = RESET_NOTE
        d["machine"] = keep
        reset.append(("machine", "every value -> " + PLACEHOLDER))

    if "codeRoot" in d:
        d["codeRoot"] = PLACEHOLDER
        reset.append(("codeRoot", PLACEHOLDER))

    if "codeLayout" in d:
        # EMPTY, never guessed. An empty layout makes df-preflight say `unknown`, which is
        # true. A guessed one makes it say `drift`, which sends someone to fix a healthy box.
        d["codeLayout"] = {"$reset": RESET_NOTE +
                           " Left EMPTY on purpose: df-preflight reports `unknown` for an "
                           "empty layout, which is honest. A guessed layout reports `drift` "
                           "and sends someone to repair a machine that is fine."}
        reset.append(("codeLayout", "emptied (unknown beats a guess)"))

    if "mcp" in d:
        del d["mcp"]
        reset.append(("mcp", "REMOVED — absent means the prefix rule applies and "
                             "df-preflight will propose a measured block"))

    if "probed" in d:
        d["probed"] = {"$reset": RESET_NOTE + " Tool-written and self-correcting; shipping "
                                              "another machine's paths makes the first "
                                              "preflight report drift that was never real.",
                       "repos": {}}
        reset.append(("probed", "emptied"))

    out = json.dumps(d, indent=2, ensure_ascii=False) + "\n"

    if a.out:
        if os.path.exists(a.out) and not a.force:
            sys.exit(f"df-record-new: {a.out} exists — refusing to overwrite (pass --force)")
        os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
        with open(a.out, "w") as f:
            f.write(out)
    else:
        sys.stdout.write(out)

    w = sys.stderr
    print(f"\ndf-record-new: {a.src} -> {a.out or '<stdout>'}", file=w)
    print("RESET (measurements — never inherited):", file=w)
    for k, v in reset:
        print(f"  {k:12} {v}", file=w)
    print("KEPT (declarations — inherited on purpose): upstreams, install, lanes, scope, "
          "notRestorable", file=w)
    print("\nSTILL YOURS, and this script deliberately does NOT do them:", file=w)
    print("  1. fill every " + PLACEHOLDER + " by MEASURING this machine", file=w)
    print("  2. ln -s ../../vendor <dir>/vendor   (lock-verify derives vendorDir from", file=w)
    print("     dirname(lockfile); without it every pin reports missing)", file=w)
    print("  3. write MACHINE.md — what a human needs that no lockfile restores", file=w)
    print("  4. install with --lock=<this file>, then let df-preflight PROPOSE mcp/probed", file=w)
    return 0


if __name__ == "__main__":
    sys.exit(main())
