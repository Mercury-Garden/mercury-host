#!/usr/bin/env bash
# scripts/backup-secrets.sh — snapshot every host secret to ~/.secrets/secrets.yaml.
#
# The output file is plaintext YAML with REAL secret values. It is
# written to ~/.secrets/ with mode 0600 and never leaves the host via
# this script. The matching `secrets/secrets.yaml.template` file in
# the repo is sanitized (placeholders only) and may be committed safely.
#
# What it captures (one section per entry in secrets/inventory.yaml):
#   ssh-ed25519-private           ~/.ssh/id_ed25519
#   gh-pat-merc                   ~/.config/gh/hosts.yml
#   gh-token-env                  ~/.hermes/.env  →  GITHUB_TOKEN value
#   oauth2-client-secret          ~/.config/oauth2-proxy/oauth2-proxy.cfg
#   oauth2-cookie-secret          ~/.config/oauth2-proxy/oauth2-proxy.cfg
#   hermes-env                    ~/.hermes/.env (full file, base64)
#   goose-secrets                 ~/.config/goose/secrets.yaml
#   letsencrypt-account-key       /etc/letsencrypt/accounts/.../account_key.json
#   letsencrypt-privkey-mercury   /etc/letsencrypt/live/mercury.garden/privkey.pem
#   mercury-tasks-tokens          /home/ubuntu/.config/mercury-tasks/tokens.json
#   x-digest-env                  ~/data/code/x-digest/.env
#   openchamber-startup-env       /home/ubuntu/.config/openchamber/startup.env
#   opencode-auth                 ~/.local/share/opencode/auth.json     (added 2026-06-30)
#   discord-notify                ~/.config/discord-notify/config.yaml  (added 2026-06-30)
#   gogcli                        ~/.config/gogcli/credentials.json + keyring/  (added 2026-06-30)
#   webhook-server                ~/.config/webhook-server/secret.txt + projects.yaml  (added 2026-06-30)
#
# Skipped on purpose:
#   ~/.hermes/auth.json           — only contains secret_fingerprints (sha256 of
#                                   the real keys, which live in ~/.hermes/.env).
#                                   Capturing it would bloat the file with no
#                                   new information.
#   ~/.hermes/state-snapshots/    — auto-managed; only valid one is the latest
#                                   auth.json above (skipped).
#
# Usage:
#   bash scripts/backup-secrets.sh          # writes ~/.secrets/secrets.yaml
#   bash scripts/backup-secrets.sh --force  # overwrite existing dump
#
# Restore: see scripts/restore-secrets.sh.

set -euo pipefail

DEST_DIR="${HOME}/.secrets"
DEST="${DEST_DIR}/secrets.yaml"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HOST="$(hostname)"

# Refuse to clobber an existing dump without --force.
if [ -f "$DEST" ] && [ "${1:-}" != "--force" ]; then
  echo "ERROR: $DEST already exists. Re-run with --force to overwrite," >&2
  echo "       or move the old file aside first." >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
chmod 700 "$DEST_DIR"

note() { printf '  %s\n' "$*" >&2; }
ok()   { printf '✓ %s\n' "$*" >&2; }
miss() { printf '  ! %s (not present, value will be null)\n' "$*" >&2; }

# ── read_env_value FILE KEY  →  prints value of KEY= (strips quotes/comments)
read_env_value() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 1
  python3 - "$file" "$key" <<'PYEOF'
import re, sys
path, key = sys.argv[1], sys.argv[2]
text = open(path).read()
m = re.search(rf'^{re.escape(key)}=(.*)$', text, re.MULTILINE)
if not m:
    sys.exit(1)
v = m.group(1).strip()
# Strip surrounding quotes
if len(v) >= 2 and ((v[0] == '"' and v[-1] == '"') or (v[0] == "'" and v[-1] == "'")):
    v = v[1:-1]
else:
    # Strip trailing inline comment for unquoted values
    v = re.split(r'\s+#', v, maxsplit=1)[0].rstrip()
print(v)
PYEOF
}

# ── read_oauth2_key FILE KEY  →  prints value of "key = \"value\"" line
read_oauth2_key() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 1
  python3 - "$file" "$key" <<'PYEOF'
import re, sys
path, key = sys.argv[1], sys.argv[2]
text = open(path).read()
m = re.search(rf'^\s*{re.escape(key)}\s*=\s*"([^"]*)"', text, re.MULTILINE)
if not m:
    sys.exit(1)
print(m.group(1))
PYEOF
}

# ── base64_encode FILE  →  emits base64 on a single line (no wrapping)
b64() {
  local file="$1"
  [ -f "$file" ] || return 1
  base64 -w 0 "$file"
}

# ── emit a scalar string value on the SAME line as the key, with proper YAML quoting
# Usage: emit_scalar_inline "key" "value"   →  prints key: "escaped-value"
emit_scalar_inline() {
  local key="$1" value="$2"
  # Double-quote the value; escape backslashes + double-quotes.
  local escaped="${value//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  printf '%s: "%s"\n' "$key" "$escaped"
}

# ── emit a YAML literal block of a base64 string (chunked for readability)
# Adds a YAML literal-block indicator `|-` on the key line, then emits the
# base64 content in fixed-width columns (4 lines of 76 chars ≈ 304 chars
# per stanza, matching OpenSSL's PEM line width by convention).
# Result is a proper YAML literal scalar that round-trips through PyYAML.
#
# Usage: emit_b64_block "key" "file"   →  prints "key: |\n      <b64>"
# If file is missing, prints "key: null" and returns 1.
emit_b64_block() {
  local key="$1" file="$2"
  if [ -f "$file" ]; then
    printf '%s: |\n' "$key"
    base64 -w 76 "$file" | awk '{printf "      %s\n", $0}'
    return 0
  else
    printf '%s: null\n' "$key"
    return 1
  fi
}

# ── pack a directory of files into a single tar.gz, then base64 it as a
# YAML literal block. Used for the gogcli keyring/ which has 3 binary
# encrypted blobs that need to stay together to be useful.
#
# Usage: pack_dir_b64_block "key" "/path/to/dir"   →  prints "key: |\n      <b64>"
# If dir is missing, prints "key: null" and returns 1.
pack_dir_b64_block() {
  local key="$1" dir="$2"
  if [ -d "$dir" ]; then
    printf '%s: |\n' "$key"
    tar -C "$(dirname "$dir")" -czf - "$(basename "$dir")" \
      | base64 -w 76 \
      | awk '{printf "      %s\n", $0}'
    return 0
  else
    printf '%s: null\n' "$key"
    return 1
  fi
}

# ── emit a scalar string value, with proper YAML quoting
emit_scalar() {
  local value="$1"
  if [ -z "$value" ]; then
    printf 'null\n'
  else
    # Double-quote; escape backslashes + double-quotes.
    local escaped="${value//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    printf '"%s"\n' "$escaped"
  fi
}

echo "=== mercury-host secrets backup — ${TIMESTAMP} ==="
echo
echo "Destination: ${DEST} (mode 0600)"
echo

# Pull the values we need. Doing this in plain bash to keep the script
# auditable; the Python helpers handle the trickier string parsing.
GH_TOKEN="$(read_env_value "${HOME}/.hermes/.env" GITHUB_TOKEN || true)"
OAUTH2_CFG="${HOME}/.config/oauth2-proxy/oauth2-proxy.cfg"
OAUTH2_CLIENT_SECRET="$(read_oauth2_key "$OAUTH2_CFG" client_secret || true)"
OAUTH2_COOKIE_SECRET="$(read_oauth2_key "$OAUTH2_CFG" cookie_secret || true)"
MT_TOKENS="/home/ubuntu/.config/mercury-tasks/tokens.json"
XD_ENV="${HOME}/data/code/x-digest/.env"
OC_ENV="${HOME}/.config/openchamber/startup.env"
ACCT_KEY="$(find /etc/letsencrypt/accounts -name account_key.json 2>/dev/null | head -1 || true)"
PRIVKEY_LINK="/etc/letsencrypt/live/mercury.garden/privkey.pem"
PRIVKEY_REAL="$(readlink -f "$PRIVKEY_LINK" 2>/dev/null || echo "$PRIVKEY_LINK")"

# ── NEW kinds (added 2026-06-30 after opencode auth.json was identified as
#    missing from the original 12-source list). Each one is a host-restorable
#    secret needed to fully recreate the operational state.
OPENCODE_AUTH="${HOME}/.local/share/opencode/auth.json"
DISCORD_NOTIFY_CFG="${HOME}/.config/discord-notify/config.yaml"
GOGCLI_CREDENTIALS="${HOME}/.config/gogcli/credentials.json"
GOGCLI_KEYRING_DIR="${HOME}/.config/gogcli/keyring"
WEBHOOK_SERVER_DIR="${HOME}/.config/webhook-server"

# Build the YAML
{
  echo "---"
  echo "# secrets.yaml — LIVE host secrets for ${HOST}"
  echo "# Generated: ${TIMESTAMP}"
  echo "# Source: scripts/backup-secrets.sh in Mercury-Garden/mercury-host"
  echo "#"
  echo "# DO NOT COMMIT THIS FILE. DO NOT COPY IT OFF THIS HOST."
  echo "# The matching secrets.yaml.template in the repo has the same"
  echo "# structure but with every value replaced by a <set from ...>"
  echo "# placeholder. Bootstrap a fresh host with:"
  echo "#   bash scripts/restore-secrets.sh /path/to/secrets.yaml"
  echo
  echo "# ── SSH ────────────────────────────────────────────────────────"
  emit_b64_block "ssh_ed25519_private" "${HOME}/.ssh/id_ed25519" || miss "$HOME/.ssh/id_ed25519"
  emit_b64_block "ssh_ed25519_public" "${HOME}/.ssh/id_ed25519.pub" || miss "$HOME/.ssh/id_ed25519.pub"
  echo
  echo "# ── GitHub ──────────────────────────────────────────────────────"
  emit_b64_block "gh_hosts_yml" "${HOME}/.config/gh/hosts.yml" || miss "$HOME/.config/gh/hosts.yml"
  if [ -n "$GH_TOKEN" ]; then
    emit_scalar_inline "gh_token_env" "$GH_TOKEN"
    ok "GITHUB_TOKEN captured"
  else
    echo "gh_token_env: null"
    miss "GITHUB_TOKEN in ~/.hermes/.env"
  fi
  echo
  echo "# ── oauth2-proxy ────────────────────────────────────────────────"
  if [ -n "$OAUTH2_CLIENT_SECRET" ]; then
    emit_scalar_inline "oauth2_client_secret" "$OAUTH2_CLIENT_SECRET"
    ok "oauth2 client_secret captured"
  else
    echo "oauth2_client_secret: null"
    miss "oauth2 client_secret"
  fi
  if [ -n "$OAUTH2_COOKIE_SECRET" ]; then
    emit_scalar_inline "oauth2_cookie_secret" "$OAUTH2_COOKIE_SECRET"
    ok "oauth2 cookie_secret captured"
  else
    echo "oauth2_cookie_secret: null"
    miss "oauth2 cookie_secret"
  fi
  echo
  echo "# ── Hermes ──────────────────────────────────────────────────────"
  emit_b64_block "hermes_env" "${HOME}/.hermes/.env" || miss "$HOME/.hermes/.env"
  # Per-profile envs. Auto-discovered: any ~/.hermes/profiles/<name>/.env
  # becomes `hermes_profile_<name>_env` (b64). Its GITHUB_TOKEN value (if
  # present) is also emitted as `gh_token_env_profile_<name>` (scalar) so
  # a restore can put the right token in the right file even if the .env
  # is otherwise empty. Profile names with hyphens are preserved verbatim
  # in the YAML key (YAML allows them) and the dash-separated kind
  # identifier used by restore-secrets.sh --include.
  PROFILES_DIR="${HOME}/.hermes/profiles"
  if [ -d "$PROFILES_DIR" ]; then
    for PROF_ENV in "$PROFILES_DIR"/*/.env; do
      [ -f "$PROF_ENV" ] || continue
      PROF_NAME=$(basename "$(dirname "$PROF_ENV")")
      KEY="hermes_profile_${PROF_NAME}_env"
      if emit_b64_block "$KEY" "$PROF_ENV"; then
        ok "$KEY captured"
        PROF_TOKEN="$(read_env_value "$PROF_ENV" GITHUB_TOKEN || true)"
        if [ -n "$PROF_TOKEN" ]; then
          emit_scalar_inline "gh_token_env_profile_${PROF_NAME}" "$PROF_TOKEN"
          ok "gh_token_env_profile_${PROF_NAME} captured"
        else
          echo "gh_token_env_profile_${PROF_NAME}: null"
        fi
      else
        miss "$PROF_ENV"
      fi
    done
  else
    note "$PROFILES_DIR not present; skipping per-profile hermes envs"
  fi
  echo
  echo "# ── Goose ───────────────────────────────────────────────────────"
  emit_b64_block "goose_secrets" "${HOME}/.config/goose/secrets.yaml" || miss "$HOME/.config/goose/secrets.yaml"
  echo
  echo "# ── Letsencrypt ─────────────────────────────────────────────────"
  printf 'letsencrypt_account_key_path: "%s"\n' "${ACCT_KEY:-}"
  emit_b64_block "letsencrypt_account_key" "$ACCT_KEY" || miss "/etc/letsencrypt/accounts/.../account_key.json"
  printf 'letsencrypt_privkey_path: "%s"\n' "$PRIVKEY_LINK"
  printf 'letsencrypt_privkey_real_path: "%s"\n' "$PRIVKEY_REAL"
  emit_b64_block "letsencrypt_privkey" "$PRIVKEY_REAL" || miss "letsencrypt privkey"
  echo
  echo "# ── mercury-tasks ───────────────────────────────────────────────"
  emit_b64_block "mercury_tasks_tokens" "$MT_TOKENS" || miss "mercury-tasks tokens"
  echo
  echo "# ── x-digest ────────────────────────────────────────────────────"
  emit_b64_block "x_digest_env" "$XD_ENV" || miss "x-digest .env"
  echo
  echo "# ── openchamber ─────────────────────────────────────────────────"
  emit_b64_block "openchamber_startup_env" "$OC_ENV" || miss "openchamber startup.env"
  echo
  echo "# ── opencode auth (provider API keys) ───────────────────────────"
  emit_b64_block "opencode_auth" "$OPENCODE_AUTH" || miss "$HOME/.local/share/opencode/auth.json"
  echo
  echo "# ── discord-notify (per-project HMAC + chat IDs) ───────────────"
  emit_b64_block "discord_notify_config" "$DISCORD_NOTIFY_CFG" || miss "$HOME/.config/discord-notify/config.yaml"
  echo
  echo "# ── gogcli (Gmail OAuth client creds + encrypted keyring) ───────"
  emit_b64_block "gogcli_credentials" "$GOGCLI_CREDENTIALS" || miss "$HOME/.config/gogcli/credentials.json"
  # The keyring is a directory of 3 encrypted blobs; pack as tar.gz + b64.
  # Restoring requires GOG_KEYRING_PASSWORD from hermes .env to decrypt.
  pack_dir_b64_block "gogcli_keyring_tar_gz" "$GOGCLI_KEYRING_DIR" || miss "$HOME/.config/gogcli/keyring"
  echo
  echo "# ── webhook-server (HMAC signing key + per-project secrets) ────"
  emit_b64_block "webhook_server_secret" "$WEBHOOK_SERVER_DIR/secret.txt" || miss "$HOME/.config/webhook-server/secret.txt"
  emit_b64_block "webhook_server_projects" "$WEBHOOK_SERVER_DIR/projects.yaml" || miss "$HOME/.config/webhook-server/projects.yaml"
  echo
} > "$DEST"

# Restrict perms before any other command can see it.
chmod 600 "$DEST"

echo
echo "=== summary ==="
ok "wrote ${DEST} ($(wc -c < "$DEST") bytes, mode 0600)"
note "verify locally:  less -S ${DEST}"
note "restore fresh:   bash scripts/restore-secrets.sh ${DEST}"
