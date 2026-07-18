
# Toolchain — mise (formerly Volta, unmaintained 2025).
# Verified 2026-07-18 during the volta→mise migration.
if command -v mise >/dev/null 2>&1; then
  eval "$(mise activate zsh)"
fi
# End toolchain.
. "$HOME/.cargo/env"
