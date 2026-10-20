#!/usr/bin/env python3
"""parity-check — compare a listener config the kit rendered with another one (e.g. a hand-built live agent).

  parity-check.py <rendered config.json> <reference config.json> [--min 0.9] [--alias ref_key=rendered_key,...]

For every rule key in the reference: the share of its content words the rendered config also carries (the rule key
plus the standing rules). Prints keys below --min with the words that are missing, sources only on one side, and
tuning numbers / prefilter that differ. Exit 0 when nothing is below --min and sources match, else 1.
A word list is a cheap proxy: read the missing words — paths, ids and rewording show up too.
"""
import json, re, sys

STOP = set("the and for with that this from into only then when each every your their them they have will must never also "
           "than what which while after before about other more same just does done next once over under who not any are "
           "its his her him can".split())


ALIAS = {}


def words(s):
    return {w for w in re.findall(r"[a-z0-9][a-z0-9_\-/.]{3,}", s.lower()) if w not in STOP}


def text(v):
    return v if isinstance(v, str) else json.dumps(v, ensure_ascii=False)


def main(a):
    if len(a) < 2:
        sys.exit(__doc__)
    K, L = json.load(open(a[0])), json.load(open(a[1]))
    mn = float(a[a.index("--min") + 1]) if "--min" in a else 0.9
    global ALIAS
    ALIAS = dict(x.split("=", 1) for x in (a[a.index("--alias") + 1].split(",") if "--alias" in a else []))
    bad = 0
    for k in sorted(L):
        if k == "sources" or not isinstance(L[k], (str, dict, list)):
            continue
        kk = ALIAS.get(k, k)
        lw, kw = words(text(L[k])), words(text(K.get(kk, "")) + " " + text(K.get("standing_rules", "")))
        cov = len(lw & kw) / max(1, len(lw))
        if cov < mn:
            bad += 1
            print(f"  {k:22s} {cov:4.0%}  missing: {' '.join(sorted(lw - kw))[:300]}")
    key = lambda s: (s.get("kind"), s.get("channel_id") or s.get("chat_id") or s.get("jql", ""))  # noqa: E731
    ls, ks = {key(s) for s in L.get("sources", [])}, {key(s) for s in K.get("sources", [])}
    if ls != ks:
        bad += 1
        print("  sources only in reference:", ls - ks, " only rendered:", ks - ls)
    for k in ("thread_window", "thread_max_age_days", "surge_threshold", "pending_max_items", "pending_max_age_days",
              "briefing_max_items", "lock_stale_minutes"):
        if k in L and L.get(k) != K.get(k):
            bad += 1
            print(f"  DIFF {k}: reference {L.get(k)} rendered {K.get(k)}")
    print("PARITY OK" if not bad else f"{bad} difference(s)")
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
