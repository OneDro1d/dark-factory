#!/usr/bin/env bash
# Tiny dependency-free assertion + runner harness (shared by agent-notepad tests).
# Usage: source this, define test_* functions, call run_tests at the end.

ASSERT_PASS=0
ASSERT_FAIL=0
ASSERT_CASES=0

_fail() {
  ASSERT_FAIL=$((ASSERT_FAIL + 1))
  printf '  \033[31mFAIL\033[0m %s\n' "$1" >&2
}
_pass() {
  ASSERT_PASS=$((ASSERT_PASS + 1))
}

assert_eq() { # expected actual msg
  ASSERT_CASES=$((ASSERT_CASES + 1))
  if [ "$1" = "$2" ]; then _pass; else _fail "$3 (expected='$1' actual='$2')"; fi
}

assert_contains() { # haystack needle msg
  ASSERT_CASES=$((ASSERT_CASES + 1))
  case "$1" in
    *"$2"*) _pass ;;
    *) _fail "$3 (missing substring '$2')" ;;
  esac
}

assert_not_contains() { # haystack needle msg
  ASSERT_CASES=$((ASSERT_CASES + 1))
  case "$1" in
    *"$2"*) _fail "$3 (unexpected substring '$2')" ;;
    *) _pass ;;
  esac
}

assert_file_exists() { # path msg
  ASSERT_CASES=$((ASSERT_CASES + 1))
  if [ -f "$1" ]; then _pass; else _fail "$2 (no file at '$1')"; fi
}

assert_dir_exists() { # path msg
  ASSERT_CASES=$((ASSERT_CASES + 1))
  if [ -d "$1" ]; then _pass; else _fail "$2 (no dir at '$1')"; fi
}

assert_le() { # value max msg
  ASSERT_CASES=$((ASSERT_CASES + 1))
  if [ "$1" -le "$2" ]; then _pass; else _fail "$3 (value=$1 > max=$2)"; fi
}

run_tests() {
  local fn
  for fn in $(declare -F | awk '{print $3}' | grep '^test_'); do
    printf '\033[1m%s\033[0m\n' "$fn"
    "$fn"
  done
  printf '\n%d cases: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n' \
    "$ASSERT_CASES" "$ASSERT_PASS" "$ASSERT_FAIL"
  [ "$ASSERT_FAIL" -eq 0 ]
}
