#!/usr/bin/env bash
# Register the weekly secrets-test smoke cron. Run AFTER this PR is merged
# — i.e., once `scripts/secrets-test-smoke.sh` exists in the repo,
# ~/.hermes/cron/jobs.json doesn't already have a `secrets-test-smoke`
# entry, and you're sitting at this repo's root.
#
# What this cron does:
#   Weekly Sun 04:00 America/Bogota (09:00 UTC): runs the round-trip
#   harness (scripts/test-secrets-backup-restore.sh, 34 assertions)
#   via the smoke wrapper (scripts/secrets-test-smoke.sh). Silent on
#   success; posts a Discord alert to the home channel on failure with
#   the harness output. Catches regressions that CI wouldn't.
#
# Idempotency: removes any pre-existing cron with the same name before
# re-registering, so a stale prompt/script reference is never left behind.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SMOKE_SRC="$REPO_ROOT/scripts/secrets-test-smoke.sh"
SMOKE_DEST="$HOME/.hermes/scripts/secrets-test-smoke.sh"
JOBS_FILE="$HOME/.hermes/cron/jobs.json"
CRON_NAME="secrets-test-smoke"
SCHEDULE="0 9 * * 0"           # Sun 04:00 Bogota = 09:00 UTC
DELIVERY="discord:1491582132479590444"   # home channel
WORKDIR="/home/ubuntu/data/code/mercury-host"

# ── preflight ─────────────────────────────────────────────────────────────
if [ ! -f "$SMOKE_SRC" ]; then
    echo "FATAL: $SMOKE_SRC not found — run from the mercury-host repo root" >&2
    exit 1
fi

# ── 1. Vendor the wrapper script to ~/.hermes/scripts/ ────────────────────
mkdir -p "$HOME/.hermes/scripts"
cp -f "$SMOKE_SRC" "$SMOKE_DEST"
chmod 755 "$SMOKE_DEST"
echo "[secrets-test-smoke] copied $SMOKE_SRC → $SMOKE_DEST"

# ── 2. If a cron with this name already exists, remove it for clean re-register ──
if [ -f "$JOBS_FILE" ] && command -v jq >/dev/null 2>&1; then
    EXISTING_ID=$(jq -r --arg name "$CRON_NAME" '.jobs[] | select(.name == $name) | .id' "$JOBS_FILE" 2>/dev/null || true)
    if [ -n "$EXISTING_ID" ] && [ "$EXISTING_ID" != "null" ]; then
        echo "[secrets-test-smoke] existing cron id=$EXISTING_ID, removing for clean re-register"
        hermes cron remove "$EXISTING_ID"
    fi
fi

# ── 3. Register the no_agent cron ──────────────────────────────────────────
# Empty prompt because the harness does all the work via the script.
hermes cron create \
    --name "$CRON_NAME" \
    --deliver "$DELIVERY" \
    --workdir "$WORKDIR" \
    "$SCHEDULE" \
    "Weekly smoke test of the secrets backup/restore round-trip harness. Runs scripts/secrets-test-smoke.sh → scripts/test-secrets-backup-restore.sh (34 assertions). Silent on success; Discord alert on failure with harness output." \
    || { echo "FATAL: hermes cron create failed" >&2; exit 1; }

# ── 4. Patch jobs.json to mark this as no_agent with script=secrets-test-smoke.sh ──
NEW_ID=$(jq -r --arg name "$CRON_NAME" '.jobs[] | select(.name == $name) | .id' "$JOBS_FILE" 2>/dev/null || true)
if [ -z "$NEW_ID" ] || [ "$NEW_ID" = "null" ]; then
    echo "FATAL: cron created but id not in $JOBS_FILE" >&2
    exit 1
fi

python3 - "$JOBS_FILE" "$NEW_ID" <<'PYEOF'
import json, sys
jobs_file, target_id = sys.argv[1], sys.argv[2]
with open(jobs_file) as f:
    data = json.load(f)
found = False
for j in data.get("jobs", []):
    if j.get("id") == target_id:
        j["no_agent"] = True
        j["script"] = "secrets-test-smoke.sh"
        j["enabled_toolsets"] = ["terminal", "file"]
        found = True
        break
if not found:
    print(f"FATAL: id={target_id} not in {jobs_file}", file=sys.stderr)
    sys.exit(1)
with open(jobs_file, "w") as f:
    json.dump(data, f, indent=2)
print(f"[secrets-test-smoke] patched {jobs_file}: no_agent=true, script=secrets-test-smoke.sh")
PYEOF

echo "[secrets-test-smoke] DONE. Job id=$NEW_ID. Force-tick: hermes cron run $NEW_ID"