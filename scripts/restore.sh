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

# ── 3. Mise (formerly Volta, unmaintained 2025) ─────────────────────────
# Verified 2026-07-18 during the volta→mise migration. install puts the
# binary at ~/.local/bin/mise by default; the tool install tree lands at
# ~/.local/share/mise, which is on the data volume via the existing
# ~/.local/share symlink created in [user_cache] (4.5).
echo "[mise] installing mise"
if ! command -v mise >/dev/null 2>&1; then
  curl -fsSL https://mise.run | sh
  # Activating here so the subsequent `mise use` already has the symlink
  # context. On a fresh host this installs Node + toolchain listed in
  # packages/node.yaml; pnpm is left to be activated per-project via
  # corepack (declared in each package.json#packageManager).
  eval "$(~/.local/bin/mise activate bash)"
  export PATH="$HOME/.local/bin:$PATH"
fi

echo "[mise] configuring default toolchain"
# `default_node` + `default_pnpm` are read from packages/node.yaml under
# node_managers.mise; we only set the ones that are explicit. pnpm is
# corepack-managed per-project — the global pin (default_pnpm) is for
# tooling outside of any repo (rare).
mise use --global "node@$(awk '/^ *default_node:/{gsub(/['\''"]/, ""); print $2; exit}' "$REPO_ROOT/packages/node.yaml")"
if grep -q '^ *default_pnpm:' "$REPO_ROOT/packages/node.yaml"; then
  mise use --global "pnpm@$(awk '/^ *default_pnpm:/{gsub(/['\''"]/, ""); print $2; exit}' "$REPO_ROOT/packages/node.yaml")"
fi

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
echo "[systemd] disabling legacy system-level backup unit (if present)"
# Pre-PR-#59 setup created a duplicate of mercury-state-backup.{timer,service}
# in /etc/systemd/system/ (system manager) AND ~/.config/systemd/user/
# (user manager). The user-manager copy is the live source of truth and
# the one this script symlinks; the system-manager copy is a legacy
# artifact from the initial 2026-06-30 bootstrap. Disable + remove it
# so we have exactly one unit per concern. Idempotent: if it's already
# gone, the step prints nothing and moves on. (Discovered 2026-07-14
# while tracing the Jul 8 backup gap — the system-level unit's
# Persistent=true catch-up race was the root cause hypothesis.)
LEGACY_BACKUP_UNITS=(
    /etc/systemd/system/mercury-state-backup.service
    /etc/systemd/system/mercury-state-backup.timer
)
for legacy in "${LEGACY_BACKUP_UNITS[@]}"; do
    if [ -L "$legacy" ] || [ -f "$legacy" ]; then
        unit_name="$(basename "$legacy")"
        if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
            sudo -n systemctl disable --now "$unit_name" 2>/dev/null || true
            sudo -n rm -f "$legacy"
            echo "  - removed legacy system-level $unit_name"
        else
            echo "  ! found $legacy but no NOPASSWD sudo — leave for manual cleanup"
        fi
    fi
done

echo "Restore complete. Manual steps remaining:"
echo "  - copy nginx/sites-available/* to /etc/nginx/sites-available/"
echo "  - sudo ln -s /etc/nginx/sites-available/<vhost> /etc/nginx/sites-enabled/"
echo "  - sudo nginx -t && sudo systemctl reload nginx"
echo "  - copy secrets/ to their final locations (NEVER commit values)"