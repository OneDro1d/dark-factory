#!/usr/bin/env bash
# install.sh — the one command. Run it in EACH of the two workspaces (builder first, then tester):
#
#   git clone <this repo> <shared_root>/builder-tester-agents && cd <shared_root>/builder-tester-agents && ./install.sh
#   ./install.sh --pack <name>     # also install + register an optional hook pack (packs/<name>/hooks.json)
#
# What it does (safe to re-run; every file it replaces is backed up first, unchanged files are left alone):
#   1. checks prerequisites (python3 + PyYAML, tmux, git, gh, claude)
#   2. finds pair.yaml, or asks the setup questions and writes it (./setup-pair init)
#   3. links the skills into ~/.claude/skills (and dark_factory.skills_dir's skills, when set)
#   4. copies the hooks into ~/.claude/hooks and registers them in ~/.claude/settings.json (from kit/hooks/hooks.json,
#      with each entry's timeout/statusMessage; `when:` entries only when that pair.yaml setting is true), plus packs
#   5. installs the reviewer and patrol agents into ~/.claude/agents (adversary.md as <rules.reviewer>.md)
#   6. checks the Dark Factory skills are present when dark_factory.enabled (warns, never fails)
#   7. points the agents' kubectl at a read-only identity (~/.kube/agent-readonly.conf) when it exists
#   8. renders this workspace's listener config and start command (./setup-pair render)
#   9. runs ./setup-pair check and prints the steps only a person can do
# It never signs in to anything, never reads a credential and never touches a cluster.
set -euo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
say() { printf '\n== %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }

PACKS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --pack) [ -n "${2:-}" ] || { echo "--pack needs a name (one of: $(ls "$KIT/packs" | tr '\n' ' '))"; exit 2; }
            [ -f "$KIT/packs/$2/hooks.json" ] || { echo "no pack '$2' (no $KIT/packs/$2/hooks.json)"; exit 2; }
            PACKS+=("$2"); shift 2 ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)"; exit 2 ;;
  esac
done

say "1/9 prerequisites"
missing=0
for t in python3 tmux git gh claude; do
  if command -v "$t" >/dev/null; then echo "ok   $t"; else echo "MISSING $t"; missing=1; fi
done
python3 -c "import yaml" 2>/dev/null || { echo "installing PyYAML for this user"; python3 -m pip install --user -q pyyaml; }
[ "$missing" = 0 ] || { echo "Install the missing tools above, then re-run ./install.sh"; exit 1; }

say "2/9 pair.yaml"
if ! CFG="$(python3 "$KIT/kit/lib/pairconf.py" path 2>/dev/null)"; then
  echo "No pair.yaml yet. Easiest: open Claude here and run /pair-setup (it asks the questions, connects your repos"
  echo "and creates the memory spaces). Or answer them in this terminal now."
  read -r -p "Answer the setup questions here now? [Y/n] " yn
  case "${yn:-Y}" in [Nn]*) echo "Run /pair-setup in Claude, then ./install.sh again."; exit 0 ;; esac
  "$KIT/setup-pair" init
  CFG="$(python3 "$KIT/kit/lib/pairconf.py" path)"
fi
echo "using $CFG"
export PAIR_CONFIG="$CFG"
mkdir -p "$HOME/.config/builder-tester-agents"
ln -sfn "$CFG" "$HOME/.config/builder-tester-agents/pair.yaml"
ln -sfn "$KIT" "$HOME/.config/builder-tester-agents/kit"   # installed hook copies find the kit (packs, extends) here
ROLE="$(python3 "$KIT/kit/lib/pairconf.py" role)"
echo "this workspace is the: $ROLE"
if [ "$ROLE" = unknown ]; then
  echo "This host ($(hostname)) is not builder.host or tester.host in $CFG — fix that, then re-run."; exit 1
fi
cfg_get() { python3 "$KIT/kit/lib/pairconf.py" get "$1"; }

say "3/9 skills"
mkdir -p "$HOME/.claude/skills" "$HOME/.claude/hooks"
for d in "$KIT"/skills/*/; do
  [ -d "$d" ] || continue
  n="$(basename "$d")"; ln -sfn "$d" "$HOME/.claude/skills/$n"; echo "skill  $n"
done
# dark_factory.skills_dir: one folder or a list of folders (e.g. an org install's skills/ and vendor/…/skills/)
DF_DIRS="$(cfg_get dark_factory.skills_dir | python3 -c 'import json,sys
v=sys.stdin.read().strip()
try: v=json.loads(v)
except ValueError: pass
print("\n".join(v if isinstance(v,list) else [v] if v else []))')"
while IFS= read -r DF_DIR; do
  [ -n "$DF_DIR" ] || continue
  DF_DIR="${DF_DIR/#\~/$HOME}"
  if [ -d "$DF_DIR" ]; then
    for d in "$DF_DIR"/*/; do
      [ -f "$d/SKILL.md" ] || continue
      n="$(basename "$d")"
      if [ -e "$HOME/.claude/skills/$n" ] && [ ! -L "$HOME/.claude/skills/$n" ]; then
        echo "skill  $n (kept: a real folder already exists in ~/.claude/skills)"
      else
        ln -sfn "${d%/}" "$HOME/.claude/skills/$n"; echo "skill  $n (from dark_factory.skills_dir)"
      fi
    done
  else
    warn "dark_factory.skills_dir=$DF_DIR does not exist — no Dark Factory skills linked from it"
  fi
done <<< "$DF_DIRS"

# install_hooks <hooks.json> <source dir> <label>: copy each hook into ~/.claude/hooks (backup when it differs) and
# register it in ~/.claude/settings.json with its timeout/statusMessage. An entry with `when: <dotted.key>` is
# registered only while that pair.yaml setting is true, and unregistered again when it is false. Idempotent:
# settings.json is rewritten (after a backup) only when something changed.
install_hooks() {
  python3 - "$KIT" "$1" "$2" "$3" <<'PY'
import datetime, filecmp, json, pathlib, shutil, sys
kit, spec, src, label = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]), sys.argv[4]
sys.path.insert(0, str(kit / "kit/lib"))
import pairconf
cfg = pairconf.load()
home = pathlib.Path.home(); dest = home / ".claude/hooks"; dest.mkdir(parents=True, exist_ok=True)
stamp = datetime.datetime.now().strftime("%Y%m%d%H%M%S")

def put(s, t, mode=None):
    if t.exists() and filecmp.cmp(s, t, shallow=False):
        return "same"
    if t.exists():
        shutil.copy2(t, t.with_name(t.name + ".bak-" + stamp))
    shutil.copy2(s, t)
    if mode:
        t.chmod(mode)
    return "updated" if t.with_name(t.name + ".bak-" + stamp).exists() else "new"

hooks = json.loads(spec.read_text())
retire = [h["retire"] for h in hooks if h.get("retire")]   # older hand-built hooks this set replaces: unregistered
hooks = [h for h in hooks if h.get("file")]
for f in sorted({h["file"] for h in hooks}):
    print(f"hook   {f:38s} {put(src / f, dest / f, 0o755)}   [{label}]")
hooks = [h for h in hooks if h.get("event")]   # entries without an event are helpers: copied, never registered
for lib, where in (("pairconf.py", kit / "kit/lib"), ("ledger_common.py", kit / "kit/hooks")):   # modules hooks import
    if (where / lib).exists():
        put(where / lib, dest / lib)

sp = home / ".claude/settings.json"
before = sp.read_text() if sp.exists() else ""
settings = json.loads(before) if before.strip() else {}
H = settings.setdefault("hooks", {})
added = updated = removed = 0
for h in hooks:
    cmd = ("python3 " if h["file"].endswith(".py") else "bash ") + str(dest / h["file"])
    matcher = h.get("matcher", "")
    want = {"type": "command", "command": cmd}
    for k in ("timeout", "statusMessage"):
        if k in h:
            want[k] = h[k]
    on = True
    if h.get("when"):
        on = pairconf.get(cfg, h["when"], False) is True
    groups = H.setdefault(h["event"], [])
    grp = next((g for g in groups if g.get("matcher", "") == matcher), None)
    have = next((x for x in (grp or {}).get("hooks", []) if x.get("command") == cmd), None)
    if not on:
        if have is not None:
            grp["hooks"].remove(have); removed += 1
            print(f"unregistered {h['file']} ({h['event']} {matcher}) — {h['when']} is not true")
        else:
            print(f"skipped      {h['file']} ({h['event']} {matcher}) — {h['when']} is not true")
        continue
    # the same hook registered under another path or form (e.g. by a hand-built install): keep exactly one
    for g in groups:
        for x in list(g.get("hooks", [])):
            c = x.get("command", "")
            if c != cmd and (c.endswith("/" + h["file"]) or ("/" + h["file"] + " ") in c):
                g["hooks"].remove(x); removed += 1
                print(f"deduplicated {h['file']} ({h['event']}): removed {c[:80]}")
    if grp is None:
        grp = {"matcher": matcher, "hooks": []}; groups.append(grp)
    if have is None:
        grp["hooks"].append(want); added += 1
    elif have != want:
        have.clear(); have.update(want); updated += 1
for name in retire:
    for ev, groups in H.items():
        for g in groups:
            for x in list(g.get("hooks", [])):
                if x.get("command", "").endswith("/" + name) or ("/" + name + " ") in x.get("command", ""):
                    g["hooks"].remove(x); removed += 1
                    print(f"retired      {name} ({ev}) — replaced by this kit")
for ev in list(H):
    H[ev] = [g for g in H[ev] if g.get("hooks")]
    if not H[ev]:
        del H[ev]
after = json.dumps(settings, indent=2) + "\n"
if after != before:
    sp.parent.mkdir(parents=True, exist_ok=True)
    if sp.exists():
        shutil.copy2(sp, sp.with_name("settings.json.bak-" + stamp))
    sp.write_text(after)
print(f"[{label}] settings.json: {added} added, {updated} updated (timeout/statusMessage), {removed} removed"
      + ("" if after != before else " — unchanged"))
PY
}

say "4/9 hooks"
install_hooks "$KIT/kit/hooks/hooks.json" "$KIT/kit/hooks" kit
for p in "${PACKS[@]+"${PACKS[@]}"}"; do
  install_hooks "$KIT/packs/$p/hooks.json" "$KIT/packs/$p/hooks" "pack:$p"
  for d in "$KIT/packs/$p/skills"/*/; do   # a pack's own skills (e.g. its runner/tester playbook)
    [ -f "$d/SKILL.md" ] || continue
    n="$(basename "$d")"; ln -sfn "${d%/}" "$HOME/.claude/skills/$n"; echo "skill  $n [pack:$p]"
  done
done

say "5/9 agents"
python3 - "$KIT" <<'PY'
import datetime, json, pathlib, re, shutil, sys
kit = pathlib.Path(sys.argv[1]); sys.path.insert(0, str(kit / "kit/lib"))
import pairconf
cfg = pairconf.load(); g = lambda k, d="": pairconf.get(cfg, k, d) or d
owner = g("owner.short_name") or (g("owner.name", "the owner").split() or ["the owner"])[0]
values = {"reviewer": g("rules.reviewer", "adversary"), "builder": pairconf.name(cfg, "builder"),
          "tester": pairconf.name(cfg, "tester"), "owner": owner, "project": g("project.name", "this project")}
if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", values["reviewer"]):
    sys.exit(f"rules.reviewer must be lowercase letters, digits and dashes (got {values['reviewer']!r})")
dest = pathlib.Path.home() / ".claude/agents"; dest.mkdir(parents=True, exist_ok=True)
stamp = datetime.datetime.now().strftime("%Y%m%d%H%M%S")
for src in sorted((kit / "agents").glob("*.md")):
    name = values["reviewer"] if src.stem == "adversary" else src.stem
    text = re.sub(r"\{\{(\w+)\}\}", lambda m: str(values.get(m.group(1), m.group(0))), src.read_text())
    tgt = dest / f"{name}.md"
    if tgt.exists() and tgt.read_text() == text:
        print(f"agent  {name:20s} same"); continue
    state = "new"
    if tgt.exists():
        shutil.copy2(tgt, tgt.with_name(tgt.name + ".bak-" + stamp)); state = "updated (old copy backed up)"
    tgt.write_text(text); print(f"agent  {name:20s} {state}")
PY

say "6/9 Dark Factory skills"
python3 - "$KIT" <<'PY'
import os, pathlib, sys
kit = pathlib.Path(sys.argv[1]); sys.path.insert(0, str(kit / "kit/lib"))
import pairconf
cfg = pairconf.load()
if pairconf.get(cfg, "dark_factory.enabled", False) is not True:
    print("dark_factory.enabled is not true — nothing to check"); sys.exit(0)
default = {"product_owner": "df-product-owner", "architect": "df-solution-architect", "build": "df-tdd-developer",
           "adversary": "df-adversary-gate", "qa": "df-qa", "reading": "requirements-discovery",
           "coverage": ["test-strategy", "dependency-mapping"], "contracts": "contract-check",
           "data_pipeline": "df-data-transform-lens", "ui": "df-ui-verify", "outcomes": "df-observability",
           "auth": "security-threat-modeler", "test_quality": ["critical-thinking"]}
skills = dict(default, **(pairconf.get(cfg, "dark_factory.skills", {}) or {}))
need = {pairconf.get(cfg, "dark_factory.loop_skill", "dark-factory-build") or "dark-factory-build": "loop_skill"}
for role, v in skills.items():
    for s in (v if isinstance(v, list) else [v]):
        if s:
            need.setdefault(str(s), f"skills.{role}")
home = pathlib.Path.home() / ".claude/skills"
missing = [(s, r) for s, r in sorted(need.items()) if not (home / s / "SKILL.md").exists()]
print(f"{len(need) - len(missing)}/{len(need)} Dark Factory skills present in {home}")
for s, r in missing:
    print(f"WARN missing skill {s:28s} (dark_factory.{r})")
if missing:
    print("WARN install them into ~/.claude/skills, or set dark_factory.skills_dir to a folder holding them and re-run;"
          " the Dark Factory loop will skip a stage whose skill is missing.")
PY

say "7/9 read-only cluster identity"
SETTINGS="$HOME/.claude/settings.json"
AGENT_KC="$HOME/.kube/agent-readonly.conf"
if [ -s "$AGENT_KC" ]; then
  python3 - "$SETTINGS" "$AGENT_KC" <<'PY'
import json, pathlib, sys
sp, kc = pathlib.Path(sys.argv[1]), sys.argv[2]
s = json.loads(sp.read_text()) if sp.exists() and sp.read_text().strip() else {}
if s.get("env", {}).get("KUBECONFIG") != kc:
    s.setdefault("env", {})["KUBECONFIG"] = kc
    sp.parent.mkdir(parents=True, exist_ok=True); sp.write_text(json.dumps(s, indent=2) + "\n")
print(f"ok   agent kubectl -> read-only identity ({kc}) via settings.json env.KUBECONFIG")
PY
else
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  warn "no $AGENT_KC — this agent's kubectl runs as YOU (often admin). The deploy gate is only a tripwire."
  warn "Fix: bash $KIT/kit/scripts/make-agent-kubeconfig.sh  (prints the commands for you to run), then re-run ./install.sh"
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
fi

say "8/9 render this workspace's files"
"$KIT/setup-pair" render

say "9/9 check"
"$KIT/setup-pair" check || true

cat <<EOF

Steps only you can do (once):
  builder workspace:  coder logout --yes                        # so the builder can't reach the tester's workspace
  each workspace:     sign in to your Jira/Teams/Slack MCP hub   # (your hub's own sign-in command)
  tester workspace:   put the Argus *author* tokens here; builder gets *runner* tokens only (if you use Argus)
  cluster (owner):    bash $KIT/kit/scripts/make-agent-kubeconfig.sh   # read-only kubectl for the agents
  each workspace:     bash $KIT/kit/scripts/start-agent.sh     # starts the watchdog + the agent; Ctrl-b d to leave
Then send "<tester-name> restart" in your Teams self-chat and look for the "Started" report.
EOF
