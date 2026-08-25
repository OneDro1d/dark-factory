#!/usr/bin/env bash
# publish-gate.sh — MUST pass before this repo is made public.
#
# This repo is built by SELECTION into a fresh `git init`, never by cloning a private
# repo and deleting the private parts — deletion does not remove git history. This gate
# is the second control: it scans the WORKING TREE and the FULL GIT HISTORY for anything
# that must not become world-readable.
#
# Design note: name-based exclusion is not a boundary. The 2026-07-12 leak came through
# generically-NAMED skills carrying client content — the name is not the boundary, the
# contents are. So this scans for LANDMARKS — concrete nouns that can only come from one
# estate — not for vocabulary. A doc explaining "how to model a patient record" is fine;
# a doc containing an internal programme code or a real cluster ARN is not.
#
# Usage: bash boot-kit/scripts/publish-gate.sh [--history]
# Exit:  0 = clean   1 = findings (do NOT publish)
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF/../.." && pwd)"
SCAN_HISTORY=0
[ "${1:-}" = "--history" ] && SCAN_HISTORY=1

FAIL=0
hit()  { printf 'FAIL  %s\n' "$1"; FAIL=1; }
pass() { printf 'PASS  %s\n' "$1"; }
note() { printf '        %s\n' "$1"; }
# A finding that is NOT a publish blocker. Kept distinct from hit() on purpose: folding
# a fact-about-this-clone into the fatal class is what made the gate unfixable-by-design.
warn() { printf 'WARN  %s\n' "$1"; }

# Two files exist to ENUMERATE these patterns, so they match by construction:
#   - this script (the patterns themselves)
#   - CONTENT-BOUNDARY.md (the landmark-vs-vocabulary table that documents them)
# Excluding them is not a loophole, but it IS a blind spot: a genuine leak pasted into
# either file would be invisible. Both are short and must be read by eye before publishing
# — that is step 2 of the pre-publish checklist in CONTENT-BOUNDARY.md.
# landmarks.example.conf and landmarks.conf enumerate the patterns, so they match by
# construction exactly as this script and CONTENT-BOUNDARY.md do. landmarks.conf is also
# gitignored (it holds the REAL list); the example holds placeholders only.
EXCL=(
  ':!boot-kit/scripts/publish-gate.sh'
  ':!boot-kit/scripts/landmarks.example.conf'
  ':!boot-kit/scripts/landmarks.conf'
  ':!boot-kit/scripts/gate-selftest.sh'
  ':!CONTENT-BOUNDARY.md'
  # The substrate template's denylist is the same KIND of file as the two above: its
  # content IS a pattern list, so every entry reads as a landmark to a scanner. Only the
  # example is excluded — the real one is gitignored and never reaches a scan.
  #
  # It earns its place here by a failure worth remembering. The example denylist and
  # landmarks.example.conf independently chose the SAME placeholder vocabulary (`acme`,
  # `redcedar`) — the natural choice for a fake client name. So the example landmark
  # scanner matched the example denylist, and CI failed on two placeholder files
  # recognising each other. It passed locally the whole time, because the real
  # landmarks.conf holds real patterns and neither fake name is among them: a
  # gitignored config had made CI and the developer run materially different checks.
  ':!skills/df-context-store/substrate-template/substrate-denylist.example.conf'
)

# P5-only exemptions: files whose JOB is to contain secret-shaped strings.
# handoff-auto redacts secrets from transcripts, so its test vectors and fixture must
# carry things that LOOK like credentials or the tests prove nothing. Deleting them would
# delete the proof that redaction works.
#
# This is an EXPLICIT PATH LIST, not a `tests/` wildcard, and that distinction matters: a
# wildcard would let a real credential dropped into any tests/ directory sail through.
# Three named files can be eyeballed; a pattern cannot. All three were read and confirmed
# synthetic (`sk-secret123ABCdef...`, `Bearer eyJhbGciOi.payload.sig`).
# ── Landmark patterns come from a LOCAL config, never from this script ──────
#
# A landmark list is by construction a list of the exact nouns you do not want
# published — client names, cluster hostnames, registry names, DB project ids.
# Keeping it inline meant that publishing this gate published the directory of
# everything it protects. And the gate CANNOT catch that itself: it excludes
# itself from its own scan (it has to, or it would always match its own
# patterns). A tool cannot audit itself. So the LOGIC is public, the LIST is local.
#
# landmarks.conf is gitignored. Falls back to the committed example — and says
# which it used, because a gate running on placeholder patterns looks exactly
# like a gate running on real ones unless it tells you.
LANDMARKS="$SELF/landmarks.conf"
LANDMARKS_SRC="landmarks.conf"
if [ ! -f "$LANDMARKS" ]; then
  LANDMARKS="$SELF/landmarks.example.conf"
  LANDMARKS_SRC="landmarks.example.conf (PLACEHOLDER PATTERNS — copy to landmarks.conf and edit)"
fi
[ -f "$LANDMARKS" ] || die "no landmark config found at $SELF/landmarks.conf or landmarks.example.conf"
# shellcheck source=/dev/null
. "$LANDMARKS"

for v in P1_PATTERN P2_PATTERN P3_PATTERN P4_PATTERN P5_PATTERN P6_PATTERN P7_PATTERN; do
  eval "val=\${$v:-}"
  [ -n "$val" ] || die "$v is unset or empty in $LANDMARKS — an empty pattern scans nothing and would PASS silently"
done

printf 'landmarks: %s\n\n' "$LANDMARKS_SRC"

# P5-only exemptions: files whose JOB is to contain secret-shaped strings, e.g. the
# redaction tests and fixtures — deleting their test vectors would delete the proof that
# redaction works.
#
# EXPLICIT PATH LIST, never a wildcard: a `tests/` wildcard would let a real credential
# dropped into any tests directory sail through. Named files can be eyeballed on review;
# a pattern cannot.
# ⚠️ EXPANDED AS ${P5_EXCL[@]+"${P5_EXCL[@]}"} AT EVERY CALL SITE, NOT AS "${P5_EXCL[@]}".
# That is not a typo and it must not be "tidied up". bash 3.2 — the /bin/bash on every
# macOS — treats "${arr[@]}" on an EMPTY array as an unbound variable under `set -u`:
#
#     $ bash -c 'set -uo pipefail; A=(); echo "${A[@]}"'
#     bash: A[@]: unbound variable
#
# Every call site sits inside $(...), so the abort killed only the substitution: the scan
# came back EMPTY, and empty output is the CLEAN branch. The gate printed
# `PASS  P5 no secret-shaped strings` over a planted key. P6 and the P8 --history scan had
# the identical defect, and the history one is the worst of the three.
#
# It went unnoticed because these two lists are the one part of the config a reader is
# MEANT to leave out, and every config WE have declares them. A stranger writing their own
# config with nothing to exempt got a gate whose secret and personal-identifier checks were
# both inert while reporting PASS. Pinned by tests/test-publish-gate-empty-exclusions.sh.
P5_EXCL=()
while IFS= read -r _line; do
  [ -n "$_line" ] && P5_EXCL+=("$_line")
done <<EOF
${P5_EXCLUDE:-}
EOF

# P6-only exemptions: the files whose JOB is to publish a contact address.
#
# An open-source repo MUST name somewhere to send a security disclosure and a code-of-conduct
# report; a project that hides its contact address has no disclosure path at all, which is a
# worse failure than the one P6 defends against. A deliberately-published business contact is
# not a leaked personal identifier.
#
# Same discipline as P5_EXCL: an EXPLICIT PATH LIST, never a wildcard. Named files can be
# eyeballed on every review; `*.md` could not, and would let a genuine home path into any doc.
P6_EXCL=()
while IFS= read -r _line; do
  [ -n "$_line" ] && P6_EXCL+=("$_line")
done <<EOF
${P6_EXCLUDE:-}
EOF

scan() {
  local label="$1" pattern="$2"
  local out
  # Use git grep when this IS a git repo, so pathspec exclusions apply. The plain-grep
  # fallback exists only for a not-yet-initialised tree.
  #
  # BUG FIXED 2026-08-02: the fallback used to fire whenever git grep produced no output —
  # i.e. on a CLEAN result — and the fallback does not honour the pathspec exclusions, so
  # it re-reported the excluded files and turned every PASS into a FAIL. A fallback that
  # triggers on success inverts the check it is backing up.
  if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    # --untracked is LOAD-BEARING: `git grep` searches TRACKED files only by default, so
    # without it a brand-new uncommitted file is invisible to this gate. Found 2026-08-02
    # by planting a canary containing a real cluster name, ticket id and token: the gate
    # reported CLEAN. That is the worst possible failure for a pre-publish check — you add
    # a file, the gate blesses it, you publish it. (.gitignore is still honoured.)
    out="$(cd "$REPO" && git grep -n -I -E -i --untracked "$pattern" -- . "${EXCL[@]}" 2>/dev/null | head -12)"
  else
    out="$(grep -rn -I -E -i "$pattern" "$REPO" \
      --exclude-dir=.git --exclude=publish-gate.sh --exclude=CONTENT-BOUNDARY.md 2>/dev/null | head -12)"
  fi
  if [ -n "$out" ]; then
    hit "$label"
    printf '%s\n' "$out" | while IFS= read -r l; do note "${l:0:160}"; done
  else
    pass "$label"
  fi
}

echo "=== publish-gate: $REPO ==="
echo ""

# TUNED 2026-08-02 after the first run. NEMSIS and HIPAA came out: they are PUBLIC
# standards/regulations, and the model docs legitimately cite them as examples in a list
# ("parity bit, type/regex, Schematron, NEMSIS"). Matching them flagged generic teaching
# material as a leak. A public standard NAME is vocabulary; a client's ticket id, app
# hostname or cluster ARN is a LANDMARK. Keep the landmarks, drop the vocabulary —
# otherwise the gate cries wolf and gets ignored, which is worse than not having it.
echo "[P1] Client / programme landmarks"
scan "P1 client landmarks" "$P1_PATTERN"

echo ""
echo "[P2] PHI markers — concrete, not the generic regulatory noun"
# `\bmrn\b` was INERT here from the start: git grep -E is POSIX ERE with no PCRE, so `\b`
# compiles without error and matches ZERO lines. The PHI scan carried a pattern that could
# never fire, and reported PASS every time — the same false-assurance failure as P3.
# `(^|[^A-Za-z])mrn($|[^A-Za-z])` is the POSIX-ERE-safe equivalent that actually works.
# NEVER use `\b` in a scan() pattern. Note plain BSD/GNU `grep -E` DOES honour `\b`, so a
# pattern tested with grep will look fine and then do nothing here — test with git grep.
scan "P2 regulated-data markers" "$P2_PATTERN"

echo ""
echo "[P3] Second-estate landmarks"
# THE LITERAL CLIENT/PRODUCT NAME IS THE LANDMARK, not just its infra ids. This pattern
# once matched only infra identifiers (repo/db/project names) and never the name itself, so
# every file that said the name plainly in prose — skill docs, templates, architecture
# notes — sailed through as CLEAN. Include the name.
#
# WORD BOUNDARIES: never use `\b` in a pattern here. `git grep -E` is POSIX ERE with no
# PCRE, so `\b` compiles without error and matches ZERO lines — an inert pattern that looks
# correct. (Plain BSD/GNU `grep -E` DOES honour it, so testing with grep will mislead you.)
# A bare substring is the opposite failure: a short client name matched unanchored will
# also hit ordinary English words that merely contain it, which is vocabulary rather than
# a landmark — the false positive CONTENT-BOUNDARY.md warns about, and a gate that cries
# wolf gets ignored.
#
# Use `(^|[^A-Za-z])name($|[^A-Za-z])`. It is the POSIX-ERE-safe word boundary that works
# under this engine, and it excludes the substring case.
scan "P3 second-estate landmarks" "$P3_PATTERN"

echo ""
echo "[P4] Private infrastructure identifiers"
scan "P4 infra ids" "$P4_PATTERN"

echo ""
# The PEM header is ANCHORED to line start. A real key block begins the line; a skill that
# documents WHAT TO REDACT necessarily names the header inline in prose ("private keys
# (-----BEGIN PRIVATE KEY-----)"). Unanchored, the gate flagged the redaction documentation
# as the thing it is telling you to redact. Same precision-vs-recall call as NEMSIS/HIPAA.
echo "[P5] Secret-shaped strings"
P5_PAT="$P5_PATTERN"
P5_OUT="$(cd "$REPO" && git grep -n -I -E -i --untracked "$P5_PAT" -- . "${EXCL[@]}" ${P5_EXCL[@]+"${P5_EXCL[@]}"} 2>/dev/null | head -12)"
if [ -n "$P5_OUT" ]; then
  hit "P5 secrets"
  printf '%s\n' "$P5_OUT" | while IFS= read -r l; do note "${l:0:160}"; done
else
  pass "P5 no secret-shaped strings (3 redaction test vectors exempted by name)"
fi

echo ""
echo "[P6] Personal / machine-local identifiers"
P6_PAT="$P6_PATTERN"
P6_OUT="$(cd "$REPO" && git grep -n -I -E -i --untracked "$P6_PAT" -- . "${EXCL[@]}" ${P6_EXCL[@]+"${P6_EXCL[@]}"} 2>/dev/null | head -12)"
if [ -n "$P6_OUT" ]; then
  hit "P6 personal"
  printf '%s\n' "$P6_OUT" | while IFS= read -r l; do note "${l:0:160}"; done
else
  pass "P6 personal (SECURITY.md + CODE_OF_CONDUCT.md exempted by name — see P6_EXCL)"
fi

echo ""
# Placeholder tenants (your-org, example, acme, <SPACE>) are documentation, not a leak.
# A real tenant name is the landmark; `your-org.atlassian.net` in a URL template is the
# opposite — it is the generic form we WANT.
echo "[P7] Internal trackers and boards"
# NB: POSIX ERE has no negative lookahead — the placeholder exemption is done by a
# second grep below, not inline. An inline (?!…) would be silently mis-parsed by grep -E.
scan "P7 tracker ids" "$P7_PATTERN"
TRACKER_EXTRA="$(cd "$REPO" && git grep -n -I -E --untracked '[a-z0-9-]+\.atlassian\.net' -- . "${EXCL[@]}" 2>/dev/null | grep -vE 'your-org|example|acme|<[A-Z]' || true)"
if [ -n "$TRACKER_EXTRA" ]; then
  hit "P7 a CONCRETE atlassian tenant is named"
  printf '%s\n' "$TRACKER_EXTRA" | while IFS= read -r l; do note "${l:0:160}"; done
fi

if [ "$SCAN_HISTORY" -eq 1 ]; then
  echo ""
  echo "[P8] FULL GIT HISTORY (every blob ever committed)"
  BLOBS="$(cd "$REPO" && git rev-list --all --objects 2>/dev/null | wc -l | tr -d ' ')"
  # The PEM pattern is ANCHORED here too. P5 was anchored on 2026-08-02 but this one was
  # not, so the history scan kept flagging the skill that DOCUMENTS what to redact. Two
  # scans of the same repo must not disagree about what counts as a secret — a gate that
  # contradicts itself is one you learn to override.
  # P8's pattern is DERIVED from the same config as P1-P7, never hand-maintained.
  # It used to be a hand-written subset, which meant the history scan could silently
  # drift from the tree scan — and it did: when P3 was widened to catch a product name,
  # P8 kept the old narrow list and went on reporting clean. Two scans of one repo must
  # not disagree about what a landmark is.
  #
  # AND IT MUST INHERIT P5's EXEMPTIONS ALONG WITH P5's PATTERN. Deriving the pattern
  # without the excludes made P8 flag the very redaction test vectors P5 deliberately
  # allows — the two scans disagreeing about what counts as a secret, which is precisely
  # the failure the paragraph above describes. Fixing one half of a rule and not the
  # other is how a gate ends up contradicting itself.
  HIST_PAT="${P1_PATTERN}|${P2_PATTERN}|${P3_PATTERN}|${P4_PATTERN}|${P5_PATTERN}"

  # ── REACHABILITY CLASSES ────────────────────────────────────────────────────
  # `git rev-list --all` is every commit in THIS CLONE, which is not the same set as
  # "what the world can fetch". A clone accumulates local-only branches — reviewed,
  # merged upstream, their remote refs long since pruned — and those commits stay in
  # the object store forever. Scanning them and calling the result "history" made the
  # gate report a leak that does not exist upstream, and then prescribe an IRREVERSIBLE
  # remedy ("rebuild from a fresh git init") for it. A gate that fires on something the
  # maintainer cannot fix is one people learn to override, which is how the next real
  # finding gets waved through. So classify by REACHABILITY, and let the class pick both
  # the severity and the remedy:
  #
  #   PUBLISHED  reachable from a remote-tracking ref — already fetchable by anyone.
  #              FATAL, and genuinely unfixable by patching.
  #   PENDING    reachable from HEAD but not from any remote — about to be published by
  #              the next push. FATAL, but fixable here: drop the commit before pushing.
  #   LOCAL-ONLY reachable from neither — present in this clone and nowhere else.
  #              A fact about this working copy, NOT a publish blocker. Warn, name it.
  #
  # The distinction requires remote-tracking refs to exist. Where there are none we
  # cannot tell published from unpublished, and an UNKNOWN must never be recorded as an
  # OK — so that case falls back to the old behaviour: scan everything, fail hard.
  REMOTE_REFS="$(cd "$REPO" && git for-each-ref --format='%(refname)' refs/remotes/ 2>/dev/null)"

  hist_grep() {  # hist_grep <newline-separated commit list>; prints up to 10 hits
    local revs="$1"
    [ -n "$revs" ] || return 0
    # $revs is deliberately UNQUOTED — git grep takes the revisions as separate argv
    # entries, and they must sit BEFORE the `--` that starts the pathspec. Piping them
    # through xargs appends them AFTER the pathspec instead, where git reads them as
    # paths that do not exist: the grep then matches nothing and the class reports clean.
    # That is exactly the false-assurance shape this gate exists to refuse, and it was
    # caught here only because the local-only class was KNOWN to have a hit.
    # shellcheck disable=SC2086
    (cd "$REPO" && git grep -n -I -E -i "$HIST_PAT" $revs \
      -- . "${EXCL[@]}" ${P5_EXCL[@]+"${P5_EXCL[@]}"} 2>/dev/null | head -10) || true
  }

  # hist_matches <revs>; prints the distinct landmark TEXTS found, lowercased and sorted.
  #
  # Deliberately NOT `hist_grep | ...`. hist_grep caps its output at 10 hits because it
  # feeds a human-readable list; deriving the already-published SET from that capped list
  # would mean the 11th distinct landmark reads as never-published, and a repeat of it
  # would be reported as fresh exposure. The cap is right for display and wrong for a set.
  #
  # `-h` suppresses the rev:path:line prefix. Without it the prefix goes through grep -o
  # too, and any landmark pattern that happens to match hex would harvest commit SHAs as
  # if they were landmarks — different SHAs on each side, so every pending hit would look
  # new. The current patterns do not match a bare SHA; a stranger's config is not ours to
  # assume, so the prefix is removed rather than trusted.
  hist_matches() {
    local revs="$1"
    [ -n "$revs" ] || return 0
    # shellcheck disable=SC2086
    (cd "$REPO" && git grep -h -I -E -i "$HIST_PAT" $revs \
      -- . "${EXCL[@]}" ${P5_EXCL[@]+"${P5_EXCL[@]}"} 2>/dev/null) \
      | grep -o -E -i "$HIST_PAT" | tr 'A-Z' 'a-z' | sort -u
  }

  if [ -z "$REMOTE_REFS" ]; then
    HIST="$(hist_grep "$(cd "$REPO" && git rev-list --all 2>/dev/null)")"
    if [ -n "$HIST" ]; then
      hit "P8 landmark found in git HISTORY — a working-tree deletion will NOT fix this"
      printf '%s\n' "$HIST" | while IFS= read -r l; do note "${l:0:160}"; done
      note "the repo must be rebuilt from a fresh git init, not patched"
    else
      pass "P8 history clean across $BLOBS objects"
    fi
    note "no remote-tracking refs in this clone — published vs local-only is UNKNOWN,"
    note "so every commit was treated as published. Fetch a remote for a finer verdict."
  else
    PUB_REVS="$(cd "$REPO" && git rev-list $REMOTE_REFS 2>/dev/null)"
    PEND_REVS="$(cd "$REPO" && git rev-list HEAD --not $REMOTE_REFS 2>/dev/null)"
    LOCAL_REVS="$(cd "$REPO" && git rev-list --all --not $REMOTE_REFS HEAD 2>/dev/null)"

    PUB_HIT="$(hist_grep "$PUB_REVS")"
    PEND_HIT="$(hist_grep "$PEND_REVS")"
    LOCAL_HIT="$(hist_grep "$LOCAL_REVS")"

    # The buckets above classify COMMITS. The PENDING verdict, though, makes a claim about
    # a LANDMARK — "the next push would publish it" — and those are different questions. A
    # string that is already fetchable, reintroduced in an unpushed commit, is a pending
    # COMMIT carrying a published LANDMARK: the push discloses nothing that is not already
    # out. Saying otherwise is not a harmless overstatement. The sibling PUBLISHED remedy
    # is "rebuild from a fresh git init", so a false "would publish" manufactures pressure
    # toward orphaning every published SHA to suppress a disclosure that already happened.
    PUB_MATCHES="$(hist_matches "$PUB_REVS")"
    PEND_MATCHES="$(hist_matches "$PEND_REVS")"
    # Blank lines are stripped from BOTH sides: printf on an empty variable emits one
    # empty line, which comm would otherwise report as a landmark present on one side.
    PEND_NEW="$(comm -13 \
      <(printf '%s\n' "$PUB_MATCHES"  | sed '/^$/d') \
      <(printf '%s\n' "$PEND_MATCHES" | sed '/^$/d'))"

    if [ -n "$PUB_HIT" ]; then
      hit "P8 landmark is ALREADY PUBLISHED — reachable from a remote branch"
      printf '%s\n' "$PUB_HIT" | while IFS= read -r l; do note "${l:0:160}"; done
      note "a working-tree deletion will NOT fix this, and neither will a force-push:"
      note "the objects stay fetchable by SHA. The repo must be rebuilt from a fresh git init."
    fi
    if [ -n "$PEND_HIT" ]; then
      # Fail SAFE on either of two conditions, never only on the happy one:
      #   PEND_NEW non-empty      something genuinely unpublished is here.
      #   PEND_MATCHES empty      hits exist that the match extraction cannot account for
      #                           — a landmark in a PATH, say, which `-h` does not see.
      #                           Published-vs-new is then UNKNOWN, and an unknown must
      #                           never be recorded as an ok. Same rule as the no-remote
      #                           fallback above.
      if [ -n "$PEND_NEW" ] || [ -z "$PEND_MATCHES" ]; then
        hit "P8 landmark is on HEAD and NOT yet published — the next push would publish it"
        printf '%s\n' "$PEND_HIT" | while IFS= read -r l; do note "${l:0:160}"; done
        note "still fixable: drop or rewrite the offending commit BEFORE pushing."
        [ -n "$PEND_MATCHES" ] || note "(could not tell new from repeat here, so treated as new)"
      else
        warn "P8 unpushed commits repeat an ALREADY-PUBLISHED landmark — the push adds no disclosure"
        printf '%s\n' "$PEND_HIT" | while IFS= read -r l; do note "${l:0:160}"; done
        note "every landmark here is already in the PUBLISHED finding above. Pushing"
        note "discloses nothing new, so this is NOT a reason to rewrite history."
        note "fix the working tree so it stops recurring; the exposure itself is already spent."
      fi
    fi
    if [ -n "$LOCAL_HIT" ]; then
      warn "P8 landmark in LOCAL-ONLY history — this clone only, not published, not on HEAD"
      printf '%s\n' "$LOCAL_HIT" | while IFS= read -r l; do note "${l:0:160}"; done
      note "not a publish blocker. Prune the stale local branches to clear it:"
      printf '%s\n' "$LOCAL_HIT" | cut -d: -f1 | sort -u | while IFS= read -r c; do
        b="$(cd "$REPO" && git branch --contains "$c" --format='%(refname:short)' 2>/dev/null | tr '\n' ' ')"
        [ -n "$b" ] && note "  ${c:0:12} is on: $b"
      done
    fi
    if [ -z "$PUB_HIT" ] && [ -z "$PEND_HIT" ] && [ -z "$LOCAL_HIT" ]; then
      pass "P8 history clean across $BLOBS objects"
    elif [ -z "$PUB_HIT" ] && [ -z "$PEND_HIT" ]; then
      pass "P8 nothing published and nothing pending — publishable history is clean"
    fi
  fi
else
  echo ""
  echo "[P8] git history — SKIPPED (pass --history; REQUIRED before going public)"
fi

# ── P9: self-containment ──────────────────────────────────────────────────────
# Added 2026-08-10. A repo that cites a skill it does not ship cannot be consumed on
# its own: the citation resolves on the authoring machine and nowhere else. No other
# gate sees this — a skill reference is not a path, so the link checker is blind to
# it, and the skill IS installed locally, so nothing here looks broken. It breaks only
# for the next consumer. This tier is the bottom of the stack and may depend on nothing
# above it, so it runs with no allowances at all.
echo ""
echo "[P9] Tier self-containment (references no skill it does not ship)"
TC="$SELF/tier-check.py"
if [ ! -f "$TC" ]; then
  printf 'WARN  %s\n' "P9 tier-check.py missing — self-containment UNVERIFIED"
elif ! command -v python3 >/dev/null 2>&1; then
  printf 'WARN  %s\n' "P9 python3 missing — self-containment UNVERIFIED"
else
  if TC_OUT="$(python3 "$TC" "$REPO" 2>&1)"; then
    pass "P9 self-contained ($(printf '%s' "$TC_OUT" | grep -c '') lines of evidence)"
  else
    hit "P9 references skill(s) it does not ship"
    printf '%s\n' "$TC_OUT" | sed 's/^/        /' | head -14
  fi
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "=== RESULT: CLEAN — safe to publish ==="
  exit 0
else
  echo "=== RESULT: FINDINGS — DO NOT PUBLISH ==="
  echo "Fix by REMOVING the file from the selection, not by editing it in place:"
  echo "content that leaked in once is usually a signal the whole file is org-specific."
  exit 1
fi
