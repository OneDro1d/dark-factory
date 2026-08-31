#!/usr/bin/env bash
# U9 — /handoff retarget test (DESIGN §9, acceptance crit 8).
#
# Asserts the publish-handoff helper:
#   - writes the structured handoff doc to <notepad>/handoffs/<date>-<topic>.md
#     (NOT a temp/OS dir — the file lands INSIDE the notepad),
#   - redacts secrets from the body,
#   - stages + commits the notepad,
#   - FORCES a git push (attempted + logged; observable against a stub remote),
#   - stays best-effort: with NO remote it still writes+commits and exits 0.
#   - SKILL.md exists with valid frontmatter and states the Notes-vs-Handoff split.
#
# TEMP-ONLY & SAFE: every git repo is a throwaway `mktemp -d`; the "remote" is a
# local bare repo (stub) — never a real repo, never a real remote, no ~/.claude.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
LIB="$ROOT/lib/publish-handoff.sh"
SKILL="$ROOT/skills/handoff/SKILL.md"
. "$HERE/assert.sh"

# Isolated git identity so temp commits don't depend on the user's global config.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# ⚠️ AND AN ISOLATED BRANCH NAME, FOR THE SAME REASON — added 2026-08-31 after this unit
# passed on a laptop and failed the first time it ever ran in CI.
#
# The fixture below pushes the seed with `HEAD:main`, so the bare remote gets a branch called
# `main` whatever the LOCAL branch is called. The local name comes from the host's
# `init.defaultBranch`: "main" on the machine this was written on, and git's built-in default
# on a stock runner. When the two differ, `push.default=simple` REFUSES a later bare
# `git push` -- "the upstream branch does not match the name of your current branch" -- so the
# helper's best-effort push silently does nothing, the stub remote never receives the handoff
# commit, and one assertion fails for a reason that lives in somebody's ~/.gitconfig.
#
# The isolated identity above already establishes the principle: a test must not read the
# author's personal git configuration. Branch naming is the same class, and it was missed for
# months because nothing ever ran this suite anywhere else. Each `init` below pins the name at
# the source rather than renaming afterwards, so there is no window in which it is anything
# else.

# _mk_notepad_with_remote -> prints "<notepad>\t<bare-remote>"
# A temp notepad git repo (NOTES.md marker) wired to a local bare repo as origin.
_mk_notepad_with_remote() {
  local base np remote
  base="$(mktemp -d)"
  np="$base/proj-arbbot"
  remote="$base/origin.git"
  mkdir -p "$np/sessions"
  : > "$np/NOTES.md"
  printf '[]\n' > "$np/sessions/index.json"
  git -c init.defaultBranch=main -C "$np" init -q
  git -C "$np" add -A >/dev/null 2>&1
  git -C "$np" commit -qm seed >/dev/null 2>&1
  git init --bare -q "$remote"
  git -C "$np" remote add origin "$remote"
  # No `|| HEAD:master` fallback any more: the branch is pinned to main above, so a
  # fallback could only mask the very drift this fixture now controls for.
  git -C "$np" push -q -u origin HEAD:main >/dev/null 2>&1
  printf '%s\t%s' "$np" "$remote"
}

_mk_notepad_no_remote() { # prints notepad root (no origin configured)
  local base np
  base="$(mktemp -d)"
  np="$base/proj-bugs"
  mkdir -p "$np/sessions"
  : > "$np/NOTES.md"
  git -c init.defaultBranch=main -C "$np" init -q
  git -C "$np" add -A >/dev/null 2>&1
  git -C "$np" commit -qm seed >/dev/null 2>&1
  printf '%s' "$np"
}

# ── (0) artifacts exist ─────────────────────────────────────────────────────
test_helper_and_skill_exist() {
  assert_file_exists "$LIB" "lib/publish-handoff.sh exists"
  if [ -x "$LIB" ]; then _pass; else _fail "lib/publish-handoff.sh is executable"; fi
  ASSERT_CASES=$((ASSERT_CASES + 1))
  assert_file_exists "$SKILL" "skills/handoff/SKILL.md exists"
}

# ── (1) SKILL.md has valid frontmatter + Notes-vs-Handoff split ─────────────
test_skill_frontmatter_and_terminology() {
  local body first name desc
  first="$(head -1 "$SKILL")"
  assert_eq "---" "$first" "SKILL.md opens with YAML frontmatter fence"
  name="$(sed -n 's/^name:[[:space:]]*//p' "$SKILL" | head -1)"
  desc="$(sed -n 's/^description:[[:space:]]*//p' "$SKILL" | head -1)"
  assert_eq "handoff" "$name" "frontmatter name is 'handoff'"
  if [ -n "$desc" ]; then _pass; else _fail "frontmatter has a description"; fi
  ASSERT_CASES=$((ASSERT_CASES + 1))
  body="$(cat "$SKILL")"
  # the terminology split must be stated (Notes = continuous, Handoff = deliberate)
  assert_contains "$body" "Notes" "SKILL states the Notes tier"
  assert_contains "$body" "Handoff" "SKILL states the Handoff tier"
  assert_contains "$body" "handoffs/" "SKILL targets the handoffs/ dir (not temp)"
  assert_contains "$body" "push" "SKILL states it forces a push"
}

# ── (2) publish writes into the notepad, redacts, commits, PUSHES ──────────
test_publish_writes_commits_and_pushes() {
  local pair np remote plog body out hf
  pair="$(_mk_notepad_with_remote)"
  np="${pair%%$'\t'*}"; remote="${pair##*$'\t'}"
  plog="$(mktemp)"; rm -f "$plog"
  export AGENT_NOTEPAD_PUSH_LOG="$plog"
  export AGENT_NOTEPAD_DATE="2026-07-10"    # deterministic filename for the test

  # a body carrying a secret literal (prefix split so push-protection can't flag it)
  local ghp; ghp="ghp""_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
  body="Objective: ship the arb bot. token=$ghp
Next: wire the router."

  out="$(printf '%s' "$body" | "$LIB" "$np" "Arb Bot Milestone")"
  RC=$?
  assert_eq "0" "$RC" "publish exits 0"

  hf="$np/handoffs/2026-07-10-arb-bot-milestone.md"
  assert_file_exists "$hf" "handoff doc written under <notepad>/handoffs/<date>-<topic>.md"
  # helper echoes the path it wrote
  assert_contains "$out" "$hf" "helper prints the handoff path"
  # file is INSIDE the notepad, not a temp/OS dir
  assert_contains "$hf" "$np/handoffs/" "handoff path is inside the notepad (not temp)"

  local content; content="$(cat "$hf")"
  assert_contains "$content" "Arb Bot Milestone" "handoff carries the topic title"
  assert_contains "$content" "ship the arb bot" "handoff carries the body"
  assert_not_contains "$content" "$ghp" "handoff redacts the secret literal"
  assert_contains "$content" "[REDACTED]" "redaction marker present"

  # committed in the notepad
  local subj; subj="$(git -C "$np" log -1 --pretty=%s 2>/dev/null)"
  assert_contains "$subj" "handoff" "a handoff commit was made in the notepad"
  # the handoff file is tracked (committed), not left dangling
  git -C "$np" ls-files --error-unmatch "handoffs/2026-07-10-arb-bot-milestone.md" >/dev/null 2>&1
  assert_eq "0" "$?" "handoff file is committed (tracked)"

  # PUSH forced + logged
  assert_file_exists "$plog" "push was logged (attempt recorded)"
  assert_contains "$(cat "$plog")" "PUSH" "push attempt logged"
  # the stub remote actually received the handoff commit (real push landed)
  local rem_has; rem_has="$(git -C "$remote" log --all --pretty=%s 2>/dev/null | grep -c handoff)"
  if [ "${rem_has:-0}" -ge 1 ]; then
    _pass
  else
    # ⚠️ DUMP THE EVIDENCE, do not just say "no". This assertion failed in CI on 2026-08-31
    # and passed on the machine that wrote it, and the message alone could not tell the two
    # apart -- a whole round-trip bought the word "no". Two hypotheses were tried against a
    # simulated runner and NEITHER reproduced, which is itself the lesson: the machine that
    # cannot reproduce the failure cannot diagnose it either, so the failure has to carry its
    # own evidence out.
    _fail "stub remote received the handoff commit"
    echo "      local branch:  $(git -C "$np" symbolic-ref --short HEAD 2>&1)"
    echo "      upstream:      $(git -C "$np" rev-parse --abbrev-ref '@{u}' 2>&1)"
    echo "      remote refs:   $(git -C "$remote" for-each-ref --format='%(refname:short)' 2>&1 | tr '\n' ' ')"
    echo "      local log:     $(git -C "$np" log --oneline -3 2>&1 | tr '\n' '|')"
    echo "      push log:      $(cat "$plog" 2>&1 | tr '\n' '|')"
    echo "      push retry:    $(git -C "$np" push 2>&1 | head -3 | tr '\n' '|')"
    echo "      git version:   $(git --version 2>&1)"
  fi
  ASSERT_CASES=$((ASSERT_CASES + 1))

  rm -rf "$(dirname "$np")" "$plog"
  unset AGENT_NOTEPAD_PUSH_LOG AGENT_NOTEPAD_DATE
}

# ── (3) best-effort: no remote → still writes+commits, exits 0 ─────────────
test_publish_best_effort_without_remote() {
  local np plog out hf
  np="$(_mk_notepad_no_remote)"
  plog="$(mktemp)"; rm -f "$plog"
  export AGENT_NOTEPAD_PUSH_LOG="$plog"
  export AGENT_NOTEPAD_DATE="2026-07-10"

  out="$(printf 'Objective: fix the bug.\n' | "$LIB" "$np" "Bug Fix")"
  RC=$?
  assert_eq "0" "$RC" "publish exits 0 even with no remote (best-effort)"
  hf="$np/handoffs/2026-07-10-bug-fix.md"
  assert_file_exists "$hf" "handoff written even without a remote"
  local subj; subj="$(git -C "$np" log -1 --pretty=%s 2>/dev/null)"
  assert_contains "$subj" "handoff" "commit still made without a remote"
  # push attempt was still made/logged (it just fails gracefully)
  assert_contains "$(cat "$plog")" "PUSH" "push still attempted+logged without a remote"

  rm -rf "$(dirname "$np")" "$plog"
  unset AGENT_NOTEPAD_PUSH_LOG AGENT_NOTEPAD_DATE
}

# ── (4) refuses outside a notepad (no NOTES.md) → exit non-zero, no write ───
test_publish_refuses_outside_notepad() {
  local d out
  d="$(mktemp -d)"                 # NOT a notepad
  out="$(printf 'x\n' | "$LIB" "$d" "Nope" 2>&1)"
  RC=$?
  if [ "$RC" -ne 0 ]; then _pass; else _fail "publish refuses outside a notepad (non-zero exit)"; fi
  ASSERT_CASES=$((ASSERT_CASES + 1))
  if [ ! -d "$d/handoffs" ]; then _pass; else _fail "no handoffs/ dir created outside a notepad"; fi
  ASSERT_CASES=$((ASSERT_CASES + 1))
  rm -rf "$d"
}

run_tests
