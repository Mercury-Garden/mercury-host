#!/usr/bin/env bash
# scripts/audit.sh — read inventory.yaml and check a live host against it.
# Exits 0 if everything matches, 1 if any drift is found. Drift is printed
# in human-readable lines. Designed to be safe to run as a cron — non-zero
# exit on drift, so a wrapping cron job can notify.
#
# IMPORTANT: run under the user's interactive shell, not under a service
# account. This script sources ~/.zshrc to get the user's real PATH,
# otherwise it would report volta as missing whenever it runs under
# hermes-agent's venv-isolated PATH.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INV="$REPO_ROOT/inventory.yaml"
PKG_NODE="$REPO_ROOT/packages/node.yaml"

# Try to reconstruct the user's real PATH. Hermes-agent shells don't have
# volta on PATH; a real login shell does.
if [ -z "${USER_SHELL_LOADED:-}" ]; then
  if [ -f "$HOME/.zshrc" ] && command -v zsh >/dev/null 2>&1; then
    USER_PATH=$(zsh -i -c 'echo $PATH' 2>/dev/null | tail -1)
  elif [ -f "$HOME/.bashrc" ]; then
    USER_PATH=$(bash -i -c 'echo $PATH' 2>/dev/null | tail -1)
  fi
  if [ -n "${USER_PATH:-}" ]; then
    export PATH="$USER_PATH"
  fi
  export USER_SHELL_LOADED=1
fi

DRIFT=0
note() { printf '  %s\n' "$*"; }
drift() { printf '✗ DRIFT: %s\n' "$*"; DRIFT=$((DRIFT + 1)); }
ok()    { printf '✓ %s\n' "$*"; }

require_yaml_field() {
  # Recursively read a nested-ish YAML key. Handles the leading "  " indent
  # we use for sub-keys under node_managers.* in packages/node.yaml.
  local file="$1" key="$2"
  awk -v k="$key" '
    {
      stripped = $0
      sub(/^[ \t]+/, "", stripped)
      if (stripped ~ "^"k":") {
        sub("^"k":[ \t]*", "", stripped)
        gsub(/[ \t]+$/, "", stripped)
        print stripped
        exit
      }
    }
  ' "$file"
}

echo "=== mercury-host audit — $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

# ── 1. Volta + Node toolchain ────────────────────────────────────────────
echo
echo "[volta]"
if ! command -v volta >/dev/null 2>&1; then
  drift "volta not on PATH (after sourcing user shell)"
else
  ok "volta present: $(volta --version)"
fi

EXPECT_NODE=$(require_yaml_field "$PKG_NODE" "default_node")
EXPECT_NPM=$(require_yaml_field "$PKG_NODE" "default_npm")
EXPECT_PNPM=$(require_yaml_field "$PKG_NODE" "default_pnpm")

ACTUAL_NODE=$(volta list 2>/dev/null | awk '/^runtime node/ {print $2; exit}' | sed -E 's/^[^@]+@//; s/[()]//g')
ACTUAL_NPM=$(volta list 2>/dev/null | awk '/^package-manager npm/ {print $2; exit}' | sed -E 's/^[^@]+@//; s/[()]//g')
ACTUAL_PNPM=$(volta list 2>/dev/null | awk '/^package pnpm/ {print $2; exit}' | sed -E 's/^[^@]+@//; s/[()]//g')

if [ "$ACTUAL_NODE" = "$EXPECT_NODE" ]; then
  ok "default node = $EXPECT_NODE"
else
  drift "default node = '$ACTUAL_NODE' (expected '$EXPECT_NODE')"
fi
if [ "$ACTUAL_NPM" = "$EXPECT_NPM" ]; then
  ok "default npm = $EXPECT_NPM"
else
  drift "default npm = '$ACTUAL_NPM' (expected '$EXPECT_NPM')"
fi
if [ "$ACTUAL_PNPM" = "$EXPECT_PNPM" ]; then
  ok "default pnpm = $EXPECT_PNPM"
else
  drift "default pnpm = '$ACTUAL_PNPM' (expected '$EXPECT_PNPM')"
fi

# ── 2. Hermes bundled node ───────────────────────────────────────────────
echo
echo "[hermes]"
if [ ! -x "$HOME/.hermes/node/bin/node" ]; then
  drift "$HOME/.hermes/node/bin/node missing"
else
  HN=$("$HOME/.hermes/node/bin/node" --version)
  ok "hermes node = $HN"
fi

# ── 3. Project registry: every tracked project present + has a volta pin ─
echo
echo "[projects]"
while IFS=$'\t' read -r path repo expected_branch; do
  [ -z "$path" ] && continue
  # Expand leading ~ to $HOME, then resolve to absolute
  full="${path/#\~/$HOME}"
  if [ ! -d "$full" ]; then
    drift "$path (repo $repo) missing on disk"
    continue
  fi
  ok "$path present"
  if [ -f "$full/package.json" ]; then
    PINNED_NODE=$(python3 -c "import json; d=json.load(open('$full/package.json')); v=d.get('volta',{}); print(v.get('node',''))" 2>/dev/null)
    if [ -z "$PINNED_NODE" ]; then
      drift "  REPRODUCIBILITY: $full/package.json has no 'volta.node' pin"
    else
      ok "  volta pin = $PINNED_NODE"
    fi
  fi
  if [ -n "$expected_branch" ] && [ -d "$full/.git" ]; then
    ACTUAL=$(git -C "$full" branch --show-current 2>/dev/null)
    if [ "$ACTUAL" = "$expected_branch" ]; then
      ok "  branch = $expected_branch"
    else
      note "  branch = '$ACTUAL' (expected '$expected_branch')"
    fi
  fi
# Use python to parse the projects section — yaml is too gnarly for awk.
done < <(python3 - "$INV" <<'PYEOF'
import sys, yaml
inv_path = sys.argv[1]
data = yaml.safe_load(open(inv_path))
for proj in data.get('projects', []):
    path = proj.get('path', '')
    repo = proj.get('repo', '')
    branch = proj.get('expected_branch', '')
    if path:
        print(f"{path}\t{repo}\t{branch}")
PYEOF
)

# ── 4. systemd services enabled (NOT just active) ───────────────────────
# Split by kind: user services checked via systemctl --user, system services via plain systemctl.
# External services (owned by Ubuntu package) are still checked — if they're not enabled
# that's a real drift — but the inventory.yaml `external: true` flag tells us not to
# expect them to be in our tracked unit files.
echo
echo "[systemd-user]"
for svc in hermes-gateway mercury-tasks oauth2-proxy openchamber webhook-server discord-notify obscura-mcp session-migration; do
  if systemctl --user is-enabled "$svc" >/dev/null 2>&1; then
    ok "$svc enabled (user)"
  else
    drift "$svc NOT enabled (user)"
  fi
done
echo
echo "[systemd-system]"
for svc in nginx ollama cron hermes-dashboard; do
  if systemctl is-enabled "$svc" >/dev/null 2>&1; then
    ok "$svc enabled (system)"
  else
    note "$svc NOT enabled (system) — may be intentional (e.g., ollama on this host is not running)"
  fi
done

# ── 4b. Hermes STT backend ──────────────────────────────────────────────
# Tracks the local STT install that backs Hermes' Spanish-voice-message
# transcription. The pip package lives in the hermes-agent venv; the model
# cache downloads on first use.
echo
echo "[stt]"
HERMES_VENV="/home/ubuntu/.hermes/hermes-agent/venv"
if /home/ubuntu/.hermes/hermes-agent/venv/bin/python3 -c "import faster_whisper" >/dev/null 2>&1; then
  ok "faster-whisper installed in hermes-agent venv"
else
  drift "faster-whisper missing from hermes-agent venv (run: ${HERMES_VENV}/bin/python3 -m pip install faster-whisper)"
fi
if command -v ffmpeg >/dev/null 2>&1; then
  ok "ffmpeg present ($(command -v ffmpeg))"
else
  drift "ffmpeg missing (apt: ffmpeg)"
fi
if [ -d "$HOME/.cache/huggingface/hub/models--Systran--faster-whisper-small" ]; then
  ok "faster-whisper 'small' model cached"
else
  note "faster-whisper 'small' model not yet downloaded — will download on first voice message"
fi

# ── 5. nginx vhosts enabled ──────────────────────────────────────────────
# nginx includes both regular files AND symlinks from sites-enabled/.
# Use -e (any exists) instead of -L (only symlink).
echo
echo "[nginx]"
for vhost in mercury.garden tasks.mercury.garden chamber.mercury.garden dev.mercury.garden plans.mercury.garden webhook.mercury.garden hermes.mercury.garden; do
  if [ -e "/etc/nginx/sites-enabled/$vhost" ]; then
    if [ -L "/etc/nginx/sites-enabled/$vhost" ]; then
      ok "$vhost enabled (symlink)"
    else
      note "$vhost enabled (regular file — consider converting to symlink for consistency)"
    fi
  else
    drift "$vhost NOT in sites-enabled"
  fi
done

# ── 6. Letsencrypt ───────────────────────────────────────────────────────
echo
echo "[letsencrypt]"
if [ -d /etc/letsencrypt/live/mercury.garden ]; then
  ok "/etc/letsencrypt/live/mercury.garden present"
else
  drift "/etc/letsencrypt/live/mercury.garden missing"
fi

# ── 7. Network files match tracked copies in network/ ────────────────────
echo
echo "[network]"
if [ -f network/hostname ]; then
  EXPECTED=$(cat network/hostname)
  ACTUAL=$(hostname)
  if [ "$EXPECTED" = "$ACTUAL" ]; then
    ok "hostname = $EXPECTED"
  else
    drift "hostname = '$ACTUAL' (expected '$EXPECTED' from network/hostname)"
  fi
else
  note "network/hostname not in repo yet — skipping"
fi
if [ -f network/hosts ]; then
  if diff -q /etc/hosts network/hosts >/dev/null 2>&1; then
    ok "/etc/hosts matches network/hosts"
  else
    note "/etc/hosts differs from network/hosts — run scripts/capture.sh to refresh"
  fi
else
  note "network/hosts not in repo yet — skipping"
fi

# ── 8. PATH order (uses already-reconstructed USER_PATH) ─────────────────
echo
echo "[path]"
# Read the first entry of path_order_required from node.yaml
EXPECTED_FIRST=$(awk '/^path_order_required:/{flag=1; next} flag && /^  - /{print $2; exit}' "$PKG_NODE" | sed "s|^~|$HOME|")
FIRST=$(echo "$PATH" | tr ':' '\n' | head -1)
if [ "$FIRST" = "$EXPECTED_FIRST" ]; then
  ok "PATH starts with $EXPECTED_FIRST"
else
  drift "PATH starts with '$FIRST' (expected '$EXPECTED_FIRST')"
fi

# ── 9. Cron (system cron.d + hermes jobs) ────────────────────────────────
echo
echo "[cron]"
# Run python: capture stdout (the human-readable ✓/✗ lines) AND stderr (drift count).
CRON_OUT=$(python3 - "$INV" 2>&1 <<'PYEOF'
import json, pathlib, subprocess, sys
inv_path = pathlib.Path(sys.argv[1])
text = inv_path.read_text()
home = pathlib.Path.home()

# system_cron_d: extract from YAML. Tolerate comments between key + list.
import re
scd = re.search(r'^  system_cron_d:\n((?:    [^\n]*\n)*)', text, re.MULTILINE)
expected = set()
if scd:
    for line in scd.group(1).splitlines():
        m = re.match(r'^    - (\S+)\s*$', line)
        if m:
            expected.add(m.group(1))

# Actual
cron_d = pathlib.Path('/etc/cron.d')
actual = set()
if cron_d.is_dir():
    for entry in cron_d.iterdir():
        if entry.name.startswith('.'):
            continue
        actual.add(f"/etc/cron.d/{entry.name}")

# Compare
missing = expected - actual
extra = actual - expected
if not missing and not extra:
    print(f"  ✓ system_cron_d: {len(actual)} entries match inventory")
else:
    for p in sorted(missing):
        print(f"  ✗ DRIFT: {p} in inventory but missing on host")
    for p in sorted(extra):
        print(f"  ✗ DRIFT: {p} on host but not in inventory")

# Hermes jobs (default profile): parse jobs.json, count
jobs_file = home / '.hermes' / 'cron' / 'jobs.json'
drift = len(missing) + len(extra)
if jobs_file.exists():
    try:
        jd = json.loads(jobs_file.read_text())
        live = len(jd.get('jobs', []))
        declared = len(re.findall(r'^      - id: ', text, re.MULTILINE))
        if live == declared:
            print(f"  ✓ hermes.jobs: {live} jobs match inventory")
        else:
            print(f"  ✗ DRIFT: hermes.jobs live={live} inventory={declared}")
            drift += 1
    except json.JSONDecodeError as e:
        print(f"  ✗ hermes.jobs: jobs.json parse error: {e}")
        drift += 1
else:
    print(f"  ! {jobs_file} not present, skipping hermes.jobs check")

# Hermes jobs (per-profile): walk the hermes_profiles: block. Each profile
# has a `jobs_file:` path and a `jobs:` list. We count declared jobs in
# YAML vs the live jobs.json on disk. (Profiles without jobs: blocks
# contribute zero, which is fine for a profile that doesn't run crons.)
# Profile blocks look like:
#   hermes_profiles:
#     - profile: mercury-butler
#       jobs_file: ~/.hermes/profiles/mercury-butler/cron/jobs.json
#       jobs:
#         - id: ...
prof_blocks = re.findall(
    r'^    - profile:\s*(\S+)\n(?:      [^\n]*\n)*?      jobs_file:\s*(\S+)\n      jobs:\n((?:        [^\n]*\n)*)',
    text, re.MULTILINE)
if prof_blocks:
    for prof_name, prof_jobs_file, prof_jobs_block in prof_blocks:
        prof_jobs_file = prof_jobs_file.replace('~', str(home))
        # Count declared jobs in this profile's `jobs:` list (lines that
        # look like `        - id: ...`)
        declared = len(re.findall(r'^        - id: ', prof_jobs_block, re.MULTILINE))
        prof_path = pathlib.Path(prof_jobs_file)
        if prof_path.exists():
            try:
                jd = json.loads(prof_path.read_text())
                live = len(jd.get('jobs', []))
                if live == declared:
                    print(f"  ✓ hermes.jobs ({prof_name}): {live} jobs match inventory")
                else:
                    print(f"  ✗ DRIFT: hermes.jobs ({prof_name}) live={live} inventory={declared}")
                    drift += 1
            except json.JSONDecodeError as e:
                print(f"  ✗ hermes.jobs ({prof_name}): jobs.json parse error: {e}")
                drift += 1
        else:
            print(f"  ! {prof_jobs_file} not present, skipping hermes.jobs ({prof_name}) check")

# Emit the drift count on its own line so the parent shell can grep it.
print(f"__CRON_DRIFT__:{drift}")
PYEOF
)
# Echo the human-readable portion, then extract the drift count.
echo "$CRON_OUT" | grep -v '__CRON_DRIFT__:' || true
CRON_DRIFT=$(echo "$CRON_OUT" | grep '__CRON_DRIFT__:' | tail -1 | sed 's/.*://')
CRON_DRIFT=${CRON_DRIFT:-0}
DRIFT=$((DRIFT + CRON_DRIFT))

# ── 10. State backup (local tarball of host config + data) ─────────────
echo
echo "[state_backup]"
SB_OUT=$(python3 - "$INV" 2>&1 <<'PYEOF'
import datetime, json, pathlib, re, sys

inv_path = pathlib.Path(sys.argv[1])
text = inv_path.read_text()
backup_root = pathlib.Path('/home/ubuntu/data/backups')

# Parse state_backup: section from inventory
sb = re.search(r'^state_backup:\n((?:  [^\n]*\n)+)', text, re.MULTILINE)
if not sb:
    print("  ! state_backup: section not found in inventory, skipping")
    print("__SB_DRIFT__:0")
    sys.exit(0)

def get_value(block, key):
    m = re.search(rf'^  {re.escape(key)}:\s*(.*)$', block, re.MULTILINE)
    if not m:
        return None
    v = m.group(1).strip()
    # Strip inline comments (# preceded by whitespace or end of value)
    v = re.split(r'\s+#', v, maxsplit=1)[0].strip()
    if v in ('null', '~', ''):
        return None
    if v.startswith('"') and v.endswith('"'):
        return v[1:-1]
    return v

block = sb.group(1)
last_run = get_value(block, 'last_run_at')
expected_path = get_value(block, 'location')
max_age_hours = float(get_value(block, 'max_age_hours') or 36)

drift = 0

# 1. Tarballs exist
tarballs = sorted(backup_root.glob('mercury-state-*.tar.zst'))
if not tarballs:
    print(f"  ✗ DRIFT: no tarballs in {backup_root}")
    drift += 1
else:
    print(f"  ✓ tarballs: {len(tarballs)} in {backup_root}")

# 2. Latest backup is fresh
if last_run and last_run != 'null':
    try:
        # Backup timestamps use dashes in HH-MM-SS (filename-safe).
        # Replace dashes in the time portion with colons so Python's fromisoformat accepts them.
        norm = re.sub(r'(\d{4}-\d{2}-\d{2})T(\d{2})-(\d{2})-(\d{2})', r'\1T\2:\3:\4', last_run)
        norm = norm.replace('Z', '+00:00')
        last_dt = datetime.datetime.fromisoformat(norm)
        age = datetime.datetime.now(datetime.timezone.utc) - last_dt
        age_hours = age.total_seconds() / 3600
        if age_hours > max_age_hours:
            print(f"  ✗ DRIFT: last backup is {age_hours:.1f}h old (max {max_age_hours}h)")
            drift += 1
        else:
            print(f"  ✓ freshness: last backup {age_hours:.1f}h ago (max {max_age_hours}h)")
    except (ValueError, AttributeError) as e:
        print(f"  ! could not parse last_run_at '{last_run}': {e}")
else:
    print(f"  ! last_run_at not set — running capture.sh will populate it")

# 3. Systemd timer is enabled + scheduled
import subprocess
try:
    out = subprocess.check_output(
        ['systemctl', 'show', 'mercury-state-backup.timer',
         '--property=ActiveState,UnitFileState,NextElapseUSecRealtime'],
        text=True, stderr=subprocess.DEVNULL
    )
    state = {}
    for line in out.splitlines():
        if '=' in line:
            k, _, v = line.partition('=')
            state[k] = v
    if state.get('UnitFileState') != 'enabled':
        print(f"  ✗ DRIFT: mercury-state-backup.timer is {state.get('UnitFileState')}, expected enabled")
        drift += 1
    else:
        print(f"  ✓ timer: enabled, next run {state.get('NextElapseUSecRealtime', 'unknown')}")
except (subprocess.CalledProcessError, FileNotFoundError) as e:
    print(f"  ! systemd check failed: {e}")

# 4. OCI Block Volume backup (the outer DR layer) — check last backup age
# This requires oci CLI on the host, which we don't have. Skip but log.
# (User runs OCI CLI commands from their laptop; the volume backup
# is configured via Oracle Console, not the host.)

print(f"__SB_DRIFT__:{drift}")
PYEOF
)
echo "$SB_OUT" | grep -v '__SB_DRIFT__:' || true
SB_DRIFT=$(echo "$SB_OUT" | grep '__SB_DRIFT__:' | tail -1 | sed 's/.*://')
SB_DRIFT=${SB_DRIFT:-0}
DRIFT=$((DRIFT + SB_DRIFT))

# ── 11. Web search backend (Hermes web_search / web_extract) ────────────
echo
echo "[web_search]"
WS_OUT=$(python3 - "$INV" 2>&1 <<'PYEOF'
import os, pathlib, re, sys

inv_path = pathlib.Path(sys.argv[1])
text = inv_path.read_text()
home = pathlib.Path.home()

def get_value(block, key):
    m = re.search(rf'^  {re.escape(key)}:\s*(.*)$', block, re.MULTILINE)
    if not m:
        return None
    v = m.group(1).strip()
    v = re.split(r'\s+#', v, maxsplit=1)[0].strip()
    if v in ('null', '~', ''):
        return None
    if v.startswith('"') and v.endswith('"'):
        return v[1:-1]
    return v

# Parse web_search: section
ws = re.search(r'^web_search:\n((?:  [^\n]*\n)+)', text, re.MULTILINE)
if not ws:
    print("  ! web_search: section not found in inventory, skipping")
    print("__WS_DRIFT__:0")
    sys.exit(0)
block = ws.group(1)

expected_backend = get_value(block, 'backend')
expected_search = get_value(block, 'search_backend')
expected_extract = get_value(block, 'extract_backend')

# Parse keys_present_in_default_profile: list and _mercury_butler_profile: list
def get_list(block, prefix):
    """Parse `prefix:` followed by indented `- name` entries, return set."""
    m = re.search(rf'^  {re.escape(prefix)}:\n((?:    - [^\n]*\n)*)', block, re.MULTILINE)
    if not m:
        return set()
    return set(re.findall(r'^\s*- (\S+)', m.group(1), re.MULTILINE))

expected_default_keys = get_list(block, 'keys_present_in_default_profile')
expected_butler_keys = get_list(block, 'keys_present_in_mercury_butler_profile')

drift = 0

# 1. Live config.yaml: default profile
cfg_path = home / '.hermes' / 'config.yaml'
def read_web_backends(path):
    """Return (backend, search_backend, extract_backend) or all-None if missing."""
    if not path.exists():
        return None, None, None
    raw = path.read_text()
    def get(k):
        m = re.search(rf'^{k}:\s*(.*)$', raw, re.MULTILINE)
        if not m:
            return None
        v = m.group(1).strip().strip('"').strip("'")
        return v if v else None
    return get('web.backend'), get('web.search_backend'), get('web.extract_backend')

def check_profile(name, env_path, cfg_path, expected_keys, expected_backend):
    """Check a profile's web config + key presence. Returns drift count."""
    d = 0
    # Backend check (if expected)
    if expected_backend:
        live_b, live_s, live_e = read_web_backends(cfg_path)
        if live_b is None and live_s is None and live_e is None:
            # No web: block at all in config — could be intentional (uses default)
            # We only drift if the user explicitly stated this profile should have tavily.
            pass
        else:
            # A web: block exists — check it matches
            for label, live, exp in [
                ('backend', live_b, expected_backend),
                ('search_backend', live_s, expected_search),
                ('extract_backend', live_e, expected_extract),
            ]:
                if live and exp and live != exp:
                    print(f"  ✗ DRIFT: {name} web.{label} = {live!r}, expected {exp!r}")
                    d += 1
                elif live and exp and live == exp:
                    pass  # ok
                elif not live and exp:
                    print(f"  ✗ DRIFT: {name} web.{label} is empty, expected {exp!r}")
                    d += 1
    # Keys check
    if env_path.exists():
        env_text = env_path.read_text()
        for k in expected_keys:
            if not re.search(rf'^{re.escape(k)}=', env_text, re.MULTILINE):
                print(f"  ✗ DRIFT: {k} missing from {env_path}")
                d += 1
        if not d:
            print(f"  ✓ {name}: {len(expected_keys)} keys present" +
                  (f" + web.backend={expected_backend}" if expected_backend else ""))
    else:
        print(f"  ✗ DRIFT: {env_path} does not exist")
        d += 1
    return d

# Default profile: backend expected = tavily
drift += check_profile(
    'default', home / '.hermes' / '.env', cfg_path,
    expected_default_keys, expected_backend)
# mercury-butler: keys expected, backend intentionally not activated
drift += check_profile(
    'mercury-butler',
    home / '.hermes' / 'profiles' / 'mercury-butler' / '.env',
    home / '.hermes' / 'profiles' / 'mercury-butler' / 'config.yaml',
    expected_butler_keys, None)

print(f"__WS_DRIFT__:{drift}")
PYEOF
)
echo "$WS_OUT" | grep -v '__WS_DRIFT__:' || true
WS_DRIFT=$(echo "$WS_OUT" | grep '__WS_DRIFT__:' | tail -1 | sed 's/.*://')
WS_DRIFT=${WS_DRIFT:-0}
DRIFT=$((DRIFT + WS_DRIFT))

# ── summary ──────────────────────────────────────────────────────────────
echo
if [ "$DRIFT" -eq 0 ]; then
  echo "✓ no drift"
  exit 0
else
  echo "✗ $DRIFT drift item(s)"
  exit 1
fi