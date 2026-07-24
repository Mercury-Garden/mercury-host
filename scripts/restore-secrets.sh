#!/usr/bin/env bash
# scripts/restore-secrets.sh — restore host secrets from a secrets.yaml
# backup file (e.g., ~/.secrets/secrets.yaml produced by backup-secrets.sh).
#
# Usage:
#   bash scripts/restore-secrets.sh                            # restore from ~/.secrets/secrets.yaml
#   bash scripts/restore-secrets.sh /path/to/secrets.yaml      # restore from a specific file
#   bash scripts/restore-secrets.sh --dry-run                  # show what would be done, do nothing
#   bash scripts/restore-secrets.sh --include <kind>           # only restore specific kinds
#   bash scripts/restore-secrets.sh --env <path-or-kind>       # restore ONE .env under ~/data/code/ and exit
#                                                              # Accepts: bare repo-relative path (e.g.
#                                                              #   x-digest/.env), absolute path
#                                                              #   (/home/ubuntu/data/code/x-digest/.env),
#                                                              #   or sanitized kind (code_env_x-digest_env).
#                                                              # Refuses to overwrite a non-empty target
#                                                              # unless --force is also passed.
#
# --include values (comma-separated, default = all):
#   ssh          SSH keypair
#   github       gh CLI hosts.yml + GITHUB_TOKEN env
#   oauth2       oauth2-proxy client/cookie secrets
#   hermes       full ~/.hermes/.env (default profile)
#   hermes-profile-<name>   full ~/.hermes/profiles/<name>/.env (per-profile)
#   goose        ~/.config/goose/secrets.yaml
#   letsencrypt  ACME account key + privkey
#   mercury-tasks   /home/ubuntu/.config/mercury-tasks/tokens.json
#   x-digest     ~/data/code/x-digest/.env       [alias for code_env_x-digest_env]
#   scriptcaster ~/data/code/scriptcaster/.env   [alias for code_env_scriptcaster_env]
#   code-env     ALL auto-discovered .env* files under ~/data/code/ (excludes *.example)
#   openchamber  ~/.config/openchamber/startup.env
#   opencode    ~/.local/share/opencode/auth.json
#   gogcli      ~/.config/gogcli/credentials.json + keyring/  (keyring as tar.gz)
#   openwiki    ~/.openwiki/.env                                (MiniMax coding-plan key for openwiki)
#   openviking  ~/.openviking/ov.conf + OPENROUTER_API_KEY in ~/.hermes/.env (live provider)
#               Also restores legacy ~/.openviking/.minimax-key if present in the backup
#               (kept for 7-day rollback window after the 2026-07-24 OpenRouter migration).
#   varlock-pass  ~/.password-store/ (encrypted pass tree) + ~/.gnupg/private-keys-v1.d/ (GPG private key).
#                Single include kind covers both — both dirs are needed for
#                the encrypted store to be usable after a restore.
#                Existing files are preserved (merge-restore, not clobber).
#
# Removed 2026-07-05 (PR #28) — services were decommissioned in PR #24
# but restore logic lingered. If a future fork needs the configs, the
# latest state tarball has the .config dir for cold-recovery:
#   discord-notify  ~/.config/discord-notify/config.yaml
#   webhook-server  ~/.config/webhook-server/secret.txt + projects.yaml
#
# Per-profile note: `hermes-profile-<name>` kinds are NOT enumerated
# statically — restore-secrets.sh scans the source YAML for any
# `hermes_profile_<name>_env` block and registers a matching include kind
# automatically. Add a profile → run a new backup → restore picks it up
# without any code change here. The same applies to the
# `gh_token_env_profile_<name>` scalars, which are restored alongside
# their owning profile.
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
ENV_TARGET=""
FORCE_OVERWRITE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --include) INCLUDE_KINDS="$2"; shift 2 ;;
    --env) ENV_TARGET="$2"; shift 2 ;;
    --force) FORCE_OVERWRITE=1; shift ;;
    -h|--help)
      sed -n '2,52p' "$0"; exit 0 ;;
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

# ── Sanitize an absolute filesystem path into the YAML key used by
# backup-secrets.sh. Mirrors backup-secrets.sh's sanitize_env_kind():
# strips the $HOME/data/code/ prefix, lowercases, replaces `/` and `.`
# with `_`, drops everything not [a-z0-9_-], prepends `code_env_`.
sanitize_env_kind() {
  local abs_path="$1"
  local rel="${abs_path#"${HOME}"/data/code/}"
  if [ "$rel" = "$abs_path" ]; then
    rel="$(basename "$abs_path")"
  fi
  local kind
  kind="$(printf '%s' "$rel" | tr '[:upper:]' '[:lower:]' | tr '/.' '__')"
  kind="$(printf '%s' "$kind" | tr -cd 'a-z0-9_-')"
  if [ -z "$kind" ]; then
    return 1
  fi
  printf 'code_env_%s\n' "$kind"
}

# ── Resolve --env <arg> into "<yaml_key> <target_path>" on stdout.
# `--env` accepts any existing project-relative path; the examples use
# x-digest because it is an active host workload.
# Accepts any of:
#   1. Bare repo-relative path:        x-digest/.env
#   2. Absolute path:                  /home/ubuntu/data/code/x-digest/.env
#   3. Sanitized YAML kind:            code_env_x-digest_env
# Returns 0 on success, 1 if --env arg can't be matched to a source YAML
# block AND doesn't look like a path we can construct a target from.
# Strips `--env` arg quoting if present.
resolve_env_target() {
  local arg="$1"
  # Strip a leading "code_env_" if the user passed a kind — we re-derive
  # the target path from it by walking the YAML key list.
  local bare="${arg#code_env_}"
  # If the YAML file has a matching key, use it; otherwise we'll fall back
  # to constructing the target path from the bare name.
  local matched_path
  matched_path="$(python3 - "$SRC" "$bare" <<'PYEOF'
import re, sys
src, bare = sys.argv[1], sys.argv[2]
text = open(src).read()
# Find every `code_env_<x>: |` block and read the matching
# `# code_env_<x> source: <path>` marker on the line immediately after.
# This is a stable contract between backup-secrets.sh (emitter) and
# restore-secrets.sh (reader) — does not depend on section-header text.
blocks = re.findall(
    r'^(code_env_[A-Za-z0-9_-]+):\s*\|\s*\n'
    r'(?:\s+[^\n]*\n)*'
    r'(?:\s*# code_env_[A-Za-z0-9_-]+ source: (\S+)\s*\n)?',
    text, re.MULTILINE
)
for key, path in blocks:
    if key == 'code_env_' + bare and path:
        print(path)
        sys.exit(0)
PYEOF
)"
  if [ -n "$matched_path" ]; then
    printf 'code_env_%s %s\n' "$bare" "$matched_path"
    return 0
  fi
  # Fall back: treat `arg` as a path, derive both key and target from it.
  local target_path="$arg"
  # Allow bare repo-relative paths.
  if [ "${target_path:0:1}" != "/" ] && [ "${target_path#./}" = "$target_path" ]; then
    target_path="${HOME}/data/code/${target_path}"
  fi
  # Expand a leading ~ for the human-typed case.
  target_path="${target_path/#\~/$HOME}"
  if ! sanitize_env_kind "$target_path" >/dev/null 2>&1; then
    return 1
  fi
  local kind
  kind="$(sanitize_env_kind "$target_path")"
  # Final guard: the source YAML must contain this kind (otherwise we'd
  # silently write garbage from a non-existent block).
  if ! grep -q "^${kind}: |" "$SRC"; then
    echo "ERROR: --env '$arg' resolves to YAML key '$kind' but the source" >&2
    echo "       $SRC does not contain that block." >&2
    return 1
  fi
  printf '%s %s\n' "$kind" "$target_path"
}

# ── Restore a single auto-discovered code_env_* file. Used by both
# the --env <arg> path and the code-env include filter. Args: yaml_key, target_path.
# Honors DRY_RUN and FORCE_OVERWRITE globals.
restore_one_code_env() {
  local yaml_key="$1" target_path="$2"
  # Safety: refuse to clobber a non-empty target unless --force. This
  # protects against the case where the operator typos --env foo/.env
  # and the path happens to point at a working .env in some other repo.
  if [ -f "$target_path" ] && [ -s "$target_path" ] && [ "$FORCE_OVERWRITE" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    warn "refusing to overwrite non-empty $target_path (pass --force to override)"
    return 1
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    ok "(dry-run) would restore $yaml_key → $target_path (mode 0600)"
    return 0
  fi
  # Make sure the parent directory exists.
  mkdir -p "$(dirname "$target_path")"
  if decode_b64_block "$yaml_key" "$target_path" 0600; then
    ok "$yaml_key → $target_path (mode 0600)"
  else
    warn "$yaml_key: SKIPPED (null in source)"
    return 1
  fi
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

# Like extract_tar_gz_b64_block but PRESERVES existing target-dir contents.
# Used for the Varlock pass store + GPG private key restore: the operator
# may have a working store on the live host, and a re-restore from backup
# should merge into it without destroying any entries that exist on disk
# but not in the tar (e.g., newer entries added since the backup was made).
# Existing files are NOT overwritten; the tar's copy wins only where the
# file is missing locally.
#
# Usage: extract_tar_gz_b64_block_preserve "key" "/target/dir"   →  merges
extract_tar_gz_b64_block_preserve() {
  local key="$1" target_dir="$2"
  python3 - "$SRC" "$key" "$target_dir" <<'PYEOF'
import base64, errno, gzip, io, os, pathlib, sys, tarfile
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
os.makedirs(target_dir, exist_ok=True)
tar_bytes = gzip.decompress(decoded)
tar = tarfile.open(fileobj=io.BytesIO(tar_bytes), mode='r')
# Merge-untars: skip members whose target path already exists.
extracted = 0
skipped = 0
for member in tar.getmembers():
    # Strip the leading dir prefix from the tar (tar's first member is the
    # captured directory name, e.g., "password-store/"; we want its
    # contents directly under target_dir).
    member_name = member.name
    parts = member_name.split('/', 1)
    if len(parts) == 2:
        rel = parts[1]
    else:
        rel = ''
    target_path = os.path.join(target_dir, rel) if rel else target_dir
    if os.path.exists(target_path) and not os.path.isdir(target_path):
        skipped += 1
        continue
    if os.path.exists(target_path) and os.path.isdir(target_path) and member.isdir():
        skipped += 1
        continue
    if not rel:
        # The captured-dir entry itself — already exists at target_dir.
        skipped += 1
        continue
    # Use extract with a manual filter rather than extractall so we can
    # honour the "skip if exists" semantics. Member path needs to be
    # rewritten so it lands directly under target_dir.
    member.name = rel
    try:
        tar.extract(member, path=target_dir)
        extracted += 1
    except (OSError, KeyError) as e:
        # EEXIST means we raced with ourselves; safe to ignore.
        if getattr(e, 'errno', None) != errno.EEXIST:
            raise
print(f"  ✓ merged {extracted} file(s) into {target_dir} ({skipped} pre-existing file(s) preserved)", file=sys.stderr)
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

# ── --env <path-or-kind>: restore ONE auto-discovered .env and exit.
# Runs before the dry-run/main branches so it works regardless of --include.
# Placed AFTER all the decode helpers so it can call restore_one_code_env
# → decode_b64_block without a forward-reference problem (bash resolves
# function names at call time, not parse time, but only functions defined
# earlier in the same shell session are visible).
if [ -n "$ENV_TARGET" ]; then
  echo "=== mercury-host secrets restore — $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  echo
  echo "Source:    $SRC"
  echo "Mode:      single .env"
  echo "Target:    $ENV_TARGET"
  echo "Force:     $([ $FORCE_OVERWRITE -eq 1 ] && echo 'yes' || echo 'no')"
  echo
  if ! RESOLVED="$(resolve_env_target "$ENV_TARGET")"; then
    echo "ERROR: could not resolve --env '$ENV_TARGET' to a known code_env_* block" >&2
    echo "       Pass a bare repo-relative path (x-digest/.env), an absolute" >&2
    echo "       path, or a sanitized kind (code_env_x-digest_env)." >&2
    exit 2
  fi
  KIND="${RESOLVED%% *}"
  TARGET="${RESOLVED#* }"
  restore_one_code_env "$KIND" "$TARGET"
  exit $?
fi

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
  # Per-profile hermes envs (auto-discovered from the source YAML).
  DRY_PROFILE_KEYS=$(python3 - "$SRC" <<'PYEOF'
import re, sys
text = open(sys.argv[1]).read()
for m in re.finditer(r'^hermes_profile_([A-Za-z0-9_-]+)_env:\s*\|', text, re.MULTILINE):
    print(m.group(1))
PYEOF
)
  for PROF_NAME in $DRY_PROFILE_KEYS; do
    KIND="hermes-profile-${PROF_NAME}"
    if in_include "$KIND"; then
      echo "  ${KIND}:  ~/.hermes/profiles/${PROF_NAME}/.env  (mode 0600)"
    fi
  done
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
    echo "  x-digest:   ~/data/code/x-digest/.env  (mode 0600) [alias of code_env_x-digest_env]"
  fi
  if in_include scriptcaster; then
    echo "  scriptcaster: ~/data/code/scriptcaster/.env  (mode 0600) [alias of code_env_scriptcaster_env]"
  fi
  # Auto-discovered code_env_* blocks: list every one from the source YAML
  # that matches the include filter (--include code-env selects them all).
  if in_include code-env; then
    DRY_CODE_ENVS=$(python3 - "$SRC" <<'PYEOF'
import re, sys
text = open(sys.argv[1]).read()
# Find the auto-discovered section, then enumerate code_env_* blocks inside it.
blocks = re.findall(
    r'^(code_env_[A-Za-z0-9_-]+):\s*\|\s*\n'
    r'(?:\s+[^\n]*\n)*'
    r'(?:\s*# code_env_[A-Za-z0-9_-]+ source: (\S+)\s*\n)?',
    text, re.MULTILINE
)
for key, path in blocks:
    if path:
        print(f'{key}|{path}')
PYEOF
)
    if [ -n "$DRY_CODE_ENVS" ]; then
      while IFS='|' read -r kind path; do
        [ -n "$kind" ] || continue
        echo "  ${kind#code_env_}: $path  (mode 0600)"
      done <<< "$DRY_CODE_ENVS"
    fi
  fi
  if in_include openchamber; then
    echo "  openchamber: /home/ubuntu/.config/openchamber/startup.env  (mode 0600)"
  fi
  if in_include opencode; then
    echo "  opencode:   ~/.local/share/opencode/auth.json  (mode 0600)"
  fi
  if in_include gogcli; then
    echo "  gogcli:     ~/.config/gogcli/credentials.json  (mode 0600)"
    echo "              ~/.config/gogcli/keyring/          (3 encrypted blobs, tar.gz)"
  fi
  if in_include openwiki; then
    echo "  openwiki:   ~/.openwiki/.env  (mode 0600, MiniMax coding-plan API key)"
  fi
  if in_include openviking; then
    echo "  openviking: ~/.openviking/ov.conf                         (mode 0600, uses ${OPENROUTER_API_KEY})"
    echo "              OPENROUTER_API_KEY line in ~/.hermes/.env      (append or replace)"
    echo "              legacy ~/.openviking/.minimax-key (if present) (mode 0600, rollback)"
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

# ── Hermes (default profile) ────────────────────────────────────────────
if in_include hermes; then
  note "restoring hermes env (default profile)..."
  mkdir -p "${HOME}/.hermes"
  if decode_b64_block "hermes_env" "${HOME}/.hermes/.env" 0600; then
    ok "hermes_env"
  else
    warn "hermes_env: SKIPPED (null in source)"
  fi
fi

# ── Hermes (per-profile) ───────────────────────────────────────────────
# Discover all `hermes_profile_<name>_env` blocks in the source and
# register them as `hermes-profile-<name>` kinds (or auto-restore them
# when no --include filter is in effect). Profile names with hyphens
# (e.g. `mercury-butler`) become include kinds `hermes-profile-mercury-butler`.
# The matching `gh_token_env_profile_<name>` scalar, if present, is also
# written into the same per-profile .env (only if GITHUB_TOKEN is missing
# from the decoded file — never overwrites an existing token).
PROFILE_KEYS=$(python3 - "$SRC" <<'PYEOF'
import re, sys
text = open(sys.argv[1]).read()
for m in re.finditer(r'^hermes_profile_([A-Za-z0-9_-]+)_env:\s*\|', text, re.MULTILINE):
    print(m.group(1))
PYEOF
)
if [ -n "$PROFILE_KEYS" ]; then
  while IFS= read -r PROF_NAME; do
    [ -n "$PROF_NAME" ] || continue
    KIND="hermes-profile-${PROF_NAME}"
    if in_include "$KIND"; then
      note "restoring hermes profile: ${PROF_NAME}..."
      PROF_DIR="${HOME}/.hermes/profiles/${PROF_NAME}"
      mkdir -p "$PROF_DIR"
      B64_KEY="hermes_profile_${PROF_NAME}_env"
      if decode_b64_block "$B64_KEY" "${PROF_DIR}/.env" 0600; then
        ok "$B64_KEY"
        # If a gh_token_env_profile_<name> scalar exists AND the decoded
        # .env is missing GITHUB_TOKEN, append it. (Decoded .env takes
        # precedence; we never overwrite an in-file token.)
        SCALAR_KEY="gh_token_env_profile_${PROF_NAME}"
        if grep -q "^${SCALAR_KEY}: \"" "$SRC" && ! grep -q '^GITHUB_TOKEN=' "${PROF_DIR}/.env"; then
          TOKEN=$(python3 -c "
import re, pathlib
text = pathlib.Path('$SRC').read_text()
m = re.search(r'^${SCALAR_KEY}:\s*\"(.*)\"\s*\$', text, re.MULTILINE)
if m: print(m.group(1).replace('\\\\\\\\', '\x00').replace('\\\\\"', '\"').replace('\x00', '\\\\'))
")
          if [ -n "$TOKEN" ]; then
            echo "GITHUB_TOKEN=$TOKEN" >> "${PROF_DIR}/.env"
            ok "$SCALAR_KEY appended to ${PROF_DIR}/.env"
          fi
        fi
      else
        warn "$B64_KEY: SKIPPED (null in source)"
      fi
    fi
  done <<< "$PROFILE_KEYS"
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
# Back-compat alias for code_env_x-digest_env. The auto-discovered section
# below restores the same file under its code_env_* key. Either include
# works; restoring twice is a no-op (the second decode overwrites with the
# same bytes).
if in_include x-digest; then
  note "restoring x-digest env (alias)..."
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

# ── scriptcaster ────────────────────────────────────────────────────────
# Back-compat alias for code_env_scriptcaster_env. See x-digest note above.
if in_include scriptcaster; then
  note "restoring scriptcaster env (alias)..."
  SC_DIR="${HOME}/data/code/scriptcaster"
  if [ ! -d "$SC_DIR" ]; then
    warn "$SC_DIR does not exist (clone the repo first) — skipping"
  else
    if decode_b64_block "scriptcaster_env" "$SC_DIR/.env" 0600; then
      ok "scriptcaster_env"
    else
      warn "scriptcaster_env: SKIPPED (null in source)"
    fi
  fi
fi

# ── Auto-discovered code_env_* (.env* under ~/data/code/, excl *.example) ─
# Each block in the source YAML is mapped to its original on-disk path
# (parsed from the section comments) and restored individually. Refuses to
# overwrite a non-empty target unless --force.
if in_include code-env; then
  note "restoring auto-discovered code_env_* (.env* under ~/data/code/)..."
  CODE_ENV_KINDS=$(python3 - "$SRC" <<'PYEOF'
import re, sys
text = open(sys.argv[1]).read()
blocks = re.findall(
    r'^(code_env_[A-Za-z0-9_-]+):\s*\|\s*\n'
    r'(?:\s+[^\n]*\n)*'
    r'(?:\s*# code_env_[A-Za-z0-9_-]+ source: (\S+)\s*\n)?',
    text, re.MULTILINE
)
for key, path in blocks:
    if path:
        print(f'{key}|{path}')
PYEOF
)
  if [ -z "$CODE_ENV_KINDS" ]; then
    warn "no code_env_* blocks found in $SRC"
  else
    while IFS='|' read -r kind path; do
      [ -n "$kind" ] || continue
      restore_one_code_env "$kind" "$path" || true
    done <<< "$CODE_ENV_KINDS"
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

# ── openwiki (~/.openwiki/.env — MiniMax coding-plan key) ────────────────
# Mirrors the opencode/gogcli standalone-config pattern. After restore, the
# next `cd <repo> && openwiki` invocation reads the key from ~/.openwiki/.env
# without needing `openwiki --init` again.
if in_include openwiki; then
  note "restoring openwiki .env..."
  OW_DIR="${HOME}/.openwiki"
  mkdir -p "$OW_DIR"
  if decode_b64_block "openwiki_env" "$OW_DIR/.env" 0600; then
    ok "openwiki_env"
  else
    warn "openwiki_env: SKIPPED (null in source)"
  fi
fi

# ── openviking (~/.openviking/ov.conf + OPENROUTER_API_KEY in ~/.hermes/.env) ─────
# Restores the config file (which uses ${OPENROUTER_API_KEY} env-var
# substitution) AND the OpenRouter API key into ~/.hermes/.env (appending
# the OPENROUTER_API_KEY=... line if missing, replacing if present). The
# legacy .minimax-key file is also restored if present in the backup
# (kept for the 7-day rollback window after the 2026-07-24 migration).
# After restore, `kill -HUP` does NOT make OpenViking re-read config;
# `systemctl --user restart openviking-server` is required.
if in_include openviking; then
  note "restoring openviking config..."
  OV_DIR="${HOME}/.openviking"
  mkdir -p "$OV_DIR"
  chmod 700 "$OV_DIR"
  # Legacy key (kept for rollback; not read by OpenViking post-migration).
  if decode_b64_block "openviking_minimax_api_key" "$OV_DIR/.minimax-key" 0600; then
    ok "openviking_minimax_api_key (legacy rollback key)"
  else
    note "openviking_minimax_api_key: null in source (skipping — no legacy key in backup)"
  fi
  # ov.conf itself (mode 0600; uses ${OPENROUTER_API_KEY} substitution).
  if decode_b64_block "openviking_ov_conf" "$OV_DIR/ov.conf" 0600; then
    ok "openviking_ov_conf"
  else
    warn "openviking_ov_conf: SKIPPED (null in source)"
  fi
  # Live OpenRouter key: write into ~/.hermes/.env as OPENROUTER_API_KEY=...
  # Append if missing, replace in place if present. Never touch other lines.
  if grep -q '^openviking_openrouter_api_key: "' "$SRC"; then
    OPENROUTER_VAL=$(python3 -c "
import re, pathlib
text = pathlib.Path('$SRC').read_text()
m = re.search(r'^openviking_openrouter_api_key:\s*\"(.*)\"\s*\$', text, re.MULTILINE)
if m: print(m.group(1).replace('\\\\\\\\', '\x00').replace('\\\\\"', '\"').replace('\x00', '\\\\'))
")
    if [ -n "$OPENROUTER_VAL" ]; then
      HERMES_ENV="${HOME}/.hermes/.env"
      mkdir -p "${HOME}/.hermes"
      chmod 700 "${HOME}/.hermes"
      if [ -f "$HERMES_ENV" ]; then
        chmod 600 "$HERMES_ENV"
        if grep -q '^OPENROUTER_API_KEY=' "$HERMES_ENV"; then
          python3 - "$HERMES_ENV" "$OPENROUTER_VAL" <<'PYEOF'
import os, pathlib, re, sys
env_path, new_val = sys.argv[1], sys.argv[2]
text = pathlib.Path(env_path).read_text()
escaped = new_val.replace('\\', '\\\\').replace('"', '\\"')
text = re.sub(r'^OPENROUTER_API_KEY=.*$', f'OPENROUTER_API_KEY="{escaped}"', text, count=1, flags=re.MULTILINE)
pathlib.Path(env_path).write_text(text)
os.chmod(env_path, 0o600)
PYEOF
          ok "OPENROUTER_API_KEY replaced in $HERMES_ENV"
        else
          printf 'OPENROUTER_API_KEY="%s"\n' "$OPENROUTER_VAL" >> "$HERMES_ENV"
          chmod 600 "$HERMES_ENV"
          ok "OPENROUTER_API_KEY appended to $HERMES_ENV"
        fi
      else
        printf 'OPENROUTER_API_KEY="%s"\n' "$OPENROUTER_VAL" > "$HERMES_ENV"
        chmod 600 "$HERMES_ENV"
        ok "OPENROUTER_API_KEY written to new $HERMES_ENV"
      fi
    else
      warn "openviking_openrouter_api_key: empty value in source — skipping write"
    fi
  else
    note "openviking_openrouter_api_key: not present in source (skipping write)"
  fi
fi

# ── Varlock pass store + GPG private key (added 2026-07-20, Stage 3) ─────
# Three blocks cover the encrypted store + key recovery:
#   * varlock_gpg_armored_private  — single-file armored private key export.
#                                    Imported first (deterministic, durable,
#                                    works regardless of agent state).
#   * varlock_gpg_private_tar_gz   — tar.gz of ~/.gnupg/private-keys-v1.d/
#                                    (opportunistic second layer; may be empty
#                                    if .key files have not been materialized
#                                    by a prior agent access).
#   * varlock_pass_store_tar_gz    — tar.gz of ~/.password-store/ (encrypted
#                                    entries + .gpg-id).
# After restore, the operator verifies with:
#   pass show <any-existing-key>     # works iff GPG key + store are both present
#   gpg --list-secret-keys           # fingerprint should match inventory
if in_include varlock-pass; then
  note "restoring varlock pass store + GPG private key (merge-restore, preserves existing)..."
  GPG_KEYS_DIR="${HOME}/.gnupg/private-keys-v1.d"
  mkdir -p "$GPG_KEYS_DIR"
  chmod 700 "$GPG_KEYS_DIR"
  # Step 1: import the armored private key. This is the durable path —
  # it always works regardless of whether the .key files were materialized.
  # We pipe through a tempfile because `decode_b64_block` writes the
  # decoded content to a target file, but gpg --import expects a path.
  ARMORED_TMP=$(mktemp -t varlock-armored-XXXXXX.asc)
  chmod 600 "$ARMORED_TMP"
  if decode_b64_block "varlock_gpg_armored_private" "$ARMORED_TMP" 0600 2>/dev/null; then
    # gpg --import is idempotent — re-importing the same key prints a
    # "already in keyring" notice and exits 0. --batch suppresses any
    # pinentry prompt; --yes avoids the "import anyway?" confirmation.
    # Inline env var (HOME/GNUPGHOME) scopes the import to the synthetic
    # HOME; this is intentional, not a shellcheck SC2097 false positive.
    # shellcheck disable=SC2097,SC2098
    IMPORT_OUT=$(HOME="$HOME" GNUPGHOME="$HOME/.gnupg" gpg --batch --yes \
        --pinentry-mode loopback --import "$ARMORED_TMP" 2>&1 || true)
    if echo "$IMPORT_OUT" | grep -qE '(imported|unchanged|new signatures)'; then
      ok "varlock_gpg_armored_private (imported)"
    else
      warn "varlock_gpg_armored_private: imported but unclear status — '$IMPORT_OUT'"
    fi
  else
    note "varlock_gpg_armored_private: null in source (skipping armored import)"
  fi
  rm -f "$ARMORED_TMP"
  # Step 2: merge the .key files tar (opportunistic). After the armored
  # import, the .key files should already be on disk; the tar merge just
  # adds anything the armored import missed.
  if extract_tar_gz_b64_block_preserve "varlock_gpg_private_tar_gz" "$GPG_KEYS_DIR" 2>/dev/null; then
    ok "varlock_gpg_private (merged into $GPG_KEYS_DIR)"
  else
    note "varlock_gpg_private_tar_gz: null in source (skipping — armored import was sufficient)"
  fi
  # Step 3: merge the pass store tar (merge semantics — never clobbers).
  PASS_DIR="${HOME}/.password-store"
  mkdir -p "$PASS_DIR"
  chmod 700 "$PASS_DIR"
  if extract_tar_gz_b64_block_preserve "varlock_pass_store_tar_gz" "$PASS_DIR" 2>/dev/null; then
    ok "varlock_pass_store (merged into $PASS_DIR)"
  else
    warn "varlock_pass_store: SKIPPED (null in source or extraction failed)"
  fi
  # Defensive: enforce .gpg-id mode (the merge-restore preserves it from
  # the tar, but if the dir was empty before restore, mode 600 is critical
  # for pass init to accept the file).
  if [ -f "$PASS_DIR/.gpg-id" ]; then
    chmod 600 "$PASS_DIR/.gpg-id"
  fi
fi

# discord-notify + webhook-server restore blocks removed 2026-07-05 (PR #28)
# — services were decommissioned in PR #24; see header comment.

echo
echo "=== summary ==="
ok "restore complete"
note "restart services to pick up new secrets:"
note "  sudo systemctl restart nginx"
note "  systemctl --user restart hermes-gateway mercury-tasks oauth2-proxy openchamber"
note "  systemctl --user restart scriptcaster x-digest  # if --include code-env restored those"
note "  systemctl --user restart hermes-cron  # if you have cron-driven tasks"
note "  systemctl --user restart openviking-server  # if --include openviking restored that"
