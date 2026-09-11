#!/usr/bin/env bash
# test-install-instance-record.sh — install.sh installs ONE MACHINE's record, end to end.
#
# ⛔ WHAT IT PROTECTS. A kit is one private repo per person with one record per machine:
# the root loom.lock.json and instances/<machine>/loom.lock.json. Until 2026-09-11 this installer
# read the root file and nothing else, so every kit copied from it could describe exactly one
# machine. This suite asserts the whole path a per-machine install takes:
#   I1/I2  --lock= and LOOM_LOCK both select the machine's record, and the SAME record reaches
#          rehydrate.sh (which installs) and lock-verify.sh (which verifies)
#   I3     no flag, no env -> the root record (control)
#   I4     the per-machine `vendor` link lock-verify needs is created beside the record
#   I5/I6  '--lock <space>' and a missing record are refused, and nothing is fetched
#   I7     the flag wins over the environment
#
# The fixture Tier 1 carries STUB rehydrate.sh and lock-verify.sh that print the record they were
# handed, so the suite observes the hand-off itself. LOOM_LIVE/LOOM_BIN are pinned into the
# fixture; nothing here reaches the real ~/.claude or ~/.local/bin.
#
# Usage: bash starter-kit/instance/tests/test-install-instance-record.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$SELF/.." && pwd)"
INSTALL_SRC="$KIT/install.sh"
[ -f "$INSTALL_SRC" ] || { echo "missing $INSTALL_SRC"; exit 2; }
command -v jq  >/dev/null 2>&1 || { echo "jq required";  exit 2; }
command -v git >/dev/null 2>&1 || { echo "git required"; exit 2; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output" ;; esac; }
absent()   { case "$3" in *"$2"*) bad "$1" "'$2' unexpectedly in output" ;; *) ok "$1" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/instrecord.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
GITC=(-c user.email=test@example.com -c user.name=test)

mk() {  # mk <case> -- a fixture Tier 1 with stub rehydrate/lock-verify, and a kit with two records
  local d="$WORK/$1"
  mkdir -p "$d/t1/boot-kit/scripts" "$d/inst/vendor"
  cat > "$d/t1/boot-kit/scripts/rehydrate.sh" <<'EOF'
#!/usr/bin/env bash
echo "RH_LOCK=[${LOOM_LOCK-<unset>}]"
EOF
  cat > "$d/t1/boot-kit/scripts/lock-verify.sh" <<'EOF'
#!/usr/bin/env bash
echo "LV_ARGS=[$*]"
echo "=== RESULT: LOCKED (fixture stub) ==="
EOF
  chmod +x "$d/t1/boot-kit/scripts"/*.sh
  git -C "$d/t1" init -q
  git "${GITC[@]}" -C "$d/t1" add -A
  git "${GITC[@]}" -C "$d/t1" commit -q -m fixture
  git clone -q "$d/t1" "$d/inst/vendor/dark-factory"
  cp "$INSTALL_SRC" "$d/inst/install.sh"
  local base='{vendorDir:"vendor", upstreams:{"dark-factory":{repo:"example/dark-factory",commit:""}},
               install:{skills:[],skillSources:{},hooks:[],hookSources:{}}}'
  jq -n "$base + {instance:{name:\"root\",kind:\"instance\"}}" > "$d/inst/loom.lock.json"
  mkdir -p "$d/inst/instances/m"
  jq -n "$base + {instance:{name:\"machine-m\",kind:\"instance\"}}" > "$d/inst/instances/m/loom.lock.json"
}
run() {  # run <case> [env assignments...] -- [install args...]
  local c="$1"; shift
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  ( cd "$WORK/$c/inst" && env -u LOOM_LOCK LOOM_LIVE="$WORK/$c/live" LOOM_BIN="$WORK/$c/bin" \
      "${envs[@]+"${envs[@]}"}" bash install.sh --offline --no-prove "$@" 2>&1 )
}

echo "=== I1: --lock=instances/m/loom.lock.json selects the machine's record, for BOTH halves ==="
mk i1
OUT1="$(run i1 -- --lock=instances/m/loom.lock.json)"
contains "I1 rehydrate was handed the machine's record" "/inst/instances/m/loom.lock.json]" "$(printf '%s' "$OUT1" | grep 'RH_LOCK=')"
contains "I1 lock-verify was handed the machine's record" "instances/m/loom.lock.json" "$(printf '%s' "$OUT1" | grep 'LV_ARGS=')"

echo "=== I2: LOOM_LOCK does the same ==="
mk i2
OUT2="$(run i2 LOOM_LOCK=instances/m/loom.lock.json --)"
# The ABSOLUTE path, which only the installer produces: a bare env var would reach the stub
# relative, unaided, and pass this on an installer that never handed anything over.
contains "I2 rehydrate was handed the machine's record by the installer" "/inst/instances/m/loom.lock.json]" "$(printf '%s' "$OUT2" | grep 'RH_LOCK=')"
contains "I2 lock-verify was handed the machine's record" "instances/m/loom.lock.json" "$(printf '%s' "$OUT2" | grep 'LV_ARGS=')"

echo "=== I3: no flag, no env -> the root record (control) ==="
mk i3
OUT3="$(run i3 --)"
contains "I3 rehydrate was handed the root record" "/inst/loom.lock.json]" "$(printf '%s' "$OUT3" | grep 'RH_LOCK=')"
absent   "I3 no machine record anywhere" "instances/m/" "$OUT3"

echo "=== I4: the per-machine vendor link lock-verify needs is created, and resolves to the kit's cache ==="
if [ -L "$WORK/i1/inst/instances/m/vendor" ] && [ -d "$WORK/i1/inst/instances/m/vendor/dark-factory" ]; then
  ok "I4 instances/m/vendor is a link that resolves to the kit's vendor/"
else
  bad "I4 instances/m/vendor is a link that resolves to the kit's vendor/" "$(ls -la "$WORK/i1/inst/instances/m" 2>&1 | tr '\n' ' ')"
fi
contains "I4 and the install says so" "linked instances/m/vendor" "$OUT1"

echo "=== I5: '--lock <space> path' is refused, with the fix named ==="
mk i5
OUT5="$(run i5 -- --lock instances/m/loom.lock.json)"; RC5=$?
[ "$RC5" -eq 1 ] && ok "I5 exits 1 (a precondition, per the EXIT contract)" || bad "I5 exits 1" "rc=$RC5"
contains "I5 says --lock takes an = sign" "takes an = sign" "$OUT5"
absent   "I5 nothing was handed to rehydrate" "RH_LOCK=" "$OUT5"

echo "=== I6: a record that does not exist is refused, naming it ==="
mk i6
OUT6="$(run i6 -- --lock=instances/nope/loom.lock.json)"; RC6=$?
[ "$RC6" -eq 1 ] && ok "I6 exits 1" || bad "I6 exits 1" "rc=$RC6"
contains "I6 names the missing record" "no record at instances/nope/loom.lock.json" "$OUT6"

echo "=== I7: the flag wins over the environment ==="
mk i7
OUT7="$(run i7 LOOM_LOCK=loom.lock.json -- --lock=instances/m/loom.lock.json)"
contains "I7 --lock= overrides LOOM_LOCK" "/inst/instances/m/loom.lock.json]" "$(printf '%s' "$OUT7" | grep 'RH_LOCK=')"

echo
printf 'install instance record: %d ok, %d failed\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
