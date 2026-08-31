#!/usr/bin/env bash
# U8 — push gate test (DESIGN §7.7, scope-init §6a).
#
# TEMP-ONLY & SAFE: every repo is a throwaway `mktemp -d`; the "remote" is a bare temp repo;
# the hook is driven purely by piped stdin JSON. Nothing here can reach a real remote — the
# fixtures never contain one.
#
# WHAT IS PINNED, AND WHY EACH CASE HAS A TWIN. This gate's whole safety rests on abstaining,
# so almost every assertion here is "it did NOT fire", and a hook that returned `{}`
# unconditionally would sail through them. Each abstain therefore has a matched case that
# MUST block on the same fixture with one thing changed — the file present, the rule level
# raised, the doc removed from the push. A suite of green abstains proves nothing.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
HOOKS="$ROOT/hooks"
GATE="$HOOKS/push-gate.sh"
. "$HERE/assert.sh"

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

run_hook() { OUT="$(printf '%s' "$2" | "$1" 2>/dev/null)"; RC=$?; }

# _mkrepo -> a temp repo whose `main` is pushed to a bare remote, so `@{u}` resolves and the
# push range is real rather than simulated.
_mkrepo() {
  local base bare work
  base="$(mktemp -d)"; bare="$base/remote.git"; work="$base/work"
  git init -q --bare "$bare"
  git init -q -b main "$work"
  mkdir -p "$work/skills/alpha" "$work/docs" "$work/.claude"
  printf 'seed\n' > "$work/README.md"
  printf '# alpha\n' > "$work/skills/alpha/SKILL.md"
  printf '# index\n' > "$work/docs/index.md"
  git -C "$work" add -A >/dev/null 2>&1
  git -C "$work" commit -qm seed >/dev/null 2>&1
  git -C "$work" remote add origin "$bare"
  git -C "$work" push -q -u origin main >/dev/null 2>&1
  printf '%s' "$work"
}

# _map <repo> <level> — the FIXTURE policy. Deliberately not any real repo's: the question of
# which docs a given repo must carry is the operator's, and inventing one here would ship a
# policy nobody chose under cover of a test.
_map() {
  cat > "$1/.claude/docs-map.json" <<MAP
{
  "\$comment": "fixture policy — test only",
  "rules": [
    { "when": "skills/*/**", "requires": ["skills/\$1/SKILL.md"], "level": "$2" },
    { "when": "services/**", "requires": ["docs/index.md"], "level": "$2" }
  ]
}
MAP
  git -C "$1" add -A >/dev/null 2>&1
  git -C "$1" commit -qm map >/dev/null 2>&1
  git -C "$1" push -q origin main >/dev/null 2>&1
}

_push_json() { printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s push"},"cwd":"%s"}' "$1" "$1"; }

# ── (a) not a push at all ───────────────────────────────────────────────────
test_push_noncommand_allows() {
  run_hook "$GATE" '{"tool_name":"Bash","tool_input":{"command":"ls -la /tmp"},"cwd":"/tmp"}'
  assert_eq "0" "$RC" "non-push: exit 0"
  assert_eq "{}" "$OUT" "non-push: emits {} (allow)"
}

test_push_git_status_allows() {
  run_hook "$GATE" '{"tool_name":"Bash","tool_input":{"command":"git -C /tmp status"},"cwd":"/tmp"}'
  assert_eq "{}" "$OUT" "git status is not a push → {}"
}

# ── (b) NO MAP MEANS ABSTAIN — and its twin, which proves the abstain is the map's doing ────
test_push_no_map_abstains() {
  local repo; repo="$(_mkrepo)"
  mkdir -p "$repo/services"; printf 'svc\n' > "$repo/services/a.go"
  git -C "$repo" add -A >/dev/null 2>&1; git -C "$repo" commit -qm svc >/dev/null 2>&1
  run_hook "$GATE" "$(_push_json "$repo")"
  assert_eq "{}" "$OUT" "no docs-map.json → abstain, never a default rule set"
  rm -rf "$(dirname "$repo")"
}

test_push_same_change_with_map_blocks() {
  local repo; repo="$(_mkrepo)"
  _map "$repo" block
  mkdir -p "$repo/services"; printf 'svc\n' > "$repo/services/a.go"
  git -C "$repo" add -A >/dev/null 2>&1; git -C "$repo" commit -qm svc >/dev/null 2>&1
  run_hook "$GATE" "$(_push_json "$repo")"
  assert_contains "$OUT" "Push blocked by agent-notepad" "the SAME change blocks once a map exists"
  assert_contains "$OUT" "services/a.go" "the reason names the file that triggered it"
  assert_contains "$OUT" "docs/index.md" "and names the doc that did not move"
  rm -rf "$(dirname "$repo")"
}

# ── (c) the doc moving with the change clears it ────────────────────────────
test_push_doc_moved_allows() {
  local repo; repo="$(_mkrepo)"
  _map "$repo" block
  mkdir -p "$repo/services"; printf 'svc\n' > "$repo/services/a.go"
  printf '# index\nupdated\n' > "$repo/docs/index.md"
  git -C "$repo" add -A >/dev/null 2>&1; git -C "$repo" commit -qm svc+doc >/dev/null 2>&1
  run_hook "$GATE" "$(_push_json "$repo")"
  assert_eq "{}" "$OUT" "code + its declared doc in one push → allow"
  rm -rf "$(dirname "$repo")"
}

# ── (d) `$1` capture: the doc must be the CHANGED skill's own ───────────────
# Without the capture, any SKILL.md anywhere would satisfy the rule, and a rule that accepts
# an unrelated file is worse than no rule: it reports as enforcement.
test_push_capture_wants_the_right_doc() {
  local repo; repo="$(_mkrepo)"
  _map "$repo" block
  mkdir -p "$repo/skills/beta"
  printf 'x\n' > "$repo/skills/beta/impl.sh"
  printf '# alpha changed\n' > "$repo/skills/alpha/SKILL.md"   # the WRONG skill's doc
  git -C "$repo" add -A >/dev/null 2>&1; git -C "$repo" commit -qm beta >/dev/null 2>&1
  run_hook "$GATE" "$(_push_json "$repo")"
  assert_contains "$OUT" "Push blocked by agent-notepad" "another skill's SKILL.md does not satisfy \$1"
  assert_contains "$OUT" "skills/beta/SKILL.md" "the reason names the doc it actually wanted"
  rm -rf "$(dirname "$repo")"
}

test_push_capture_satisfied_allows() {
  local repo; repo="$(_mkrepo)"
  _map "$repo" block
  mkdir -p "$repo/skills/beta"
  printf 'x\n' > "$repo/skills/beta/impl.sh"
  printf '# beta\n' > "$repo/skills/beta/SKILL.md"
  git -C "$repo" add -A >/dev/null 2>&1; git -C "$repo" commit -qm beta >/dev/null 2>&1
  run_hook "$GATE" "$(_push_json "$repo")"
  assert_eq "{}" "$OUT" "the changed skill's OWN doc satisfies it"
  rm -rf "$(dirname "$repo")"
}

# ── (e) level: warn does not block, and is not silent either ────────────────
test_push_warn_does_not_block() {
  local repo; repo="$(_mkrepo)"
  _map "$repo" warn
  mkdir -p "$repo/services"; printf 'svc\n' > "$repo/services/a.go"
  git -C "$repo" add -A >/dev/null 2>&1; git -C "$repo" commit -qm svc >/dev/null 2>&1
  run_hook "$GATE" "$(_push_json "$repo")"
  assert_not_contains "$OUT" "Push blocked by agent-notepad" "level warn does not block"
  assert_contains "$OUT" "systemMessage" "…and does not vanish either"
  rm -rf "$(dirname "$repo")"
}

# ── (f) --no-verify is an explicit, documented bypass ───────────────────────
test_push_no_verify_bypasses() {
  local repo; repo="$(_mkrepo)"
  _map "$repo" block
  mkdir -p "$repo/services"; printf 'svc\n' > "$repo/services/a.go"
  git -C "$repo" add -A >/dev/null 2>&1; git -C "$repo" commit -qm svc >/dev/null 2>&1
  run_hook "$GATE" "$(printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s push --no-verify"},"cwd":"%s"}' "$repo" "$repo")"
  assert_eq "{}" "$OUT" "--no-verify bypasses, as documented"
  rm -rf "$(dirname "$repo")"
}

test_push_env_off_bypasses() {
  local repo; repo="$(_mkrepo)"
  _map "$repo" block
  mkdir -p "$repo/services"; printf 'svc\n' > "$repo/services/a.go"
  git -C "$repo" add -A >/dev/null 2>&1; git -C "$repo" commit -qm svc >/dev/null 2>&1
  OUT="$(printf '%s' "$(_push_json "$repo")" | AGENT_NOTEPAD_PUSH_GATE=off "$GATE" 2>/dev/null)"
  assert_eq "{}" "$OUT" "AGENT_NOTEPAD_PUSH_GATE=off disables it"
  rm -rf "$(dirname "$repo")"
}

# ── (g) a push naming some OTHER ref is out of scope ────────────────────────
# It is not judging HEAD, and reporting on the wrong commits is worse than not reporting.
test_push_foreign_refspec_abstains() {
  local repo; repo="$(_mkrepo)"
  _map "$repo" block
  mkdir -p "$repo/services"; printf 'svc\n' > "$repo/services/a.go"
  git -C "$repo" add -A >/dev/null 2>&1; git -C "$repo" commit -qm svc >/dev/null 2>&1
  run_hook "$GATE" "$(printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s push origin other-branch:main"},"cwd":"%s"}' "$repo" "$repo")"
  assert_eq "{}" "$OUT" "a refspec naming another source ref → abstain"
  # …and the twin, so "out of scope" cannot quietly become "never fires".
  run_hook "$GATE" "$(printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s push origin HEAD"},"cwd":"%s"}' "$repo" "$repo")"
  assert_contains "$OUT" "Push blocked by agent-notepad" "an explicit HEAD refspec is still judged"
  rm -rf "$(dirname "$repo")"
}

# ── (h) a branch with no upstream is judged, not skipped ────────────────────
# The push that CREATES a branch is the one a naive `@{u}` implementation would abstain on —
# and it is the push that carries the whole feature.
test_push_new_branch_uses_default_base() {
  local repo; repo="$(_mkrepo)"
  _map "$repo" block
  git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main >/dev/null 2>&1
  git -C "$repo" checkout -q -b feat/new
  mkdir -p "$repo/services"; printf 'svc\n' > "$repo/services/a.go"
  git -C "$repo" add -A >/dev/null 2>&1; git -C "$repo" commit -qm svc >/dev/null 2>&1
  run_hook "$GATE" "$(_push_json "$repo")"
  assert_contains "$OUT" "Push blocked by agent-notepad" "no upstream → falls back to origin/HEAD, still judged"
  rm -rf "$(dirname "$repo")"
}

# ── (i) a malformed map is a visible configuration error, not a silent pass ──
test_push_broken_map_warns() {
  local repo; repo="$(_mkrepo)"
  printf '{ this is not json\n' > "$repo/.claude/docs-map.json"
  git -C "$repo" add -A >/dev/null 2>&1; git -C "$repo" commit -qm badmap >/dev/null 2>&1
  mkdir -p "$repo/services"; printf 'svc\n' > "$repo/services/a.go"
  git -C "$repo" add -A >/dev/null 2>&1; git -C "$repo" commit -qm svc >/dev/null 2>&1
  run_hook "$GATE" "$(_push_json "$repo")"
  assert_not_contains "$OUT" "Push blocked by agent-notepad" "a typo in the map does not block every push"
  assert_contains "$OUT" "systemMessage" "…but it is reported, not swallowed"
  rm -rf "$(dirname "$repo")"
}

# ── (j) the caveat that must survive every rewrite ──────────────────────────
# The hook's own text has to keep saying what a green push does NOT mean. If this assertion
# ever fails, someone trimmed the one sentence that stops the gate being over-read.
test_push_reason_disclaims_correctness() {
  local repo; repo="$(_mkrepo)"
  _map "$repo" block
  mkdir -p "$repo/services"; printf 'svc\n' > "$repo/services/a.go"
  git -C "$repo" add -A >/dev/null 2>&1; git -C "$repo" commit -qm svc >/dev/null 2>&1
  run_hook "$GATE" "$(_push_json "$repo")"
  assert_contains "$OUT" "MOVED" "the block text says it proves a doc MOVED, not that it is right"
  rm -rf "$(dirname "$repo")"
}

run_tests
