#!/usr/bin/env bash
# hooks/push-gate.sh — U8 doc-currency gate on AGENT pushes (DESIGN §7.7, scope-init §6a).
#
# Wiring: PreToolUse on Bash, declared in the NOTEPAD's .claude/settings.json, so it arms only
# in notepad sessions.
#
# ⚠️ IT GOVERNS AGENT PUSHES ONLY. A human typing `git push` in a terminal never reaches a
# PreToolUse hook. An operator who believes this covers their own pushes is worse off than one
# who knows it does not — say so wherever it is offered.
#
# ⚠️ IT CAN ONLY PROVE A DOC MOVED, NEVER THAT IT IS RIGHT. One whitespace character in the
# required file passes. This catches the mechanical class — code shipped with the index
# untouched — and a reader catches the semantic one. A green push does not mean the docs are
# current, and nothing in the output should be phrased as if it did.
#
# Contract (hook recipe): read the tool-call JSON on stdin, inspect tool_input.command; emit
# {} to allow or {"decision":"block","reason":...} to block. EXIT 0 ALWAYS — a non-zero exit
# is an error, not a policy decision.
#
# ── WHERE THE RULES LIVE, AND WHY IT IS NOT HERE ────────────────────────────────────────────
# `<repo>/.claude/docs-map.json`, IN THE CODE REPO. Not in the notepad's manifest: a manifest
# is objective-scoped, one notepad per objective, and the same repo can be driven by two
# notepads or by none. Put the policy there and the repo acquires two definitions of done, or
# zero — the one-artifact-two-homes failure this whole model exists to remove, one level up.
# The notepad answers "which repos am I working on"; the repo answers "what does this repo
# require".
#
# ⚠️ NO FILE MEANS ABSTAIN, NEVER A DEFAULT RULE SET. A gate that invents rules for a repo
# nobody configured fires wrong on its first run, and a gate that fires wrong is one people
# learn to `--no-verify` past. Same abstain-by-default the commit gate uses for a repo with no
# `.claude/context/` store.
#
# Shape:
#   { "rules": [ { "when": "<glob>", "requires": ["<glob>", …], "level": "block"|"warn" } ] }
#   `when` matching a pushed path REQUIRES at least one `requires` glob to match a pushed path
#   too. `$1` in a `requires` glob is the text the FIRST `*` of `when` matched, so
#   {"when":"skills/*/**","requires":["skills/$1/SKILL.md"]} asks for the changed skill's own
#   doc rather than for any doc anywhere.
#
# Abstains ({}) when: not a push; repo unresolved or not a worktree; no docs-map; the push
# range cannot be resolved (see below); the range is empty; `--no-verify`; or the env off.
#
# ⚠️ WHAT "THE PUSH RANGE" MEANS, AND THE HOLE IN IT. The range is `@{u}..HEAD`, falling back
# to the remote's default branch when the branch has no upstream yet — the ordinary
# new-feature-branch case, which would otherwise abstain on the one push that creates it. If
# NEITHER resolves the gate abstains rather than guessing a base: a wrong base either invents
# violations or hides them, and both are worse than not looking. A push naming an explicit
# refspec for some other ref (`git push origin some-branch:main`) is out of scope and abstains
# — it is not judging HEAD, and pretending otherwise would report on the wrong commits.
#
# Config (env, all optional):
#   AGENT_NOTEPAD_PUSH_GATE=off      disable entirely
#   AGENT_NOTEPAD_DOCS_MAP=<name>    filename under <repo>/.claude/ (default docs-map.json)
set -u

allow() { printf '{}\n'; exit 0; }
# A warn-level violation must not vanish. `systemMessage` is this plugin's existing channel for
# talking to the operator (session-start.sh uses it), and the text ALSO goes to stderr, because
# whether a PreToolUse systemMessage is surfaced is not something this hook can verify from
# inside itself. Two channels and a stated uncertainty beat one channel and an assumption.
warn_only() { # message
  printf '%s\n' "$1" >&2
  jq -n --arg m "$1" '{systemMessage:$m}' 2>/dev/null || printf '{}\n'
  exit 0
}
block() { # reason-text
  jq -n --arg r "$1" '{decision:"block", reason:$r}' 2>/dev/null \
    || printf '{"decision":"block","reason":%s}\n' "\"${1//\"/\\\"}\""
  exit 0
}

[ "${AGENT_NOTEPAD_PUSH_GATE:-on}" = "off" ] && allow

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[ -z "$cmd" ] && allow

# ── parse the command: is it a git-push? extract -C <path>, --no-verify, refspecs ───────────
# Same tokenizer as commit-gate.sh: shlex handles quoting, `git -C <path> push`, and a push
# segment inside a compound command.
parsed="$(python3 - "$cmd" <<'PY'
import shlex, sys, os
cmd = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    toks = shlex.split(cmd)
except ValueError:
    print("NOTPUSH"); sys.exit(0)

VAL_OPTS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path",
            "--super-prefix", "--config-env"}

def scan(start):
    i, cpath, n = start, "", len(toks)
    while i < n:
        t = toks[i]
        if t == "-C" and i + 1 < n:
            cpath = toks[i + 1]; i += 2; continue
        if t.startswith("-C") and len(t) > 2:
            cpath = t[2:]; i += 1; continue
        if t in VAL_OPTS and i + 1 < n:
            i += 2; continue
        if t.startswith("--") and "=" in t:
            i += 1; continue
        if t.startswith("-"):
            i += 1; continue
        return t, cpath, i
    return None, cpath, n

i, n = 0, len(toks)
while i < n:
    if os.path.basename(toks[i]) == "git":
        sub, cpath, subidx = scan(i + 1)
        if sub == "push":
            rest = toks[subidx + 1:]
            nov = "1" if "--no-verify" in rest else "0"
            # Positional args after `push` are <remote> [<refspec>…]. A refspec that names a
            # source ref other than HEAD is out of scope — see the header.
            pos = [t for t in rest if not t.startswith("-")]
            foreign = "0"
            for t in pos[1:]:
                src = t.split(":", 1)[0].lstrip("+")
                if src and src != "HEAD":
                    foreign = "1"
            print("PUSH\t%s\t%s\t%s" % (cpath, nov, foreign)); sys.exit(0)
    i += 1
print("NOTPUSH")
PY
)"

case "$parsed" in
  NOTPUSH|"") allow ;;
esac

IFS=$'\t' read -r _kind cpath noverify foreign <<EOF
$parsed
EOF

[ "${noverify:-0}" = "1" ] && allow
[ "${foreign:-0}" = "1" ] && allow

# ── resolve the target repo ─────────────────────────────────────────────────────────────────
repo="$cpath"
[ -z "$repo" ] && repo="$cwd"
[ -z "$repo" ] && repo="$PWD"
git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || allow
root="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$root" ] && repo="$root"

MAP_NAME="${AGENT_NOTEPAD_DOCS_MAP:-docs-map.json}"
MAP="$repo/.claude/$MAP_NAME"
[ -f "$MAP" ] || allow     # ← the abstain that makes this gate safe to ship

# ── resolve the push range ──────────────────────────────────────────────────────────────────
base=""
if git -C "$repo" rev-parse --verify --quiet '@{u}' >/dev/null 2>&1; then
  base="@{u}"
else
  # No upstream: the branch is being created by this very push. Fall back to the remote's
  # default branch so the ordinary new-branch case is judged rather than skipped.
  for cand in "$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" \
              origin/main origin/master; do
    [ -n "$cand" ] || continue
    if git -C "$repo" rev-parse --verify --quiet "$cand" >/dev/null 2>&1; then base="$cand"; break; fi
  done
fi
[ -n "$base" ] || allow

changed="$(git -C "$repo" diff --name-only --diff-filter=ACMR "$base..HEAD" 2>/dev/null | sed '/^$/d')"
[ -z "$changed" ] && allow

# ── evaluate the rules ──────────────────────────────────────────────────────────────────────
# Verdict text is produced by python (glob translation and `$1` capture are not shell work) and
# printed as: `BLOCK\n<text>` / `WARN\n<text>` / `OK`.
# ⚠️ The change set arrives in the ENVIRONMENT, not on stdin. The script itself is fed to
# python on stdin by the heredoc, so `sys.stdin.read()` here returns nothing — measured, after
# the first version of this hook silently evaluated an empty file list and allowed every push.
# An empty list is indistinguishable from "no violations", which is the worst possible way for
# a gate to be broken.
verdict="$(AGENT_NOTEPAD_CHANGED="$changed" python3 - "$MAP" "$repo" <<'PY'
import json, os, re, sys

map_path, repo = sys.argv[1], sys.argv[2]
changed = [l for l in os.environ.get("AGENT_NOTEPAD_CHANGED", "").split("\n") if l.strip()]
if not changed:
    print("OK"); sys.exit(0)

try:
    with open(map_path, encoding="utf-8") as fh:
        doc = json.load(fh)
except Exception as exc:
    # A malformed map is NOT a silent allow and NOT a block: it is a configuration error the
    # operator has to see, and blocking every push on a typo is how a gate gets turned off.
    print("WARN")
    print("agent-notepad push gate: %s could not be read (%s). No rules were applied to this "
          "push — fix the file or the gate is decorative." % (map_path, exc))
    sys.exit(0)

rules = doc.get("rules") or []
if not isinstance(rules, list) or not rules:
    print("OK"); sys.exit(0)

def to_regex(glob):
    """Translate a path glob, capturing what the FIRST single `*` matches as group 1.

    `**` spans separators, a single `*` and `?` do not — the distinction `fnmatch` does not
    make, and without it `skills/*/**` would match every path in the repo.
    """
    out, i, n, capped = [], 0, len(glob), False
    while i < n:
        c = glob[i]
        if c == "*":
            if i + 1 < n and glob[i + 1] == "*":
                out.append(".*"); i += 2; continue
            if not capped:
                out.append("([^/]*)"); capped = True
            else:
                out.append("[^/]*")
            i += 1; continue
        if c == "?":
            out.append("[^/]"); i += 1; continue
        out.append(re.escape(c)); i += 1
    return re.compile("^" + "".join(out) + "$")

blocks, warns = [], []
for rule in rules:
    if not isinstance(rule, dict):
        continue
    when = rule.get("when")
    requires = rule.get("requires") or []
    level = (rule.get("level") or "block").lower()
    if not when or not isinstance(requires, list):
        continue
    wre = to_regex(when)

    # Group the triggering paths by their capture, so a rule with `$1` asks for one doc PER
    # matched thing rather than one doc for the lot.
    triggers = {}
    for f in changed:
        m = wre.match(f)
        if m:
            cap = m.group(1) if m.groups() else ""
            triggers.setdefault(cap, []).append(f)
    if not triggers:
        continue

    for cap, files in sorted(triggers.items()):
        wanted = [r.replace("$1", cap) for r in requires]
        if any(to_regex(w).match(f) for w in wanted for f in changed):
            continue
        entry = (when, files, wanted)
        (warns if level == "warn" else blocks).append(entry)

def render(entries, verb):
    out = []
    for when, files, wanted in entries:
        out.append("  %s `%s` changed:" % (verb, when))
        for f in files[:6]:
            out.append("      %s" % f)
        if len(files) > 6:
            out.append("      … and %d more" % (len(files) - 6))
        out.append("    but none of these moved with it: %s" % ", ".join(wanted))
    return "\n".join(out)

if blocks:
    text = ["Push blocked by agent-notepad: this range changes a declared area and its "
            "declared doc did not move.", ""]
    text.append(render(blocks, "rule"))
    if warns:
        text += ["", "Also flagged, not blocking:", render(warns, "rule")]
    text += ["",
             "Rules: %s" % map_path,
             "⚠️ This proves a doc MOVED, not that it is RIGHT — one character passes. It "
             "catches the mechanical case only.",
             "Fix: update the doc and include it in this push. Bypass (intentional): "
             "--no-verify, or AGENT_NOTEPAD_PUSH_GATE=off."]
    print("BLOCK"); print("\n".join(text)); sys.exit(0)

if warns:
    text = ["agent-notepad push gate — not blocking, but the docs for this range did not move:",
            "", render(warns, "rule"), "", "Rules: %s" % map_path]
    print("WARN"); print("\n".join(text)); sys.exit(0)

print("OK")
PY
)"

kind="$(printf '%s' "$verdict" | head -1)"
body="$(printf '%s' "$verdict" | tail -n +2)"
case "$kind" in
  BLOCK) block "$body" ;;
  WARN)  warn_only "$body" ;;
esac
allow
