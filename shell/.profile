
# Toolchain — mise (formerly Volta, unmaintained 2025).
# bash login shells only; zsh and interactive shells source via .zshrc instead.
# Verified 2026-07-18 during the volta→mise migration.
if command -v mise >/dev/null 2>&1; then
  eval "$(mise activate bash)"
fi
# End toolchain.
. "$HOME/.cargo/env"
