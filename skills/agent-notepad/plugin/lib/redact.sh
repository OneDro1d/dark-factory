#!/usr/bin/env bash
# lib/redact.sh — pure text transforms shared by the agent-notepad read-hooks.
# Redact secrets/PII (DESIGN §6.1/§7.5) and bound snapshot size.
# Pure: read stdin, write stdout, no side effects. BSD-sed / macOS compatible.
# Ported from the hardened handoff-auto redactor (2026-06-26 adversary gate).
#
# Scope note: pattern/keyword based. It will NOT catch a bare high-entropy secret
# with no recognizable prefix and no adjacent keyword (over-redacting SHAs/base64
# is worse). Such secrets are caught only in keyworded form (api_key=...).

# redact_secrets: replace common credential shapes with [REDACTED].
redact_secrets() {
  awk '
    /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/ { print "[REDACTED PRIVATE KEY]"; inkey=1; next }
    inkey { if ($0 ~ /-----END [A-Z0-9 ]*PRIVATE KEY-----/) inkey=0; next }
    { print }
  ' | sed -E \
    -e 's/[Bb]earer[[:space:]]+[A-Za-z0-9._~+/-]+=*/Bearer [REDACTED]/g' \
    -e 's/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_.=-]+\.[A-Za-z0-9_.=-]+/[REDACTED]/g' \
    -e 's/sk-[A-Za-z0-9_-]{20,}/[REDACTED]/g' \
    -e 's/(github_pat_|gh[pousr]_)[A-Za-z0-9_]{20,}/[REDACTED]/g' \
    -e 's/xox[baprs]-[A-Za-z0-9-]{10,}/[REDACTED]/g' \
    -e 's/AKIA[0-9A-Z]{16}/[REDACTED]/g' \
    -e 's/([^[:space:]]*([Pp]assword|[Pp]asswd|[Ss]ecret|[Tt]oken|[Aa]pi[_-]?[Kk]ey)[^[:space:]=:]*)["]?[[:space:]]*[=:][[:space:]]*["]?[^[:space:]"]+/\1=[REDACTED]/g'
}

# bound_lines MAX: pass input through unchanged if <= MAX lines,
# else emit the first MAX-1 lines plus a truncation marker (total == MAX).
bound_lines() {
  awk -v max="$1" '
    { lines[NR] = $0 }
    END {
      if (NR <= max) {
        for (i = 1; i <= NR; i++) print lines[i]
      } else {
        keep = max - 1
        for (i = 1; i <= keep; i++) print lines[i]
        printf "[... truncated to %d lines ...]\n", max
      }
    }'
}
