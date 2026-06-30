#!/usr/bin/env bash
# scripts/restore-secrets.sh — restore host secrets from a secrets.yaml
# backup file (e.g., ~/.secrets/secrets.yaml produced by backup-secrets.sh).
#
# Usage:
#   bash scripts/restore-secrets.sh                            # restore from ~/.secrets/secrets.yaml
#   bash scripts/restore-secrets.sh /path/to/secrets.yaml      # restore from a specific file
#   bash scripts/restore-secrets.sh --dry-run                  # show what would be done, do nothing
#   bash scripts/restore-secrets.sh --include <kind>           # only restore specific kinds
#
# --include values (comma-separated, default = all):
#   ssh          SSH keypair
#   github       gh CLI hosts.yml + GITHUB_TOKEN env
#   oauth2       oauth2-proxy client/cookie secrets
#   hermes       full ~/.hermes/.env
#   goose        ~/.config/goose/secrets.yaml
#   letsencrypt  ACME account key + privkey
#   mercury-tasks   /home/ubuntu/.config/mercury-tasks/tokens.json
#   x-digest     ~/data/code/x-digest/.env
#   openchamber  /home/ubuntu/.config/openchamber/startup.env
#   opencode    ~/.local/share/opencode/auth.json
#   discord-notify  ~/.config/discord-notify/config.yaml
#   gogcli      ~/.config/gogcli/credentials.json + keyring/  (keyring as tar.gz)
#   webhook-server  ~/.config/webhook-server/secret.txt + projects.yaml
#
# This script is the inverse of backup-secrets.sh. It writes files with
# the same modes the originals had on the source host (0600 for secrets,
# 0644 for public keys). It will NOT start or restart any service — that
# is the job of a separate step (e.g., `systemctl --user restart`).
#
# Restore on a fresh host:
#   1. clone mercury-host
#   2. transfer secrets.yaml (out-of-band: scp, USB, NEVER committed)
#   3. bash scripts/restore-secrets.sh /path/to/secrets.yaml
#   4. verify:  bash scripts/restore-secrets.sh --dry-run
#   5. restart services:  systemctl --user restart hermes-gateway mercury-tasks ...

set -euo pipefail

SRC="${HOME}/.secrets/secrets.yaml"
DRY_RUN=0
INCLUDE_KINDS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --include) INCLUDE_KINDS="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,40p' "$0"; exit 0 ;;
    *)
      if [ -f "$1" ]; then
        SRC="$1"; shift
      else
        echo "ERROR: $1 is not a file" >&2; exit 1
      fi
      ;;
  esac
done

if [ ! -f "$SRC" ]; then
  echo "ERROR: secrets file not found: $SRC" >&2
  echo "       Pass it as the first argument, or run backup-secrets.sh first." >&2
  exit 1
fi

# Restrict perms on read file defensively (the file should already be 0600
# but if you scp'd it from elsewhere it might be 0644).
chmod 600 "$SRC" 2>/dev/null || true

note() { printf '  %s\n' "$*" >&2; }
ok()   { printf '✓ %s\n' "$*" >&2; }
warn() { printf '⚠ %s\n' "$*" >&2; }

# Test whether a kind is in --include. Empty INCLUDE_KINDS = all.
in_include() {
  local kind="$1"
  if [ -z "$INCLUDE_KINDS" ]; then return 0; fi
  case ",$INCLUDE_KINDS," in
 *",$kind,"*) return 0 ;;
 *) return 1 ;;
  esac
}

# Decode a base64 YAML literal block scalar, write it to DEST with mode MODE.
# Uses python because base64 from a YAML literal block has internal newlines.
decode_b64_block() {
  local key="$1" dest="$2" mode="$3"
  python3 - "$SRC" "$key" "$dest" "$mode" <<'PYEOF'
import base64, os, pathlib, sys
src, key, dest, mode = sys.argv[1:5]
mode = int(mode, 8)
text = pathlib.Path(src).read_text()
# Find the block under `key: |` (or `key: >`). Collect indented lines.
lines = text.splitlines()
out = []
in_block = False
for i, line in enumerate(lines):
    if not in_block:
        if line.startswith(key + ':') and (line[len(key)+1:].strip() in ('|', '|-', '>')):
            in_block = True
        continue
    # In the block. Line either empty, indented (>= 1 space), or a new top-level key.
    # In the block. Line either empty, indented (>= 1 space), or a new top-level key.
    if not line:
        out.append('')
    elif line.startswith(' ') or line.startswith('\t'):
        out.append(line)
    else:
        break  # next top-level key
# Strip the common indent (we used 6 spaces, but be defensive).
body = '\n'.join(out)
# Find the minimum indent among non-blank lines
non_blank = [l for l in out if l]
min_indent = min(len(l) - len(l.lstrip()) for l in non_blank) if non_blank else 0
# Drop blank lines entirely (base64 doesn't need them); strip the indent.
stripped = ''.join(l[min_indent:] for l in out if l)
try:
    decoded = base64.b64decode(stripped, validate=True)
except Exception as e:
    print(f"  ! decode failed for {key}: {e}", file=sys.stderr)
    sys.exit(1)
# Atomically write: write to temp, then move
tmp = dest + '.tmp'
pathlib.Path(tmp).write_bytes(decoded)
os.chmod(tmp, mode)
os.replace(tmp, dest)
print(f"  ✓ wrote {dest} ({len(decoded)} bytes, mode {oct(mode)})", file=sys.stderr)
PYEOF
}

# Decode a b64 block, gunzip, untar into a target directory.
# Used for the gogcli keyring (3 encrypted blobs packed as tar.gz).
#
# Usage: extract_tar_gz_b64_block "key" "/target/dir"   →  untars into dir
# Returns 0 on success, 1 if the block is null or extraction fails.
extract_tar_gz_b64_block() {
  local key="$1" target_dir="$2"
  python3 - "$SRC" "$key" "$target_dir" <<'PYEOF'
import base64, gzip, io, os, pathlib, shutil, sys, tarfile
src, key, target_dir = sys.argv[1:4]
text = pathlib.Path(src).read_text()
lines = text.splitlines()
out, in_block = [], False
for line in lines:
    if not in_block:
        if line.startswith(key + ':') and (line[len(key)+1:].strip() in ('|', '|-', '>')):
            in_block = True
        continue
    if not line:
        out.append('')
    elif line.startswith(' ') or line.startswith('\t'):
        out.append(line)
    else:
        break
non_blank = [l for l in out if l]
if not non_blank:
    print(f"  ! {key}: not found or null in {src}", file=sys.stderr)
    sys.exit(1)
min_indent = min(len(l) - len(l.lstrip()) for l in non_blank)
stripped = ''.join(l[min_indent:] for l in out if l)
try:
    decoded = base64.b64decode(stripped, validate=True)
except Exception as e:
    print(f"  ! b64 decode failed for {key}: {e}", file=sys.stderr)
    sys.exit(1)
# Gunzip + untar. Replace the target dir contents to keep the restore idempotent.
if os.path.isdir(target_dir):
    shutil.rmtree(target_dir)
os.makedirs(target_dir, exist_ok=True)
tar_bytes = gzip.decompress(decoded)
tar = tarfile.open(fileobj=io.BytesIO(tar_bytes), mode='r')
tar.extractall(path=os.path.dirname(target_dir))
# Restore perms on extracted files (tar preserves them but be defensive)
for root, _, files in os.walk(target_dir):
    for f in files:
        p = os.path.join(root, f)
        os.chmod(p, 0o600)
print(f"  ✓ extracted {target_dir} (from {len(decoded)}-byte b64 block)", file=sys.stderr)
PYEOF
}

# Decode a scalar string field, write to DEST (or echo if dest is "-").
decode_scalar() {
  local key="$1" dest="$2"
  python3 - "$SRC" "$key" "$dest" <<'PYEOF'
import pathlib, sys
src, key, dest = sys.argv[1:4]
text = pathlib.Path(src).read_text()
# Find the line `key: "value"` and extract the value.
import re
m = re.search(rf'^{re.escape(key)}:\s*"(.*)"\s*$', text, re.MULTILINE)
if not m:
    print(f"  ! {key}: not found in {src}", file=sys.stderr)
    sys.exit(1)
val = m.group(1)
# Unescape backslash + double-quote
val = val.replace('\\\\', '\x00').replace('\\"', '"').replace('\x00', '\\')
if dest == '-':
    print(val)
else:
    pathlib.Path(dest).write_text(val)
    print(f"  ✓ wrote {dest} (mode will be set by caller)", file=sys.stderr)
PYEOF
}

echo "=== mercury-host secrets restore — $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo
echo "Source:      $SRC"
echo "Mode:        $([ $DRY_RUN -eq 1 ] && echo 'dry-run' || echo 'live')"
[ -n "$INCLUDE_KINDS" ] && echo "Scope:       $INCLUDE_KINDS" || echo "Scope:       all"
echo

if [ $DRY_RUN -eq 1 ]; then
  note "DRY RUN — no files will be written."
  note "Below are the target paths each kind would write to."
  echo
  if in_include ssh; then
    echo "  ssh:        ~/.ssh/id_ed25519        (mode 0600)"
    echo "              ~/.ssh/id_ed25519.pub    (mode 0644)"
  fi
  if in_include github; then
    echo "  github:     ~/.config/gh/hosts.yml    (mode 0600)"
    echo "              GITHUB_TOKEN extracted from gh_token_env (printed to stdout)"
  fi
  if in_include oauth2; then
    echo "  oauth2:     PATCH ~/.config/oauth2-proxy/oauth2-proxy.cfg"
    echo "              client_secret + cookie_secret lines"
  fi
  if in_include hermes; then
    echo "  hermes:     ~/.hermes/.env            (mode 0600)"
  fi
  if in_include goose; then
    echo "  goose:      ~/.config/goose/secrets.yaml  (mode 0600)"
  fi
  if in_include letsencrypt; then
    echo "  letsencrypt: /etc/letsencrypt/live/mercury.garden/privkey.pem + account_key.json"
  fi
  if in_include mercury-tasks; then
    echo "  mercury-tasks: /home/ubuntu/.config/mercury-tasks/tokens.json (mode 0600)"
  fi
  if in_include x-digest; then
    echo "  x-digest:   ~/data/code/x-digest/.env  (mode 0600)"
  fi
  if in_include openchamber; then
    echo "  openchamber: /home/ubuntu/.config/openchamber/startup.env  (mode 0600)"
  fi
  if in_include opencode; then
    echo "  opencode:   ~/.local/share/opencode/auth.json  (mode 0600)"
  fi
  if in_include discord-notify; then
    echo "  discord-notify: ~/.config/discord-notify/config.yaml  (mode 0600)"
  fi
  if in_include gogcli; then
    echo "  gogcli:     ~/.config/gogcli/credentials.json  (mode 0600)"
    echo "              ~/.config/gogcli/keyring/          (3 encrypted blobs, tar.gz)"
  fi
  if in_include webhook-server; then
    echo "  webhook-server: ~/.config/webhook-server/secret.txt  (mode 0600)"
    echo "                  ~/.config/webhook-server/projects.yaml  (mode 0600)"
  fi
  echo
  exit 0
fi

# ── SSH ─────────────────────────────────────────────────────────────────
if in_include ssh; then
  note "restoring SSH keypair..."
  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"
  if decode_b64_block "ssh_ed25519_private" "${HOME}/.ssh/id_ed25519" 0600; then
    ok "ssh_ed25519_private"
  else
    warn "ssh_ed25519_private: SKIPPED (null in source)"
  fi
  if decode_b64_block "ssh_ed25519_public" "${HOME}/.ssh/id_ed25519.pub" 0644; then
    ok "ssh_ed25519_public"
  else
    warn "ssh_ed25519_public: SKIPPED (null in source)"
  fi
fi

# ── GitHub ───────────────────────────────────────────────────────────────
if in_include github; then
  note "restoring GitHub config..."
  mkdir -p "${HOME}/.config/gh"
  chmod 700 "${HOME}/.config/gh"
  if decode_b64_block "gh_hosts_yml" "${HOME}/.config/gh/hosts.yml" 0600; then
    ok "gh_hosts_yml"
  else
    warn "gh_hosts_yml: SKIPPED (null in source)"
  fi
  # GITHUB_TOKEN is in hermes_env; the hermes step below restores it.
  # If you want it standalone, extract here:
  if grep -q '^gh_token_env: "' "$SRC"; then
    TOKEN=$(python3 -c "
import re, pathlib
text = pathlib.Path('$SRC').read_text()
m = re.search(r'^gh_token_env:\s*\"(.*)\"\s*\$', text, re.MULTILINE)
if m: print(m.group(1).replace('\\\\\\\\', '\x00').replace('\\\\\"', '\"').replace('\x00', '\\\\'))
")
    if [ -n "$TOKEN" ]; then
      # Append to ~/.hermes/.env if not already present
      if [ -f "${HOME}/.hermes/.env" ] && ! grep -q '^GITHUB_TOKEN=' "${HOME}/.hermes/.env"; then
        echo "GITHUB_TOKEN=$TOKEN" >> "${HOME}/.hermes/.env"
        ok "GITHUB_TOKEN appended to ~/.hermes/.env"
      elif [ ! -f "${HOME}/.hermes/.env" ]; then
        warn "\$HOME/.hermes/.env does not exist; will be created by 'hermes' restore below"
      else
        ok "GITHUB_TOKEN already present in ~/.hermes/.env (not modifying)"
      fi
    fi
  fi
fi

# ── oauth2-proxy ────────────────────────────────────────────────────────
# Patch the existing cfg file (don't replace it) — only update the two secret values.
if in_include oauth2; then
  note "patching oauth2-proxy config..."
  OAUTH2_CFG="${HOME}/.config/oauth2-proxy/oauth2-proxy.cfg"
  if [ ! -f "$OAUTH2_CFG" ]; then
    warn "$OAUTH2_CFG does not exist — skipping oauth2 (template in tooling/oauth2-proxy/oauth2-proxy.cfg.example must be copied first)"
  else
    chmod 600 "$OAUTH2_CFG"
    python3 - "$SRC" "$OAUTH2_CFG" <<'PYEOF'
import os, pathlib, re, sys
src, cfg = sys.argv[1], sys.argv[2]
text = pathlib.Path(src).read_text()
def get_scalar(key):
    m = re.search(rf'^{re.escape(key)}:\s*"(.*)"\s*$', text, re.MULTILINE)
    if not m: return None
    return m.group(1).replace('\\\\', '\x00').replace('\\"', '"').replace('\x00', '\\')
client = get_scalar('oauth2_client_secret')
cookie = get_scalar('oauth2_cookie_secret')
cfg_text = pathlib.Path(cfg).read_text()
if client:
    cfg_text = re.sub(r'^(client_secret\s*=\s*)"[^"]*"', rf'\1"{client}"', cfg_text, count=1, flags=re.MULTILINE)
    print(f"  ✓ patched client_secret in {cfg}", file=sys.stderr)
if cookie:
    cfg_text = re.sub(r'^(cookie_secret\s*=\s*)"[^"]*"', rf'\1"{cookie}"', cfg_text, count=1, flags=re.MULTILINE)
    print(f"  ✓ patched cookie_secret in {cfg}", file=sys.stderr)
pathlib.Path(cfg).write_text(cfg_text)
os.chmod(cfg, 0o600)
PYEOF
    ok "oauth2-proxy.cfg patched"
  fi
fi

# ── Hermes ──────────────────────────────────────────────────────────────
if in_include hermes; then
  note "restoring hermes env..."
  mkdir -p "${HOME}/.hermes"
  if decode_b64_block "hermes_env" "${HOME}/.hermes/.env" 0600; then
    ok "hermes_env"
  else
    warn "hermes_env: SKIPPED (null in source)"
  fi
fi

# ── Goose ───────────────────────────────────────────────────────────────
if in_include goose; then
  note "restoring goose secrets..."
  mkdir -p "${HOME}/.config/goose"
  if decode_b64_block "goose_secrets" "${HOME}/.config/goose/secrets.yaml" 0600; then
    ok "goose_secrets"
  else
    warn "goose_secrets: SKIPPED (null in source)"
  fi
fi

# ── Letsencrypt ─────────────────────────────────────────────────────────
# This requires sudo because /etc/letsencrypt is root-owned.
if in_include letsencrypt; then
  note "restoring letsencrypt keys (requires sudo)..."
  if ! command -v sudo >/dev/null 2>&1; then
    warn "sudo not available; skipping letsencrypt (run as root, or scp the files manually)"
  else
    PRIVKEY_PATH=$(python3 -c "
import re, pathlib
text = pathlib.Path('$SRC').read_text()
m = re.search(r'^letsencrypt_privkey_path:\s*\"(.*)\"\s*\$', text, re.MULTILINE)
print(m.group(1) if m else '/etc/letsencrypt/live/mercury.garden/privkey.pem')
")
    ACCT_PATH=$(python3 -c "
import re, pathlib
text = pathlib.Path('$SRC').read_text()
m = re.search(r'^letsencrypt_account_key_path:\s*\"(.*)\"\s*\$', text, re.MULTILINE)
print(m.group(1) if m else '')
")
    if [ -n "$PRIVKEY_PATH" ]; then
      sudo mkdir -p "$(dirname "$PRIVKEY_PATH")" 2>/dev/null || true
      # Decode to a temp file under our control, then sudo cp
      TMP_PRIVKEY=$(mktemp)
      if decode_b64_block "letsencrypt_privkey" "$TMP_PRIVKEY" 0600 2>/dev/null; then
        sudo cp "$TMP_PRIVKEY" "$PRIVKEY_PATH"
        sudo chmod 600 "$PRIVKEY_PATH"
        rm -f "$TMP_PRIVKEY"
        ok "letsencrypt privkey → $PRIVKEY_PATH"
      else
        warn "letsencrypt privkey: SKIPPED (null in source)"
        rm -f "$TMP_PRIVKEY"
      fi
    fi
    if [ -n "$ACCT_PATH" ]; then
      sudo mkdir -p "$(dirname "$ACCT_PATH")" 2>/dev/null || true
      TMP_ACCT=$(mktemp)
      if decode_b64_block "letsencrypt_account_key" "$TMP_ACCT" 0600 2>/dev/null; then
        sudo cp "$TMP_ACCT" "$ACCT_PATH"
        sudo chmod 600 "$ACCT_PATH"
        rm -f "$TMP_ACCT"
        ok "letsencrypt account_key → $ACCT_PATH"
      else
        warn "letsencrypt account_key: SKIPPED (null in source)"
        rm -f "$TMP_ACCT"
      fi
    fi
  fi
fi

# ── mercury-tasks ───────────────────────────────────────────────────────
if in_include mercury-tasks; then
  note "restoring mercury-tasks tokens..."
  MT_DIR="${HOME}/.config/mercury-tasks"
  mkdir -p "$MT_DIR"
  if decode_b64_block "mercury_tasks_tokens" "$MT_DIR/tokens.json" 0600; then
    ok "mercury_tasks_tokens"
  else
    warn "mercury_tasks_tokens: SKIPPED (null in source)"
  fi
fi

# ── x-digest ────────────────────────────────────────────────────────────
if in_include x-digest; then
  note "restoring x-digest env..."
  XD_DIR="${HOME}/data/code/x-digest"
  if [ ! -d "$XD_DIR" ]; then
    warn "$XD_DIR does not exist (clone the repo first) — skipping"
  else
    if decode_b64_block "x_digest_env" "$XD_DIR/.env" 0600; then
      ok "x_digest_env"
    else
      warn "x_digest_env: SKIPPED (null in source)"
    fi
  fi
fi

# ── openchamber ─────────────────────────────────────────────────────────
if in_include openchamber; then
  note "restoring openchamber env..."
  OC_DIR="${HOME}/.config/openchamber"
  mkdir -p "$OC_DIR"
  if decode_b64_block "openchamber_startup_env" "$OC_DIR/startup.env" 0600; then
    ok "openchamber_startup_env"
  else
    warn "openchamber_startup_env: SKIPPED (null in source)"
  fi
fi

# ── opencode auth ───────────────────────────────────────────────────────
if in_include opencode; then
  note "restoring opencode auth..."
  OC_DIR="${HOME}/.local/share/opencode"
  mkdir -p "$OC_DIR"
  if decode_b64_block "opencode_auth" "$OC_DIR/auth.json" 0600; then
    ok "opencode_auth"
  else
    warn "opencode_auth: SKIPPED (null in source)"
  fi
fi

# ── discord-notify ──────────────────────────────────────────────────────
if in_include discord-notify; then
  note "restoring discord-notify config..."
  DN_DIR="${HOME}/.config/discord-notify"
  mkdir -p "$DN_DIR"
  if decode_b64_block "discord_notify_config" "$DN_DIR/config.yaml" 0600; then
    ok "discord_notify_config"
  else
    warn "discord_notify_config: SKIPPED (null in source)"
  fi
fi

# ── gogcli (credentials + encrypted keyring) ────────────────────────────
# Restoring the keyring requires GOG_KEYRING_PASSWORD (in hermes .env) to
# decrypt the 3 blobs. The password itself is in the hermes block above.
if in_include gogcli; then
  note "restoring gogcli credentials + keyring..."
  GOG_DIR="${HOME}/.config/gogcli"
  mkdir -p "$GOG_DIR"
  if decode_b64_block "gogcli_credentials" "$GOG_DIR/credentials.json" 0600; then
    ok "gogcli_credentials"
  else
    warn "gogcli_credentials: SKIPPED (null in source)"
  fi
  if extract_tar_gz_b64_block "gogcli_keyring_tar_gz" "$GOG_DIR/keyring" 2>/dev/null; then
    ok "gogcli_keyring"
  else
    warn "gogcli_keyring: SKIPPED (null in source or extraction failed)"
  fi
fi

# ── webhook-server ──────────────────────────────────────────────────────
if in_include webhook-server; then
  note "restoring webhook-server config..."
  WS_DIR="${HOME}/.config/webhook-server"
  mkdir -p "$WS_DIR"
  if decode_b64_block "webhook_server_secret" "$WS_DIR/secret.txt" 0600; then
    ok "webhook_server_secret"
  else
    warn "webhook_server_secret: SKIPPED (null in source)"
  fi
  if decode_b64_block "webhook_server_projects" "$WS_DIR/projects.yaml" 0600; then
    ok "webhook_server_projects"
  else
    warn "webhook_server_projects: SKIPPED (null in source)"
  fi
fi

echo
echo "=== summary ==="
ok "restore complete"
note "restart services to pick up new secrets:"
note "  sudo systemctl restart nginx"
note "  systemctl --user restart hermes-gateway mercury-tasks oauth2-proxy webhook-server openchamber"
note "  systemctl --user restart hermes-cron  # if you have cron-driven tasks"
