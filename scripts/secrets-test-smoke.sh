#!/usr/bin/env bash
# scripts/secrets-test-smoke.sh — wrapper that runs the round-trip harness
# and emits a Discord alert only on failure. Designed to be invoked as
# a Hermes no_agent cron (script:), not an LLM agent — the harness
# itself is fully self-contained, so the LLM would just call back into
# bash to do the work.
#
# Usage:
#   bash scripts/secrets-test-smoke.sh
#
# Exit codes:
#   0  all 34 harness assertions passed (silent — no Discord output)
#   1  harness reported FAIL > 0
#   2  harness not found / not executable
#
# Delivery (cron config) handles the Discord post — when this script
# exits non-zero with stdout empty, the cron system delivers the script
# stderr to the configured channel. When it exits 0 with stdout empty,
# the cron system stays silent. That's the watchdog pattern.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS="$SCRIPT_DIR/test-secrets-backup-restore.sh"

if [ ! -x "$HARNESS" ]; then
    echo "secrets-test-smoke: harness not found or not executable at $HARNESS" >&2
    exit 2
fi

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

# Run the harness. On failure, capture output to the temp file and print
# the FAILED lines + a header to stderr (which the cron system delivers).
set +e
bash "$HARNESS" >"$OUT" 2>&1
RC=$?
set -e

if [ "$RC" -eq 0 ]; then
    # Silent on success — the harness's own summary is in $OUT but the
    # watchdog pattern says: silence = healthy.
    exit 0
fi

# Failure: emit a Discord-friendly summary to stderr so the cron system
# delivers it.
{
    echo "⚠ secrets-test smoke FAILED (harness exit $RC)"
    # Pull the PASS/FAIL summary + last 20 lines of context
    grep -E '^(PASS|FAIL|✗)' "$OUT" | head -40 || true
    echo "--- last 20 harness lines ---"
    tail -20 "$OUT" || true
} >&2
exit 1