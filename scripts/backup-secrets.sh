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
#   x-digest-env                  ~/data/code/x-digest/.env        [alias, see code_env_* below]
#   scriptcaster-env              ~/data/code/scriptcaster/.env    [alias, see code_env_* below]
#   openchamber-startup-env       ~/.config/openchamber/startup.env
#   opencode-auth                 ~/.local/share/opencode/auth.json     (added 2026-06-30)
#   gogcli                        ~/.config/gogcli/credentials.json + keyring/  (added 2026-06-30)
#   openwiki                      ~/.openwiki/.env                       (added 2026-07-08)
#   openviking                    ~/.openviking/.minimax-key + ov.conf   (added 2026-07-19)
#
# Auto-discovered (added 2026-07-07):
#   code_env_<sanitized-path>     EVERY `.env*` file under ~/data/code/, except
#                                 `*.example` (templates, never have real secrets).
#                                 Sanitization: repo-relative path → replace `/` and `.`
#                                 with `_`, lowercase. Example:
#                                   ~/data/code/mercury-tasks/web/.env.production
#                                   → code_env_mercury-tasks_web_env_production
#                                 Discovered at backup time; adding a new project
#                                 needs no inventory edit and no script change.
#                                 Restore one with:
#                                   bash scripts/restore-secrets.sh --env <path>
#                                 Restore all with:
#                                   bash scripts/restore-secrets.sh --include code-env
#                                 The legacy `x_digest_env` / `scriptcaster_env` keys
#                                 remain as ALIASES of the matching code_env_* blocks
#                                 for back-compat — old --include filters keep working.
#
# Removed 2026-07-05 (PR #28) — services were decommissioned in PR #24
# but their secrets.yaml blocks lingered; nothing reads these anymore:
#   discord-notify                ~/.config/discord-notify/config.yaml
#   webhook-server                ~/.config/webhook-server/secret.txt + projects.yaml
# (The on-disk .config dirs were deleted in the same PR. If a future
# fork needs the configs, the latest state tarball has the .config dir
# for cold-recovery.)
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

# ── Sanitize a filesystem path into a YAML key safe to round-trip.
# `~/data/code/mercury-tasks/web/.env.production` →
#   `code_env_mercury-tasks_web_env_production`
# Rules: lowercase, `/` → `_`, leading `.` → `_`, all other `.` → `_`.
# Strips a leading `~/data/code/` (or `$HOME/data/code/`) prefix; everything
# else is treated as repo-relative. Hyphens, digits, and underscores pass
# through. Non-alphanumeric chars other than `-` and `_` are dropped.
# Returns 0 on success, 1 if the input is empty or contains no usable chars.
sanitize_env_kind() {
  local abs_path="$1"
  local rel="${abs_path#"${HOME}"/data/code/}"
  if [ "$rel" = "$abs_path" ]; then
    # No $HOME/data/code/ prefix — fall back to basename only.
    rel="$(basename "$abs_path")"
  fi
  # Lowercase, replace `/` and `.` with `_`, drop everything not [a-z0-9_-].
  local kind
  kind="$(printf '%s' "$rel" | tr '[:upper:]' '[:lower:]' | tr '/.' '__')"
  kind="$(printf '%s' "$kind" | tr -cd 'a-z0-9_-')"
  if [ -z "$kind" ]; then
    return 1
  fi
  printf 'code_env_%s\n' "$kind"
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
# Per-project .env files. These live under ~/data/code/<repo>/.env (mode 0600)
# and are NOT in the daily BACKUP_PATHS list (those are dotfile roots, not
# per-project) — they MUST be captured here so a dropped .env is recoverable
# in <1 min via `bash scripts/restore-secrets.sh`. As of 2026-07-07 the list
# is auto-discovered: every `.env*` file under ~/data/code/ is captured as a
# `code_env_*` b64 block (excluding `*.example` templates). The two legacy
# keys below (`x_digest_env`, `scriptcaster_env`) remain as ALIASES of the
# corresponding auto-discovered blocks so old `--include` filters keep
# working. No more per-project edits required when a new repo is added.
SC_ENV="${HOME}/data/code/scriptcaster/.env"
OC_ENV="${HOME}/.config/openchamber/startup.env"
ACCT_KEY="$(find /etc/letsencrypt/accounts -name account_key.json 2>/dev/null | head -1 || true)"
PRIVKEY_LINK="/etc/letsencrypt/live/mercury.garden/privkey.pem"
PRIVKEY_REAL="$(readlink -f "$PRIVKEY_LINK" 2>/dev/null || echo "$PRIVKEY_LINK")"

# ── NEW kinds (added 2026-06-30 after opencode auth.json was identified as
#    missing from the original 12-source list). Each one is a host-restorable
#    secret needed to fully recreate the operational state.
OPENCODE_AUTH="${HOME}/.local/share/opencode/auth.json"
GOGCLI_CREDENTIALS="${HOME}/.config/gogcli/credentials.json"
GOGCLI_KEYRING_DIR="${HOME}/.config/gogcli/keyring"

# OpenWiki (LangChain repo-documentation agent) — created on first `openwiki --init`.
# Holds the API key + provider/base_url/model pins. RECOVERABLE (regenerates on
# next --init) but worth a backup so a host restore doesn't need a coding-plan
# portal round-trip. `~/.openwiki/openwiki.sqlite` (the session/index cache) is
# NOT backed up — it rebuilds on the next openwiki run and is ~130MB.
OPENWIKI_ENV="${HOME}/.openwiki/.env"

# OpenViking (agent context database, added 2026-07-19). The MiniMax API key
# is referenced as both a standalone key file (EnvironmentFile= source for
# the systemd unit) AND inline in ov.conf (which OpenViking's config schema
# requires — see secrets/inventory.yaml). Back up both for full restore.
OPENVKING_MINIMAX_KEY="${HOME}/.openviking/.minimax-key"
OPENVKING_OV_CONF="${HOME}/.openviking/ov.conf"

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
  # ── x-digest ────────────────────────────────────────────────────────────
  # Back-compat alias for the auto-discovered code_env_x-digest_env block.
  # New keys go into code_env_* (see the auto-discovered section below);
  # this alias is preserved so legacy `--include x-digest` filters still work.
  emit_b64_block "x_digest_env" "$XD_ENV" || miss "x-digest .env"
  echo
  # ── scriptcaster ────────────────────────────────────────────────────────
  # Back-compat alias for the auto-discovered code_env_scriptcaster_env block.
  # ElevenLabs / Fish Audio / Cartesia / HuggingFace / Langfuse / MiniMax keys.
  emit_b64_block "scriptcaster_env" "$SC_ENV" || miss "scriptcaster .env"
  echo
  # ── Auto-discovered ~/data/code/**/*.env ────────────────────────────────
  # Every `.env*` file under ~/data/code/ is captured as a `code_env_*` b64
  # block, excluding `*.example` (templates never have real secrets). The
  # path → key mapping is computed by sanitize_env_kind() above. Files
  # already captured as x_digest_env / scriptcaster_env aliases get a
  # re-emission as code_env_* so the new format is authoritative; the
  # aliases above remain for back-compat. Files with mode != 0600 are
  # captured (we don't refuse — mode is enforced on restore) but the miss
  # note records the actual mode so the user sees it in the backup log.
  # Override the discovery root with BACKUP_CODE_ROOT for testing.
  CODE_ROOT="${BACKUP_CODE_ROOT:-${HOME}/data/code}"
  echo "# ── Auto-discovered .env* under ~/data/code (excludes *.example) ──"
  if [ -d "$CODE_ROOT" ]; then
    # -print0 + mapfile handles paths with spaces/special chars safely.
    mapfile -d '' -t CODE_ENV_FILES < <(
      find "$CODE_ROOT" \
        -type f \
        -name '.env*' \
        ! -name '*.example' \
        ! -name '*.sample' \
        -print0 2>/dev/null \
        | sort -z
    )
    if [ "${#CODE_ENV_FILES[@]}" -eq 0 ]; then
      note "no .env* files found under $CODE_ROOT"
    else
      for env_file in "${CODE_ENV_FILES[@]}"; do
        [ -n "$env_file" ] || continue
        KIND="$(sanitize_env_kind "$env_file")" || {
          miss "sanitize failed for $env_file"
          continue
        }
        if emit_b64_block "$KIND" "$env_file"; then
          mode=$(stat -c '%a' "$env_file" 2>/dev/null || echo '?')
          # Emit a stable source-path marker on the line immediately after the
          # b64 block. restore-secrets.sh uses this marker (one per block,
          # exact key name → path) to map YAML keys back to on-disk paths
          # without depending on cosmetic section-header text. Format:
          #   # code_env_foo_env source: /home/ubuntu/data/code/foo/.env
          printf '# %s source: %s\n' "$KIND" "$env_file"
          if [ "$mode" = "600" ]; then
            ok "$KIND ($env_file, mode 0600)"
          else
            note "$KIND ($env_file, mode $mode — restore will normalize to 0600)"
          fi
        else
          miss "$KIND ($env_file)"
        fi
      done
    fi
  else
    note "$CODE_ROOT not present; skipping auto-discovery"
  fi
  echo
  echo "# ── openchamber ─────────────────────────────────────────────────"
  emit_b64_block "openchamber_startup_env" "$OC_ENV" || miss "openchamber startup.env"
  echo
  echo "# ── opencode auth (provider API keys) ───────────────────────────"
  emit_b64_block "opencode_auth" "$OPENCODE_AUTH" || miss "$HOME/.local/share/opencode/auth.json"
  echo
  echo "# ── gogcli (Gmail OAuth client creds + encrypted keyring) ───────"
  emit_b64_block "gogcli_credentials" "$GOGCLI_CREDENTIALS" || miss "$HOME/.config/gogcli/credentials.json"
  # The keyring is a directory of 3 encrypted blobs; pack as tar.gz + b64.
  # Restoring requires GOG_KEYRING_PASSWORD from hermes .env to decrypt.
  pack_dir_b64_block "gogcli_keyring_tar_gz" "$GOGCLI_KEYRING_DIR" || miss "$HOME/.config/gogcli/keyring"
  echo
  echo "# ── openwiki (langchain repo-documentation agent) ──────────────"
  # MiniMax coding-plan key + provider/base_url/model pins. Written by
  # `openwiki --init`. Restoring with --include openwiki makes the next
  # `cd <repo> && openwiki --update` run without re-init.
  emit_b64_block "openwiki_env" "$OPENWIKI_ENV" || miss "$HOME/.openwiki/.env"
  echo
  # ── openviking (agent context database — added 2026-07-19) ────────
  # Captures both the standalone key file and ov.conf (which contains the
  # same key inline because OpenViking's config schema does not support
  # env-var substitution in api_key fields). Both files are mode 0600.
  emit_b64_block "openviking_minimax_api_key" "$OPENVKING_MINIMAX_KEY" || miss "$HOME/.openviking/.minimax-key"
  emit_b64_block "openviking_ov_conf" "$OPENVKING_OV_CONF" || miss "$HOME/.openviking/ov.conf"
  echo
  # ── Varlock pass store + GPG private key (added 2026-07-20, Stage 3) ──
  # The pass store at ~/.password-store/ holds every `mercury/<repo>/<KEY>`
  # entry consumed by `varlock load` / `varlock run` during project startup.
  # The GPG private key for the identity that encrypts the store lives in
  # ~/.gnupg/private-keys-v1.d/<keygrip>.key as a mode-600 binary file — but
  # on this GnuPG version (2.4.4) those .key files are written LAZILY by
  # the agent on first private-key access, NOT by keygen itself. The
  # durable copy of the private key is therefore the armored export block
  # below (single file, ~3-5 KB, byte-deterministic from the key). The
  # tar.gz of private-keys-v1.d/ is an opportunistic second-layer capture
  # that works only if the .key files have been materialized (via any
  # prior gpg-agent operation); restore handles both, preferring the
  # armored import if present.
  #
  # Restore (single include kind covers all three blocks):
  #   bash scripts/restore-secrets.sh --include varlock-pass
  VARLOCK_PASS_DIR="${HOME}/.password-store"
  VARLOCK_GPG_KEYS_DIR="${HOME}/.gnupg/private-keys-v1.d"
  VARLOCK_GPG_FP=$(timeout 10 gpg --list-secret-keys --with-colons 2>/dev/null \
    | awk -F: '/^fpr:/{print $10; exit}')
  echo "# ── Varlock: encrypted pass store + GPG private key ────────────"
  pack_dir_b64_block "varlock_pass_store_tar_gz" "$VARLOCK_PASS_DIR" \
    || miss "$VARLOCK_PASS_DIR (Stage 2 not yet run? — see AGENTS.md 'Varlock' quirk)"
  pack_dir_b64_block "varlock_gpg_private_tar_gz" "$VARLOCK_GPG_KEYS_DIR" \
    || miss "$VARLOCK_GPG_KEYS_DIR (no .key files materialized — use armored export below)"
  # Durable copy: armored private key (single file, deterministic name).
  # Always emitted if there is a GPG identity on the host.
  if [ -n "$VARLOCK_GPG_FP" ]; then
    # Generate the armored export to a tempfile with mode 0600, then
    # base64 it. The tempfile is shredded immediately after capture.
    _varlock_armored_tmp=$(mktemp -t varlock-gpg-armored-XXXXXX.asc)
    chmod 600 "$_varlock_armored_tmp"
    gpg --export-secret-keys --armor "$VARLOCK_GPG_FP" > "$_varlock_armored_tmp" 2>/dev/null || {
      rm -f "$_varlock_armored_tmp"
      miss "varlock_gpg_armored_private (gpg export failed)"
    }
    if [ -f "$_varlock_armored_tmp" ]; then
      emit_b64_block "varlock_gpg_armored_private" "$_varlock_armored_tmp" \
        || miss "varlock_gpg_armored_private"
      shred -u "$_varlock_armored_tmp"
    fi
  else
    miss "varlock_gpg_armored_private (no GPG identity on host — Stage 2 not run)"
  fi
  echo
  # discord-notify + webhook-server removed 2026-07-05 (PR #28). The systemd
  # units and projects were decommissioned in PR #24 but their config dirs
  # + secrets.yaml capture remained; nothing reads them anymore. If a future
  # fork needs the configs, the latest state tarball still has the .config
  # directory for cold-recovery.
} > "$DEST"

# Restrict perms before any other command can see it.
chmod 600 "$DEST"

echo
echo "=== summary ==="
ok "wrote ${DEST} ($(wc -c < "$DEST") bytes, mode 0600)"
note "verify locally:  less -S ${DEST}"
note "restore fresh:   bash scripts/restore-secrets.sh ${DEST}"
