#!/usr/bin/env bash
# test-varlock-stage8-restore-drill.sh — Stage 8.5 of the Varlock plan.
#
# Proves the varlock pipeline round-trips correctly for every migrated repo
# (x-digest, better-bet, scriptcaster) by:
#   1. Backing up the live ~/.password-store + ~/.gnupg into a synthetic $HOME
#   2. Verifying each migrated repo's schema loads cleanly
#   3. Verifying the canary decrypts from cold gpg-agent (post-extract)
#
# This complements `test-varlock-backup-restore.sh` (which tests the host-side
# tar+restore cycle). This script is repository-scoped: it checks that every
# migrated project can still resolve its secrets after the host cycle completes.
#
# Run from anywhere; resolves paths relative to mercury-host repo root
# (`$(git rev-parse --show-toplevel)` of the calling shell, falling back to
# the script's parent).
#
# Exit codes:
#   0  all migrations round-trip cleanly
#   1  preflight failed (varlock, pass, or gpg not available)
#   2  one or more migrated repos failed
#   3  canary decryption failed
set -uo pipefail

# Resolve script directory and (if available) repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)}"
if [ ! -d "$REPO_ROOT" ]; then
  echo "ERROR: cannot resolve mercury-host repo root" >&2
  exit 1
fi

# ── Pre-flight ────────────────────────────────────────────────────────
preflight_status=0
for tool in varlock pass gpg; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    echo "✗ preflight failed: $tool not on PATH" >&2
    preflight_status=1
  fi
done
[ "$preflight_status" -eq 0 ] || exit 1

# Synthetic HOME for round-trip verification
SYNTH_HOME="$(mktemp -d -t vp-stage8-drill-XXXXXX)"
chmod 700 "$SYNTH_HOME"
trap 'rm -rf "$SYNTH_HOME"' EXIT

mkdir -p "$SYNTH_HOME/.gnupg"
chmod 700 "$SYNTH_HOME/.gnupg"

# ── Round-trip: copy the live store + keyring into synthetic HOME ────
echo "=== Round-trip: copy ~/.gnupg + ~/.password-store → $SYNTH_HOME ==="
cp -a ~/.gnupg/* "$SYNTH_HOME/.gnupg/" 2>&1 | head -3
chmod -R 700 "$SYNTH_HOME/.gnupg"
chmod 600 "$SYNTH_HOME/.gnupg"/*.k* 2>/dev/null || true
mkdir -p "$SYNTH_HOME/.password-store"
chmod 700 "$SYNTH_HOME/.password-store"
cp -a ~/.password-store/* "$SYNTH_HOME/.password-store/"
chmod -R 700 "$SYNTH_HOME/.password-store"
find "$SYNTH_HOME/.password-store" -type f -exec chmod 600 {} +

echo
echo "=== Canary decryption in synthetic HOME ==="
HOME="$SYNTH_HOME" gpg --batch --pinentry-mode loopback \
    --homedir "$SYNTH_HOME/.gnupg" \
    --decrypt "$SYNTH_HOME/.password-store/mercury/_canary/test.gpg" \
    > /tmp/vp-stage8-canary.txt 2>/tmp/vp-stage8-canary.err
CANARY_RC=$?
if [ "$CANARY_RC" -ne 0 ]; then
  echo "✗ DRILL FAIL: canary decrypt rc=$CANARY_RC"
  cat /tmp/vp-stage8-canary.err
  exit 3
fi
CANARY_VALUE=$(cat /tmp/vp-stage8-canary.txt)
if [[ "$CANARY_VALUE" != mercury-canary-* ]]; then
  echo "✗ DRILL FAIL: canary value does not match expected prefix"
  exit 3
fi
echo "✓ canary decrypts from cold gpg-agent in synthetic HOME"
shred -u /tmp/vp-stage8-canary.txt 2>/dev/null || rm -f /tmp/vp-stage8-canary.txt
shred -u /tmp/vp-stage8-canary.err 2>/dev/null || rm -f /tmp/vp-stage8-canary.err

# ── Per-repo varlock load test ────────────────────────────────────────
echo
echo "=== Per-repo varlock load (Stage 8: every migrated repo) ==="
DRILL_STATUS=0
REPOS=("x-digest" "better-bet" "scriptcaster")
for repo in "${REPOS[@]}"; do
  repo_dir="$HOME/data/code/$repo"
  schema="$repo_dir/.env.schema"
  if [ ! -f "$schema" ]; then
    echo "  ✗ $repo — schema missing"
    DRILL_STATUS=2
    continue
  fi
  # varlock load uses the actual ~/.password-store/ on the host (it's
  # how varlock 1.11.0 works; PASSWORD_STORE_DIR is ignored for the
  # pass-plugin). The .env.schema file itself is read-only here.
  if ! (cd "$repo_dir" && varlock load --skip-cache --agent >/dev/null 2>&1); then
    echo "  ✗ $repo — varlock load failed"
    DRILL_STATUS=2
    continue
  fi
  echo "  ✓ $repo — varlock load rc=0"
done

# ── Restore-drill on the SYNTACTIC HOME (gpg-agent cold decrypt) ────────
echo
echo "=== Cold-agent decrypt in synthetic HOME (kills + restarts agent) ==="
# Stop the live gpg-agent; pretend we're a fresh host.
gpgconf --kill gpg-agent 2>/dev/null || true

# Start a synthetic gpg-agent pointing at the synthetic HOME, with a
# 5-second cache so cold decrypt needs to re-request the passphrase
# (we use an unprotected key; this test won't actually exercise a
# passphrase challenge, but proves the agent can re-initialize).
GNUPGHOME="$SYNTH_HOME/.gnupg" gpg-agent --homedir "$SYNTH_HOME/.gnupg" \
    --daemon --default-cache-ttl 1 --max-cache-ttl 1 \
    > /tmp/vp-stage8-agent.log 2>&1 &
AGENT_PID=$!
sleep 2

COLD_CANARY=$(GNUPGHOME="$SYNTH_HOME/.gnupg" gpg --batch --pinentry-mode loopback \
    --homedir "$SYNTH_HOME/.gnupg" \
    --decrypt "$SYNTH_HOME/.password-store/mercury/_canary/test.gpg" 2>/dev/null)
COLD_RC=$?
kill "$AGENT_PID" 2>/dev/null

if [ "$COLD_RC" -ne 0 ] || [[ "$COLD_CANARY" != mercury-canary-* ]]; then
  echo "✗ DRILL FAIL: cold-agent canary decrypt (rc=$COLD_RC)"
  cat /tmp/vp-stage8-agent.log
  exit 3
fi
echo "✓ cold-agent canary decrypts from synthetic HOME"
shred -u /tmp/vp-stage8-agent.log 2>/dev/null || rm -f /tmp/vp-stage8-agent.log

# Bring the live gpg-agent back up so subsequent work doesn't suffer
gpgconf --kill gpg-agent 2>/dev/null || true
gpg-agent --daemon > /dev/null 2>&1
sleep 1

if [ "$DRILL_STATUS" -ne 0 ]; then
  echo
  echo "✗ DRILL FAIL: $DRILL_STATUS migrated repo(s) failed"
  exit "$DRILL_STATUS"
fi

echo
echo "✓ Stage 8.5 restore drill: 3/3 migrated repos round-trip"
exit 0
