
# Toolchain — mise (formerly Volta, unmaintained 2025).
# Login shells start with a minimal PATH (no ~/.local/bin), so `mise`
# isn't on PATH yet when .zshenv runs. We resolve mise via its absolute
# install path first (fast path), then fall back to `command -v` for
# non-standard installs. Verified 2026-07-18 during the volta→mise
# migration; updated 2026-07-18 for the SSH-login-shell fix (node not
# found over SSH — see PR #72 follow-up).
MISE_BIN="$HOME/.local/bin/mise"
if [ -x "$MISE_BIN" ]; then
  eval "$("$MISE_BIN" activate zsh)"
elif command -v mise >/dev/null 2>&1; then
  eval "$(mise activate zsh)"
fi
# End toolchain.
. "$HOME/.cargo/env"
