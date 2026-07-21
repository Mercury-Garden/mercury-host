#!/usr/bin/env bash
# scripts/varlock-preflight.sh — Stage 5 cron preflight.
#
# Validates that `varlock load --agent` can resolve every key in a project's
# .env.schema without throwing. Used by the x-digest-daily cron (and any
# future varlock-backed cron) to fail closed BEFORE touching any actual
# pipeline work.
#
# EXITS:
#   0 — preflight passed; pipeline can run
#   1 — varlock binary not found
#   2 — schema missing
#   3 — varlock load returned non-zero (a @required item is unresolved)
#   4 — varlock load returned zero but JSON output is malformed
#   5 — gpg-agent not reachable (cold-agent decrypt failed)
#
# USAGE:
#   bash scripts/varlock-preflight.sh <project-path>
#
# EXAMPLES:
#   bash scripts/varlock-preflight.sh ~/data/code/x-digest
#
# BEHAVIORAL NOTES:
#   * Uses `varlock load --agent --skip-cache` so the resolved values are
#     inspected in their redacted form — no secret values leave the machine.
#     (The `--agent` flag is what triggers the redacted placeholders shown
#     in varlock's docs. Without it, the JSON would have the actual values
#     in cleartext.)
#   * Times out after 30 seconds so a hung gpg-agent doesn't poison a cron
#     tick. Most resolutions complete in <1s in steady state.
#   * On failure, prints stderr with actionable fix suggestions; the cron
#     prompt's step 2 fallback (source .env) triggers automatically when
#     this script exits non-zero.

set -euo pipefail

PROJECT="${1:-}"
if [ -z "$PROJECT" ]; then
  printf 'usage: %s <project-path>\n' "$0" >&2
  exit 64
fi
if [ ! -d "$PROJECT" ]; then
  printf '✗ project path does not exist: %s\n' "$PROJECT" >&2
  exit 1
fi
if [ ! -f "$PROJECT/.env.schema" ]; then
  printf '✗ no .env.schema at %s — varlock not configured here\n' "$PROJECT" >&2
  exit 2
fi

# Preflight: varlock binary?
if ! command -v varlock >/dev/null 2>&1; then
  printf '✗ varlock not on PATH\n' >&2
  printf '  fix: install varlock per packages/node.yaml or scripts/restore.sh\n' >&2
  exit 1
fi

# Preflight: gpg-agent alive?
if ! pgrep -f gpg-agent >/dev/null 2>&1; then
  printf '✗ gpg-agent not running\n' >&2
  printf '  fix: systemctl --user start gpg-agent.service || gpg-agent --daemon\n' >&2
  exit 5
fi

# Core: did `varlock load --agent` succeed?
cd "$PROJECT"
TMP=$(mktemp -t vp-preflight-XXXXXX)
trap 'rm -f "$TMP"' RETURN

if ! timeout 30 varlock load --agent --skip-cache > "$TMP" 2>&1; then
  printf '✗ varlock load failed (rc=%d)\n' "$?" >&2
  printf '  full varlock error:\n' >&2
  sed 's/^/    /' "$TMP" >&2
  printf '  common fixes:\n' >&2
  printf '    - gpg-agent not running: systemctl --user start gpg-agent.service\n' >&2
  printf '    - missing pass entries: see secrets/inventory.yaml#varlock-pass-store\n' >&2
  printf '    - schema mismatch: rerun scripts/audit.sh for drift\n' >&2
  exit 3
fi

# Verify the JSON output is well-formed (one more canary against a
# half-broken varlock that silently produces garbage).
if ! jq -r 'keys[]' "$TMP" >/dev/null 2>&1; then
  printf '✗ varlock output is malformed JSON\n' >&2
  cat "$TMP" >&2
  exit 4
fi

# Count keys (helpful for the cron log; we don't print the values).
KEY_COUNT=$(jq 'length' "$TMP")
printf '✓ varlock preflight ok: %d keys resolvable (sensitive values redacted)\n' "$KEY_COUNT"
exit 0
