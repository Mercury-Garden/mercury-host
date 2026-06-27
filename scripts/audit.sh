#!/usr/bin/env bash
# scripts/audit.sh — read inventory.yaml and check a live host against it.
# Exits 0 if everything matches, 1 if any drift is found. Drift is printed
# in human-readable lines. Designed to be safe to run as a cron — non-zero
# exit on drift, so a wrapping cron job can notify.
#
# IMPORTANT: run under the user's interactive shell, not under a service
# account. This script sources ~/.zshrc to get the user's real PATH,
# otherwise it would report volta as missing whenever it runs under
# hermes-agent's venv-isolated PATH.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INV="$REPO_ROOT/inventory.yaml"
PKG_NODE="$REPO_ROOT/packages/node.yaml"

# Try to reconstruct the user's real PATH. Hermes-agent shells don't have
# volta on PATH; a real login shell does.
if [ -z "${USER_SHELL_LOADED:-}" ]; then
  if [ -f "$HOME/.zshrc" ] && command -v zsh >/dev/null 2>&1; then
    USER_PATH=$(zsh -i -c 'echo $PATH' 2>/dev/null | tail -1)
  elif [ -f "$HOME/.bashrc" ]; then
    USER_PATH=$(bash -i -c 'echo $PATH' 2>/dev/null | tail -1)
  fi
  if [ -n "${USER_PATH:-}" ]; then
    export PATH="$USER_PATH"
  fi
  export USER_SHELL_LOADED=1
fi

DRIFT=0
note() { printf '  %s\n' "$*"; }
drift() { printf '✗ DRIFT: %s\n' "$*"; DRIFT=$((DRIFT + 1)); }
ok()    { printf '✓ %s\n' "$*"; }

require_yaml_field() {
  # Recursively read a nested-ish YAML key. Handles the leading "  " indent
  # we use for sub-keys under node_managers.* in packages/node.yaml.
  local file="$1" key="$2"
  awk -v k="$key" '
    {
      stripped = $0
      sub(/^[ \t]+/, "", stripped)
      if (stripped ~ "^"k":") {
        sub("^"k":[ \t]*", "", stripped)
        gsub(/[ \t]+$/, "", stripped)
        print stripped
        exit
      }
    }
  ' "$file"
}

echo "=== mercury-host audit — $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

# ── 1. Volta + Node toolchain ────────────────────────────────────────────
echo
echo "[volta]"
if ! command -v volta >/dev/null 2>&1; then
  drift "volta not on PATH (after sourcing user shell)"
else
  ok "volta present: $(volta --version)"
fi

EXPECT_NODE=$(require_yaml_field "$PKG_NODE" "default_node")
EXPECT_NPM=$(require_yaml_field "$PKG_NODE" "default_npm")
EXPECT_PNPM=$(require_yaml_field "$PKG_NODE" "default_pnpm")

ACTUAL_NODE=$(volta list 2>/dev/null | awk '/^runtime node/ {print $2; exit}' | sed -E 's/^[^@]+@//; s/[()]//g')
ACTUAL_NPM=$(volta list 2>/dev/null | awk '/^package-manager npm/ {print $2; exit}' | sed -E 's/^[^@]+@//; s/[()]//g')
ACTUAL_PNPM=$(volta list 2>/dev/null | awk '/^package pnpm/ {print $2; exit}' | sed -E 's/^[^@]+@//; s/[()]//g')

if [ "$ACTUAL_NODE" = "$EXPECT_NODE" ]; then
  ok "default node = $EXPECT_NODE"
else
  drift "default node = '$ACTUAL_NODE' (expected '$EXPECT_NODE')"
fi
if [ "$ACTUAL_NPM" = "$EXPECT_NPM" ]; then
  ok "default npm = $EXPECT_NPM"
else
  drift "default npm = '$ACTUAL_NPM' (expected '$EXPECT_NPM')"
fi
if [ "$ACTUAL_PNPM" = "$EXPECT_PNPM" ]; then
  ok "default pnpm = $EXPECT_PNPM"
else
  drift "default pnpm = '$ACTUAL_PNPM' (expected '$EXPECT_PNPM')"
fi

# ── 2. Hermes bundled node ───────────────────────────────────────────────
echo
echo "[hermes]"
if [ ! -x "$HOME/.hermes/node/bin/node" ]; then
  drift "$HOME/.hermes/node/bin/node missing"
else
  HN=$("$HOME/.hermes/node/bin/node" --version)
  ok "hermes node = $HN"
fi

# ── 3. Project registry: every tracked project present + has a volta pin ─
echo
echo "[projects]"
while IFS=$'\t' read -r path repo expected_branch; do
  [ -z "$path" ] && continue
  # Expand leading ~ to $HOME, then resolve to absolute
  full="${path/#\~/$HOME}"
  if [ ! -d "$full" ]; then
    drift "$path (repo $repo) missing on disk"
    continue
  fi
  ok "$path present"
  if [ -f "$full/package.json" ]; then
    PINNED_NODE=$(python3 -c "import json; d=json.load(open('$full/package.json')); v=d.get('volta',{}); print(v.get('node',''))" 2>/dev/null)
    if [ -z "$PINNED_NODE" ]; then
      drift "  REPRODUCIBILITY: $full/package.json has no 'volta.node' pin"
    else
      ok "  volta pin = $PINNED_NODE"
    fi
  fi
  if [ -n "$expected_branch" ] && [ -d "$full/.git" ]; then
    ACTUAL=$(git -C "$full" branch --show-current 2>/dev/null)
    if [ "$ACTUAL" = "$expected_branch" ]; then
      ok "  branch = $expected_branch"
    else
      note "  branch = '$ACTUAL' (expected '$expected_branch')"
    fi
  fi
# Use python to parse the projects section — yaml is too gnarly for awk.
done < <(python3 - "$INV" <<'PYEOF'
import sys, yaml
inv_path = sys.argv[1]
data = yaml.safe_load(open(inv_path))
for proj in data.get('projects', []):
    path = proj.get('path', '')
    repo = proj.get('repo', '')
    branch = proj.get('expected_branch', '')
    if path:
        print(f"{path}\t{repo}\t{branch}")
PYEOF
)

# ── 4. systemd services enabled (NOT just active) ───────────────────────
# Split by kind: user services checked via systemctl --user, system services via plain systemctl.
# External services (owned by Ubuntu package) are still checked — if they're not enabled
# that's a real drift — but the inventory.yaml `external: true` flag tells us not to
# expect them to be in our tracked unit files.
echo
echo "[systemd-user]"
for svc in hermes-gateway mercury-tasks oauth2-proxy openchamber webhook-server discord-notify session-migration; do
  if systemctl --user is-enabled "$svc" >/dev/null 2>&1; then
    ok "$svc enabled (user)"
  else
    drift "$svc NOT enabled (user)"
  fi
done
echo
echo "[systemd-system]"
for svc in nginx ollama cron hermes-dashboard; do
  if systemctl is-enabled "$svc" >/dev/null 2>&1; then
    ok "$svc enabled (system)"
  else
    note "$svc NOT enabled (system) — may be intentional (e.g., ollama on this host is not running)"
  fi
done

# ── 5. nginx vhosts enabled ──────────────────────────────────────────────
# nginx includes both regular files AND symlinks from sites-enabled/.
# Use -e (any exists) instead of -L (only symlink).
echo
echo "[nginx]"
for vhost in mercury.garden tasks.mercury.garden chamber.mercury.garden dev.mercury.garden plans.mercury.garden webhook.mercury.garden hermes.mercury.garden; do
  if [ -e "/etc/nginx/sites-enabled/$vhost" ]; then
    if [ -L "/etc/nginx/sites-enabled/$vhost" ]; then
      ok "$vhost enabled (symlink)"
    else
      note "$vhost enabled (regular file — consider converting to symlink for consistency)"
    fi
  else
    drift "$vhost NOT in sites-enabled"
  fi
done

# ── 6. Letsencrypt ───────────────────────────────────────────────────────
echo
echo "[letsencrypt]"
if [ -d /etc/letsencrypt/live/mercury.garden ]; then
  ok "/etc/letsencrypt/live/mercury.garden present"
else
  drift "/etc/letsencrypt/live/mercury.garden missing"
fi

# ── 7. PATH order (uses already-reconstructed USER_PATH) ─────────────────
echo
echo "[path]"
# Read the first entry of path_order_required from node.yaml
EXPECTED_FIRST=$(awk '/^path_order_required:/{flag=1; next} flag && /^  - /{print $2; exit}' "$PKG_NODE" | sed "s|^~|$HOME|")
FIRST=$(echo "$PATH" | tr ':' '\n' | head -1)
if [ "$FIRST" = "$EXPECTED_FIRST" ]; then
  ok "PATH starts with $EXPECTED_FIRST"
else
  drift "PATH starts with '$FIRST' (expected '$EXPECTED_FIRST')"
fi

# ── summary ──────────────────────────────────────────────────────────────
echo
if [ "$DRIFT" -eq 0 ]; then
  echo "✓ no drift"
  exit 0
else
  echo "✗ $DRIFT drift item(s)"
  exit 1
fi