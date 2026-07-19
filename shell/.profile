
# Toolchain — mise (formerly Volta, unmaintained 2025).
# bash login shells only; zsh and interactive shells source via .zshrc
# instead. Same SSH-login-shell caveat as ~/.zshenv: resolve mise via
# its absolute install path first (login shells start with a minimal
# PATH that doesn't include ~/.local/bin).
# Updated 2026-07-18 for the SSH-login-shell fix (PR #72 follow-up).
MISE_BIN="$HOME/.local/bin/mise"
if [ -x "$MISE_BIN" ]; then
  eval "$("$MISE_BIN" activate bash)"
elif command -v mise >/dev/null 2>&1; then
  eval "$(mise activate bash)"
fi
# End toolchain.
. "$HOME/.cargo/env"
