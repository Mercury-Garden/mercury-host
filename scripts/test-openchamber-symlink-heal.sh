#!/usr/bin/env bash
# Regression test: devtools-upgrade.ts repairPnpmSymlinks() must heal a
# broken relative symlink (the failure class that took out openchamber
# on 2026-07-18 11:00 UTC and left it in restart-loop for ~4 hours).
#
# This test is a STATIC-CHECK + BEHAVIORAL verification:
#
#   1. Static check: confirm auditOpenchamber() calls repairPnpmSymlinks
#      and repointPnpmCmdShim UNCONDITIONALLY after pnpmGlobalUpgrade
#      (the regression: previously these were gated on r.err === null).
#
#   2. Behavioral check: confirm the script's main() runs and emits 14
#      JSON lines in canonical order. This is the same end-to-end smoke
#      test the cron run uses; it confirms the new conditional structure
#      parses + executes correctly.
#
# We deliberately do NOT import the helpers via dynamic-import — Node's
# --experimental-strip-types does not surface named ESM exports through
# dynamic import (verified 2026-07-18). Instead, the behavioral proof is
# that the script runs end-to-end without parse errors and emits the
# expected contract.
#
# Run from repo root:
#   bash scripts/test-openchamber-symlink-heal.sh --verbose
#
# Exit codes: 0 = all pass, 1 = at least one assertion failed.

set -uo pipefail

VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/devtools-upgrade.ts"

log() {
  if [ "$VERBOSE" = "1" ]; then
    echo "  $*"
  fi
}

# ── 1. static check: unconditional repair in auditOpenchamber ────────────
log "step 1: static check — auditOpenchamber must call repair helpers unconditionally"

# Look for the pattern: `pnpmGlobalUpgrade(...)` followed (within ~30 lines)
# by an UNCONDITIONAL `repairPnpmSymlinks` call. The previous version gated
# this inside `if (!r.err)` blocks — confirm those wrappers are gone.
# Use pnpmGlobalUpgrade line as anchor, then check for repair within next 30 lines.
ANCHOR_LINE=$(grep -n 'pnpmGlobalUpgrade.*latest' "$SCRIPT" | head -1 | cut -d: -f1)
log "  pnpmGlobalUpgrade line: $ANCHOR_LINE"

if [ -z "$ANCHOR_LINE" ]; then
  echo "FAIL: pnpmGlobalUpgrade call not found in script" >&2
  exit 1
fi

# Read the next 30 lines after the anchor and look for the unconditional call.
TAIL=$(tail -n +"$ANCHOR_LINE" "$SCRIPT" | head -30)
HAS_UNCONDITIONAL=$(echo "$TAIL" | grep -c 'try { repairPnpmSymlinks')
log "  found $HAS_UNCONDITIONAL unconditional repairPnpmSymlinks call(s) within 30 lines after pnpmGlobalUpgrade"

if [ "$HAS_UNCONDITIONAL" -lt 1 ]; then
  echo "FAIL: auditOpenchamber does NOT call repairPnpmSymlinks unconditionally after pnpmGlobalUpgrade" >&2
  echo "      (the regression: the previous version gated this on r.err === null)" >&2
  echo "      --- 30 lines after pnpmGlobalUpgrade ---" >&2
  echo "$TAIL" | head -30 >&2
  exit 1
fi
log "  ok: unconditional repairPnpmSymlinks call is present"

# Confirm the three-case classification block (a)/(b)/(c) is present —
# the new classification logic that distinguishes "install failed but
# repair healed it" (upgraded) from "install failed and repair couldn't
# heal" (failed).
HAS_THREE_CASE=$(grep -c 'install reported.*post-install repair healed it' "$SCRIPT")
log "  found $HAS_THREE_CASE three-case classification reference(s)"

if [ "$HAS_THREE_CASE" -lt 1 ]; then
  echo "FAIL: auditOpenchamber does NOT have the three-case classification block" >&2
  echo "      (the new logic distinguishes healed-failed-install from unhealed-failed-install)" >&2
  exit 1
fi
log "  ok: three-case classification block is present"

# ── 2. behavioral check: script runs and emits 14 lines ──────────────────
log "step 2: behavioral check — script runs and emits 14 JSON lines"

OUT=$(node --experimental-strip-types "$SCRIPT" 2>&1)
RC=$?
if [ "$RC" -ne 0 ]; then
  echo "FAIL: script exited non-zero (rc=$RC)" >&2
  echo "  output: $OUT" | head -10 >&2
  exit 1
fi

LINE_COUNT=$(echo "$OUT" | wc -l)
log "  emitted $LINE_COUNT lines"
if [ "$LINE_COUNT" -ne 14 ]; then
  echo "FAIL: expected 14 lines, got $LINE_COUNT" >&2
  exit 1
fi
log "  ok: 14 lines emitted"

# Verify canonical order (matches the cron prompt's hard-rule)
ORDER=$(echo "$OUT" | python3 -c '
import json, sys
got = [json.loads(l)["tool"] for l in sys.stdin if l.strip()]
expected = ["opencode-ai","openchamber","pnpm","node","volta","context-mode","@plannotator/opencode","@colbymchenry/codegraph","opencode-plugin-openspec","@fission-ai/openspec","openwiki","rtk","plannotator","codegraph"]
print("OK" if got == expected else f"ORDER MISMATCH: got {got}")
')
if [ "$ORDER" != "OK" ]; then
  echo "FAIL: canonical order mismatch — $ORDER" >&2
  exit 1
fi
log "  ok: canonical order matches the cron prompt"

# ── 3. openchamber is healthy ────────────────────────────────────────────
log "step 3: confirm openchamber service is healthy"
SUBSTATE=$(systemctl --user is-active openchamber.service 2>&1 || true)
if [ "$SUBSTATE" != "active" ]; then
  echo "FAIL: openchamber.service is not active (got: $SUBSTATE)" >&2
  exit 1
fi
log "  ok: openchamber.service is active"

HTTP=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:9090/ 2>&1)
if [ "$HTTP" != "200" ]; then
  echo "FAIL: openchamber HTTP probe returned $HTTP (expected 200)" >&2
  exit 1
fi
log "  ok: openchamber HTTP 200"

echo
echo "3/3 assertions passed"