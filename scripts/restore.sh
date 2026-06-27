#!/usr/bin/env bash
# scripts/restore.sh — given a fresh Ubuntu 24.04 image, apply this repo.
# Run as the user that will own the host (ubuntu). NOT idempotent end-to-end
# (apt installs and systemd --user enable are; nginx vhost deploy is manual).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INV="$REPO_ROOT/inventory.yaml"
# INV is referenced by the per-step echoes and by future restore steps; the
# current version only reads the package yaml, so we touch INV here to keep
# the variable live for shellcheck and for forthcoming enhancements.
: "$INV"

# ── 1. apt ───────────────────────────────────────────────────────────────
echo "[apt] installing manually-tracked packages"
if [ -f "$REPO_ROOT/packages/apt.list" ]; then
  xargs sudo apt-get install -y < "$REPO_ROOT/packages/apt.list"
fi

# ── 2. snap ──────────────────────────────────────────────────────────────
echo "[snap] restoring snap apps"
if command -v snap >/dev/null 2>&1 && [ -f "$REPO_ROOT/packages/snap.yaml" ]; then
  python3 -c "
import yaml
data = yaml.safe_load(open('$REPO_ROOT/packages/snap.yaml'))
for app in data.get('apps', []):
    classic = '--classic' if app.get('classic') else ''
    print(f'sudo snap install {app[\"name\"]} {classic} --channel={app[\"channel\"]}')
" | grep -v '^$' | bash
fi

# ── 3. Volta ─────────────────────────────────────────────────────────────
echo "[volta] installing Volta"
if ! command -v volta >/dev/null 2>&1; then
  curl -fsSL https://volta.sh/install.sh | bash -s -- --skip-setup
  export VOLTA_HOME="$HOME/.volta"
  export PATH="$VOLTA_HOME/bin:$PATH"
fi

echo "[volta] pinning default toolchain"
volta pin "node@$(awk '/^default_node:/{print $2; exit}' "$REPO_ROOT/packages/node.yaml")"
volta pin "npm@$(awk '/^default_npm:/{print $2; exit}' "$REPO_ROOT/packages/node.yaml")"
volta pin "pnpm@$(awk '/^default_pnpm:/{print $2; exit}' "$REPO_ROOT/packages/node.yaml")"

# ── 4. Per-project pins + install ────────────────────────────────────────
echo "[projects] restoring ~/data/code/* projects"
if [ -d "$HOME/data/code" ]; then
  for d in "$HOME"/data/code/*/; do
    [ -f "$d/package.json" ] || continue
    [ -d "$d/.git" ] || continue
    name=$(basename "$d")
    echo "  $name"
    ( cd "$d" && pnpm install --frozen-lockfile )
  done
fi

# ── 5. systemd user services enabled ─────────────────────────────────────
echo "[systemd] enabling user services"
mkdir -p "$HOME/.config/systemd/user/"
for unit in "$REPO_ROOT"/systemd/user/*.service; do
  [ -f "$unit" ] || continue
  cp "$unit" "$HOME/.config/systemd/user/"
  systemctl --user enable "$(basename "$unit")"
done

echo
echo "Restore complete. Manual steps remaining:"
echo "  - copy nginx/sites-available/* to /etc/nginx/sites-available/"
echo "  - sudo ln -s /etc/nginx/sites-available/<vhost> /etc/nginx/sites-enabled/"
echo "  - sudo nginx -t && sudo systemctl reload nginx"
echo "  - copy secrets/ to their final locations (NEVER commit values)"