#!/usr/bin/env python3
"""df-lock-migrate — move a lockfile's `install` block from the old MAP shape to the one shape.

THE PROBLEM
-----------
`install.skills` had more than one reading. The engine read an ARRAY of names plus an
`install.skillSources` MAP of name -> source; the tier templates read a single MAP of
name -> source; and a generated tier-3 instance read that same map with BARE local paths
as its values. One key, three meanings, all of them plausible on sight.

The array+map shape won, on counts rather than taste: it is what the verifier reads, and
it is what every lockfile already in service carries. It also expresses two states a
single map cannot -- a name with no source, and a source with no name -- both of which
install nothing while still reading like a declaration. `lock-verify` L7 checks both.

So the installers now REFUSE the old shape instead of quietly understanding it. An
installer that reads both forever is how a third reading appears. This script is the
one-line fix that refusal points at.

WHY THIS IS NOT PART OF df-manifest-migrate.py
----------------------------------------------
That script makes `repos.manifest.json` machine-neutral -- a different file, a different
shape, a different failure. Folding this in would make one script two things, which is
the exact defect this migration exists to remove.

WHAT IT DOES
------------
    "install": {"skills": {"a": "upstream:x/a", "b": "local:skills/b"}}
becomes
    "install": {"skills": ["a", "b"],
                "skillSources": {"a": "upstream:x/a", "b": "local:skills/b"}}

Source VALUES are carried across verbatim, with one exception, applied only where the
old shape could not have meant anything else: in a tier-3 instance lockfile every value
was resolved against the instance root, so a BARE value there means `local:` and is
rewritten to say so. Everywhere else a bare value already meant vendorDir and is left
exactly as it is. Guessing beyond that is how a migration invents a fourth reading.

Ordering is the declaration order of the old map, so a diff reads as a reshape rather
than a reshuffle. Key order elsewhere in the file, and the `$comment` keys, are preserved.

Usage:
  df-lock-migrate.py --lock <path> [--apply]
Without --apply it reports what it would change and writes nothing.
Exit: 0 migrated / already migrated · 1 nothing to do is not the case but it could not
      act · 2 the file is unusable.
"""
import argparse
import json
import sys
from collections import OrderedDict

# `skills` pairs with `skillSources`, `hooks` with `hookSources` — the stem is singular,
# so the pairing is stated once here rather than derived by concatenation at each use.
KINDS = {"skills": "skillSources", "hooks": "hookSources"}

# A tier-3 instance lockfile resolved every source against the instance root, so a bare
# value there meant "local:". Detected by the file's own name and by the key that only a
# tier-3 lockfile carries -- both, so a renamed file cannot silently change the meaning
# of every source in it.
def bare_means_local(path, doc):
    return path.name == "instance.lock.json" and "instance" in doc


def load(path):
    try:
        with path.open() as fh:
            return json.load(fh, object_pairs_hook=OrderedDict)
    except FileNotFoundError:
        sys.exit(f"FATAL: no lockfile at {path}")
    except json.JSONDecodeError as exc:
        sys.exit(f"FATAL: {path} is not valid JSON: {exc}")


def migrate(doc, local_default):
    """Return (new_install, report). new_install is None when there is nothing to do."""
    install = doc.get("install")
    if not isinstance(install, dict):
        return None, ["no `install` block — nothing to migrate"]

    report, changed = [], False
    out = OrderedDict()
    for key, val in install.items():
        if key not in KINDS:
            out[key] = val
            continue
        smap_key = KINDS[key]
        if isinstance(val, list):
            report.append(f"install.{key}: already an array ({len(val)} name(s))")
            out[key] = val
            continue
        if not isinstance(val, dict):
            sys.exit(f"FATAL: install.{key} is a {type(val).__name__}, not a map or an array")

        names, sources = [], OrderedDict()
        # `$`-prefixed keys are documentation, not entries. They stay in the SOURCES map,
        # which is where the shipped templates carry them.
        for name, src in val.items():
            if name.startswith("$"):
                sources[name] = src
                continue
            names.append(name)
            if local_default and isinstance(src, str) and ":" not in src.split("/")[0]:
                sources[name] = "local:" + src
                report.append(f"install.{key}: '{name}' bare source made explicit -> {sources[name]}")
            else:
                sources[name] = src
        out[key] = names
        # An existing *Sources map alongside an old-shape map is a state nothing writes and
        # nothing can safely merge -- stop rather than pick a winner.
        if isinstance(install.get(smap_key), dict) and any(
            not k.startswith("$") for k in install[smap_key]
        ):
            sys.exit(
                f"FATAL: install.{key} is a map AND install.{smap_key} already has entries.\n"
                "       Nothing writes that state and merging it would have to guess. "
                "Resolve it by hand."
            )
        out[smap_key] = sources
        report.append(f"install.{key}: map -> array of {len(names)} + {smap_key}")
        changed = True

    # A *Sources map with no array beside it (the old shape never wrote one, but a
    # half-hand-edited file can) is left alone rather than invented into a declaration.
    for kind, smap in KINDS.items():
        if smap in install and smap not in out:
            out[smap] = install[smap]

    return (out if changed else None), report


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--lock", required=True, help="path to the lockfile to migrate")
    ap.add_argument("--apply", action="store_true", help="write the change (default: report only)")
    args = ap.parse_args()

    from pathlib import Path
    path = Path(args.lock)
    doc = load(path)
    local_default = bare_means_local(path, doc)
    new_install, report = migrate(doc, local_default)

    print(f"=== df-lock-migrate  {path}")
    if local_default:
        print("    tier-3 instance lockfile: a bare source meant `local:` here, and is made explicit")
    for line in report:
        print("    " + line)

    if new_install is None:
        print("    already on the one shape — nothing to do")
        return 0

    if not args.apply:
        print("    DRY RUN — nothing written. Re-run with --apply.")
        return 0

    doc["install"] = new_install
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w") as fh:
        json.dump(doc, fh, indent=2)
        fh.write("\n")
    tmp.replace(path)
    print(f"    written: {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
