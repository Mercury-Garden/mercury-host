#!/usr/bin/env bash
# scripts/openviking-prepare-openrouter-env.sh
# Materialize a single-key environment file from ~/.hermes/.env so the
# OpenViking systemd unit can pick OPENROUTER_API_KEY up via
# EnvironmentFile= without (a) inlining the key value in the unit file
# or (b) sourcing the entire Hermes .env into the OpenViking process.
#
# Used as ExecStartPre= in systemd/user/openviking-server.service.
# Idempotent: re-runs just refresh the tempfile.
set -euo pipefail
ENV_OUT="${HOME}/.openviking/.openrouter-env"
install -m 0600 /dev/null "$ENV_OUT"
# Source ~/.hermes/.env. This script runs under systemd with HOME=/home/ubuntu,
# so the path is well-defined at runtime even though static analysis cannot
# resolve it from the current shell's cwd.
# SC1091 (info): non-resolvable source path — silenced deliberately.
# shellcheck disable=SC1091
set -a; . "${HOME}/.hermes/.env"; set +a
if [ -z "${OPENROUTER_API_KEY:-}" ]; then
  echo "FATAL: OPENROUTER_API_KEY not set in ${HOME}/.hermes/.env" >&2
  exit 1
fi
printf 'OPENROUTER_API_KEY=%s\n' "$OPENROUTER_API_KEY" > "$ENV_OUT"
chmod 0600 "$ENV_OUT"
