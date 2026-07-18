#!/usr/bin/env bash
# Register the devtools-upgrade cron job. Run AFTER this PR is merged —
# i.e., once `~/.hermes/scripts/devtools-upgrade.ts`,
# `~/.hermes/cron/jobs.json` is empty (or the cron no longer exists under
# this name), and you're sitting at this repo's root.
#
# Idempotency model:
#   • If a cron named "devtools-upgrade" already exists in
#     ~/.hermes/cron/jobs.json, it's removed first. This guarantees the
#     prompt + toolsets stay in sync with the vendored version on disk:
#     a stale prompt from a prior registration is the failure mode this
#     prevents.
#   • The vendored TypeScript script is copied to ~/.hermes/scripts/ on
#     every run, so manual edits to the live copy are overwritten.
#
# What this cron does (see scripts/devtools-upgrade-prompt.txt and the
# devtools-upgrade-plan skill for full architecture context):
#   Daily at 06:00 America/Bogota (11:00 UTC): audit 14 dev tools
#   (opencode-ai, openchamber, pnpm, node, volta, five opencode plugins,
#   openwiki, rtk, plannotator, codegraph) against their latest releases. Apply
#   upgrades; on opencode-ai/openchamber, stop+start openchamber.service
#   around the install (its opencode-gate subprocess holds the on-disk
#   binary). Post a deterministic Discord message to <#1520253382630047865>.
#
# Delivery target (channel id 1520253382630047865) is hard-coded here on
# purpose — it's the only place this cron posts. If you ever move it,
# edit both this file AND the channel-id it embeds.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_SRC="$REPO_ROOT/scripts/devtools-upgrade.ts"
PROMPT_SRC="$REPO_ROOT/scripts/devtools-upgrade-prompt.txt"
SCRIPT_DEST="$HOME/.hermes/scripts/devtools-upgrade.ts"
JOBS_FILE="$HOME/.hermes/cron/jobs.json"
CRON_NAME="devtools-upgrade"
DELIVERY="discord:1520253382630047865"
SCHEDULE="0 11 * * *"
WORKDIR="/home/ubuntu"
TOOLSETS=("terminal" "file" "web")

# ── preflight: source files exist ───────────────────────────────────────────
if [ ! -f "$SCRIPT_SRC" ]; then
    echo "FATAL: $SCRIPT_SRC not found — are you running this from the mercury-host repo root?" >&2
    exit 1
fi
if [ ! -f "$PROMPT_SRC" ]; then
    echo "FATAL: $PROMPT_SRC not found — prompt vendoring is required" >&2
    exit 1
fi

# ── 1. Copy the vendored script to ~/.hermes/scripts/ ───────────────────────
mkdir -p "$HOME/.hermes/scripts"
cp -f "$SCRIPT_SRC" "$SCRIPT_DEST"
chmod 644 "$SCRIPT_DEST"
echo "[devtools-upgrade] copied $SCRIPT_SRC → $SCRIPT_DEST"

# ── 2. If the cron already exists, remove it for clean re-registration ─────
if [ -f "$JOBS_FILE" ] && command -v jq >/dev/null 2>&1; then
    EXISTING_ID=$(jq -r --arg name "$CRON_NAME" '.jobs[] | select(.name == $name) | .id' "$JOBS_FILE" 2>/dev/null || true)
    if [ -n "$EXISTING_ID" ] && [ "$EXISTING_ID" != "null" ]; then
        echo "[devtools-upgrade] existing cron id=$EXISTING_ID, removing for clean re-register"
        hermes cron remove "$EXISTING_ID"
    fi
fi

# ── 3. Register the cron ────────────────────────────────────────────────────
# NOTE: 'hermes cron create' takes positional <schedule> <prompt>. It does
# NOT accept --enabled-toolsets (we patch jobs.json for that after).
PROMPT=$(cat "$PROMPT_SRC")
hermes cron create \
    --name "$CRON_NAME" \
    --deliver "$DELIVERY" \
    --workdir "$WORKDIR" \
    "$SCHEDULE" \
    "$PROMPT"
echo "[devtools-upgrade] registered"

# ── 4. Patch jobs.json: enabled_toolsets, script, and origin thread ────────
# The hermes CLI doesn't expose --enabled-toolsets, --script, or the cron
# identity fields. We mutate jobs.json directly; the chronos scheduler
# re-reads it on every tick (no gateway restart needed).
NEW_ID=$(jq -r --arg name "$CRON_NAME" '.jobs[] | select(.name == $name) | .id' "$JOBS_FILE" 2>/dev/null || true)
if [ -z "$NEW_ID" ] || [ "$NEW_ID" == "null" ]; then
    echo "FATAL: cron was created but I cannot find its id in $JOBS_FILE — check manually" >&2
    exit 1
fi

# Build the toolsets JSON array literal (jq isn't available in all cron
# shells, so we synthesize the fragment by hand). Comma-joined string of
# quoted toolset names.
TS_JSON=$(printf '"%s",' "${TOOLSETS[@]}")
TS_JSON="[${TS_JSON%,}]"

python3 - "$JOBS_FILE" "$NEW_ID" "$CRON_NAME" "$TS_JSON" <<'PYEOF'
import json, sys
jobs_file, target_id, target_name, toolsets_json = sys.argv[1:5]
with open(jobs_file) as f:
    data = json.load(f)
toolsets = json.loads(toolsets_json)
found = False
for j in data.get("jobs", []):
    if j.get("id") == target_id:
        j["enabled_toolsets"] = toolsets
        j["script"] = "devtools-upgrade.ts"
        j["origin"] = j.get("origin", {})
        j["origin"]["chat_id"] = "1521633992561131752"
        j["origin"]["thread_id"] = "1521633992561131752"
        j["origin"]["chat_name"] = j["origin"].get("chat_name", "Mercury home / #infrastructure")
        found = True
        break
if not found:
    print(f"FATAL: id={target_id} not in {jobs_file}", file=sys.stderr)
    sys.exit(1)
with open(jobs_file, "w") as f:
    json.dump(data, f, indent=2)
print(f"[devtools-upgrade] patched {jobs_file}: enabled_toolsets={toolsets}, script=devtools-upgrade.ts")
PYEOF

echo "[devtools-upgrade] DONE. Job id=$NEW_ID. To force-tick: hermes cron run $NEW_ID"
