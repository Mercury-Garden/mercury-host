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

# ── 4.5. User cache symlinks (post-2026-07-05 cache relocation) ──────
# ~/.cache and ~/.local/share are now symlinks pointing at
# /home/ubuntu/data/.cache and /home/ubuntu/data/.local/share. On a
# fresh host, both the sdb data volume AND the target dirs must exist
# before symlinking — otherwise the symlinks dangle and every tool
# (pnpm, uv, playwright, hermes-gateway mmap loads) breaks.
#
# This step is intentionally BEFORE [systemd] so that when the user
# services come up, the cache symlinks already resolve to real dirs.
# Inventory source of truth: inventory.yaml → user_cache_paths.
echo "[user_cache] creating cache symlinks on sdb"
DATA_VOL="/home/ubuntu/data"
if [ -d "$DATA_VOL" ]; then
  mkdir -p "$DATA_VOL/.cache" "$DATA_VOL/.local/share"
  for entry in "$HOME/.cache:$DATA_VOL/.cache" \
               "$HOME/.local/share:$DATA_VOL/.local/share"; do
    src="${entry%%:*}"
    dst="${entry##*:}"
    if [ -L "$src" ]; then
      echo "  $src already a symlink (skip)"
      continue
    fi
    if [ -d "$src" ] && [ ! -L "$src" ]; then
      echo "  WARN: $src is a real directory on the boot volume"
      echo "        this fresh host does not match inventory.yaml → user_cache_paths"
      echo "        (you may want to migrate it before continuing; see references)"
    fi
    ln -s "$dst" "$src"
    echo "  $src -> $dst"
  done
else
  echo "  WARN: $DATA_VOL not present — cache symlinks not created"
  echo "        mount the data volume, create $DATA_VOL, then run:"
  echo "        mkdir -p $DATA_VOL/.cache $DATA_VOL/.local/share"
  echo "        ln -s $DATA_VOL/.cache $HOME/.cache"
  echo "        ln -s $DATA_VOL/.local/share $HOME/.local/share"
fi

# ── 5. systemd user units enabled (services + timers, user/ + system/) ──
#
# Why both dirs and both kinds:
#   - `systemd/user/` holds most of our services (hermes-gateway, oauth2-proxy,
#     mercury-tasks, openchamber, obscura-mcp).
#   - `systemd/system/` holds mercury-state-backup.{service,timer} — it
#     needs `HOME=/home/ubuntu` pinned, `StandardOutput=journal`, and to
#     fire at 03:00 Bogota before any user session may be active. Moving
#     it to `user/` would silently regress all three. (See
#     inventory.yaml `state_backup:` block for the canonical note.)
#
# Why symlink instead of copy: the backup units in particular get
# hand-edited and pulled frequently (see PRs #34, #38). Symlink means
# `git pull && systemctl --user daemon-reload` picks up the change with
# no re-run of restore.sh. A copy would silently desync.
#
# Idempotent: re-running this block is a no-op. `enable` on an already-
# enabled unit exits 0. The symlink `ln -sf` is a no-op if the target
# already points at the right source.
echo "[systemd] enabling user units"
mkdir -p "$HOME/.config/systemd/user/"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"

enable_unit() {
  local src="$1"
  local name dst
  name="$(basename "$src")"
  dst="$SYSTEMD_USER_DIR/$name"
  # If something is already in place pointing at the right source, skip.
  if [ -L "$dst" ] && [ "$(readlink -f "$dst")" = "$(readlink -f "$src")" ]; then
    echo "  ✓ $name (already symlinked)"
  else
    # Remove any pre-existing file/symlink/copy so ln -sf can replace it.
    rm -f "$dst"
    ln -s "$src" "$dst"
    echo "  + $name (symlinked)"
  fi
  systemctl --user enable "$name"
  # Timers need an explicit start to schedule their next fire.
  # `enable` alone leaves ActiveState=inactive with no NextElapseUSecRealtime.
  # Services are oneshot; `start` on an already-active one is a no-op.
  case "$name" in
    *.timer) systemctl --user start "$name" ;;
  esac
}

for unit in "$REPO_ROOT"/systemd/user/*.service \
            "$REPO_ROOT"/systemd/system/*.service \
            "$REPO_ROOT"/systemd/system/*.timer; do
  [ -f "$unit" ] || continue
  enable_unit "$unit"
done

# Pick up any newly-added/renamed units. Safe to run on every restore;
# it is a no-op when nothing changed.
systemctl --user daemon-reload

echo
echo "Restore complete. Manual steps remaining:"
echo "  - copy nginx/sites-available/* to /etc/nginx/sites-available/"
echo "  - sudo ln -s /etc/nginx/sites-available/<vhost> /etc/nginx/sites-enabled/"
echo "  - sudo nginx -t && sudo systemctl reload nginx"
echo "  - copy secrets/ to their final locations (NEVER commit values)"