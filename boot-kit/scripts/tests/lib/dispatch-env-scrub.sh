#!/usr/bin/env bash
# dispatch-env-scrub.sh — the dispatch environment, stripped, for gate suites that must be
# hermetic to whatever worker happens to be running them.
#
# ⛔ THE BUG THIS GUARDS. `env VAR=val cmd` only ADDS to cmd's inherited environment — it does
# NOT clear it. df-worker exports DF_TICKET, DF_ROLE, DF_MISSION, DF_SCRATCH, DF_MCP_MODE and
# DF_CLAIM_COLUMNS into every child process, dispatch.sh exports WORKER_*, and a headless
# (`claude -p` / sdk-cli) run additionally carries CLAUDE_CODE_ENTRYPOINT=sdk-cli. A gate suite
# invoked BY a df-dispatched worker hands its hook-under-test the WORKER's own ticket, scratch
# dir, claim columns and entrypoint underneath whatever the suite explicitly passes — not the
# absence a "DF_TICKET unset" or "DF_CLAIM_VALUES_KEY unset" case is asserting, and (for the
# completeness gate) not the interactive session its "the gate fires" cases assume. A suite run
# by hand, or by CI with none of this exported, never sees it: two workers independently
# reported these suites as "pre-existing failures reproducing in total isolation" and were not
# isolated — the ambient env was the fixture nobody declared.
#
# scrub_dispatch_env <cmd...> — runs <cmd...> with every variable matching ^DF_ or ^WORKER_,
# PLUS CLAUDE_CODE_ENTRYPOINT (a headless-run signal the completeness gate reads directly, named
# explicitly since it matches neither prefix), unset first. <cmd...> may itself lead with
# `NAME=VALUE` assignments or `-u NAME` flags of its own — `env` applies unset-then-assign in
# the order given, so a caller's own assignments after the scrub still land. Everything else the
# calling shell already carries (PATH, HOME, TMPDIR, ...) passes through untouched.
#
# Recomputed on every call, not cached at source time or at process start, so a case that
# poisons the SUITE's own environment mid-run (proving the scrub survives that, not just
# describing it) is still caught, not grandfathered in by a stale snapshot.
scrub_dispatch_env() {
  local flags=(-u CLAUDE_CODE_ENTRYPOINT)
  local var
  while IFS= read -r var; do
    [ -n "$var" ] && flags+=(-u "$var")
  done < <(env | LC_ALL=C awk -F= '/^(DF_|WORKER_)/{print $1}')
  env "${flags[@]}" "$@"
}
