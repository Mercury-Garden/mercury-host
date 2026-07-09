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
for svc in hermes-gateway mercury-tasks oauth2-proxy openchamber obscura-mcp session-migration; do
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

# ── 4a. systemd services that should be ACTIVELY running ────────────────
# This is intentionally separate from [systemd-system] above, which only
# checks is-enabled. A service can be enabled but stopped — the canonical
# example is ollama, which is enabled but the user often keeps it
# inactive when not in use. We can't blanket-check is-active for every
# enabled service without false positives.
#
# This list is "services that should be running 24/7 unless someone has
# just stopped them on purpose." If you stop one of these temporarily,
# expect audit to scream at you until you start it back. The point is
# to catch the silent multi-day downtime that hit hermes-dashboard on
# 2026-07-05 → 2026-07-09 (the unit stopped cleanly, `is-enabled` still
# said enabled, audit never noticed). See AGENTS.md post-mortem note.
echo
echo "[active-services]"
for svc in nginx cron hermes-dashboard; do
  if ! systemctl is-enabled "$svc" >/dev/null 2>&1; then
    # Not enabled — skip; [systemd-system] will already have flagged that.
    continue
  fi
  # Note: `is-active` exits 3 on inactive/dead/failed and 4 on unknown —
  # that's the documented behavior, not an error. We must NOT let
  # those exit codes propagate up under `set -e` (the script is run
  # with `set -euo pipefail`), so swallow them here. The actual state
  # string is what we care about.
  active_state=""
  if active_state=$(systemctl is-active "$svc" 2>/dev/null); then
    :
  else
    # is-active returned non-zero; `active_state` is whatever partial
    # output it produced (usually "inactive" or "unknown"). Fall through
    # to the case below, which classifies correctly.
    :
  fi
  active_state="${active_state:-unknown}"
  case "${active_state}" in
    active)
      ok "$svc active (system)"
      ;;
    failed)
      drift "$svc in ActiveState=failed (system) — fix: sudo systemctl status $svc; sudo systemctl restart $svc"
      ;;
    inactive|dead|activating|reloading|deactivating)
      # Get how long it's been down to flag long-running silent outages
      inactive_since=$(systemctl show "$svc" -p InactiveEnterTimestamp --value 2>/dev/null || true)
      inactive_since="${inactive_since:-unknown}"
      drift "$svc NOT active (state=${active_state}, inactive-since=${inactive_since})"
      ;;
    *)
      note "$svc in unexpected state: ${active_state}"
      ;;
  esac
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

# ── 9b. Project env files (per-repo .env presence + mode 0600) ──────────
# Drift on this section catches the recurring incident: an agent (or a manual
# cleanup) drops /home/ubuntu/data/code/<repo>/.env and the cron for that repo
# fails silently the next morning. The fix surfaces immediately.
#
# As of 2026-07-07 the list is auto-discovered from ~/data/code/ (every `.env*`
# file, excluding `*.example` / `*.sample` templates) — adding a new project
# with a .env needs no audit.sh edit. Files under ~/.config/ that are
# project-scoped (mercury-tasks tokens, openchamber startup.env) are checked
# in the static list below because they don't live under ~/data/code/.
echo
echo "[project_env]"
# Static checks for ~/.config/ project-scoped secrets.
PE_DRIFT=0
STATIC_PROJECT_ENVS=(
  "mercury-tasks:${HOME}/.config/mercury-tasks/tokens.json"
  "openchamber:${HOME}/.config/openchamber/startup.env"
)
for entry in "${STATIC_PROJECT_ENVS[@]}"; do
  label="${entry%%:*}"
  path="${entry#*:}"
  if [ -f "$path" ]; then
    mode=$(stat -c '%a' "$path")
    if [ "$mode" = "600" ]; then
      echo "  ✓ $label: present, mode 0600"
    else
      echo "  ✗ DRIFT: $label: mode $mode (want 600) at $path"
      PE_DRIFT=$((PE_DRIFT + 1))
    fi
  else
    echo "  ✗ DRIFT: $label: MISSING at $path — cron for this repo will fail"
    PE_DRIFT=$((PE_DRIFT + 1))
  fi
done
# Auto-discovered checks for every `.env*` file under ~/data/code/.
# `~/data/code` may not exist on a fresh CI runner — that's expected,
# the static checks above still cover the .config/ project secrets.
CODE_ROOT="${BACKUP_CODE_ROOT:-${HOME}/data/code}"
if [ -d "$CODE_ROOT" ]; then
  # mapfile handles paths with spaces/newlines safely.
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
    echo "  (no .env* files under $CODE_ROOT — nothing to check)"
  else
    for env_file in "${CODE_ENV_FILES[@]}"; do
      [ -n "$env_file" ] || continue
      label="$(printf '%s' "$env_file" | sed "s#^${CODE_ROOT}/##")"
      mode=$(stat -c '%a' "$env_file")
      if [ "$mode" = "600" ]; then
        echo "  ✓ $label: present, mode 0600"
      else
        echo "  ✗ DRIFT: $label: mode $mode (want 600) at $env_file"
        PE_DRIFT=$((PE_DRIFT + 1))
      fi
    done
  fi
else
  echo "  ($CODE_ROOT not present — skipping auto-discovered .env checks)"
fi
DRIFT=$((DRIFT + PE_DRIFT))

# ── 9c. Hermes per-profile irreplaceable paths (state.db, SOUL.md, etc.) ─
# Mirrors the project_env pattern but for `~/.hermes/profiles/<name>/`.
# Drift here means a fresh-host restore from the state tarball would land
# with an incomplete profile — fail loud so the user notices BEFORE the
# profile is needed in production. Hardcoded list (kept in lockstep with
# `hermes_profiles_irreplaceable` in inventory.yaml) so a missing profile
# file is detected on the very first audit run, not "when we try to use it".
echo
echo "[hermes_profile_state]"
HPS_DRIFT=0
declare -A HPS_PROFILE_FILES=(
  ["mercury-butler/state.db"]="600"
  ["mercury-butler/SOUL.md"]="600"
  ["mercury-butler/auth.json"]="600"
  ["mercury-butler/channel_directory.json"]="600"
  ["mercury-butler/config.yaml"]="600"
  ["mercury-butler/.env"]="600"
)
for rel in "${!HPS_PROFILE_FILES[@]}"; do
  full="$HOME/.hermes/profiles/$rel"
  want="${HPS_PROFILE_FILES[$rel]}"
  if [ -f "$full" ]; then
    actual=$(stat -c '%a' "$full")
    if [ "$actual" = "$want" ]; then
      echo "  ✓ $rel: present, mode $actual"
    else
      echo "  ✗ DRIFT: $rel: mode $actual (want $want) at $full"
      HPS_DRIFT=$((HPS_DRIFT + 1))
    fi
  else
    echo "  ✗ DRIFT: $rel: MISSING at $full — profile is unrecoverable"
    HPS_DRIFT=$((HPS_DRIFT + 1))
  fi
done
DRIFT=$((DRIFT + HPS_DRIFT))

# ── 9d. User cache paths relocated to /dev/sdb (2026-07-05) ───────────
# Drift here means /home/ubuntu's cache dirs are back on the boot
# volume — the very thing this PR was created to prevent. Each entry
# is the same shape as [project_env] / [hermes_profile_state]: a
# hardcoded bash map below that mirrors inventory.yaml → user_cache_paths.
# Detect on the very first audit run, not "when the boot disk fills
# up again".
#
# Checks per entry (src → declared target):
#   1. src is a symlink (not a real dir)
#   2. readlink -f resolves to declared target
#   3. target exists and is a directory
#   4. target lives on /dev/sdb (df --output=source on the target
#      differs from df --output=source on /home/ubuntu/)
echo
echo "[user_cache_paths]"
UCP_DRIFT=0
# Hardcoded so missing entries are detected on first audit run.
# Twin source of truth with inventory.yaml → user_cache_paths[].symlink/target.
declare -A UCP_SYMLINKS=(
  ["$HOME/.cache"]="/home/ubuntu/data/.cache"
  ["$HOME/.local/share"]="/home/ubuntu/data/.local/share"
)
for src in "${!UCP_SYMLINKS[@]}"; do
  dst="${UCP_SYMLINKS[$src]}"
  short_src="${src#"$HOME"}"       # ~/.cache    (display)
  short_dst="${dst#"$HOME"}"       # ~/data/...   (display)
  if [ ! -L "$src" ]; then
    drift "$short_src is NOT a symlink — cache has been moved back to /dev/sda!"
    UCP_DRIFT=$((UCP_DRIFT + 1))
    continue
  fi
  actual_target=$(readlink "$src")
  resolved=$(readlink -f "$src")
  if [ "$resolved" != "$dst" ]; then
    drift "$short_src -> $actual_target (resolves to $resolved, expected $short_dst)"
    UCP_DRIFT=$((UCP_DRIFT + 1))
    continue
  fi
  if [ ! -d "$dst" ]; then
    drift "$short_src target $short_dst does not exist on disk!"
    UCP_DRIFT=$((UCP_DRIFT + 1))
    continue
  fi
  # Verify the target sits on /dev/sdb (not sda). Uses df --output=source
  # which gives the device for the resolved mountpoint (sdb1 in our case).
  dst_dev=$(df --output=source "$dst" 2>/dev/null | tail -1 | tr -d ' ')
  home_dev=$(df --output=source /home/ubuntu 2>/dev/null | tail -1 | tr -d ' ')
  if [ -z "$dst_dev" ] || [ -z "$home_dev" ]; then
    note "$short_src -> $short_dst (could not verify filesystem; both df calls failed)"
    continue
  fi
  if [ "$dst_dev" = "$home_dev" ]; then
    drift "$short_src target $short_dst is on $dst_dev — SAME device as /home, NOT relocated to sdb!"
    UCP_DRIFT=$((UCP_DRIFT + 1))
  else
    ok "$short_src -> $short_dst (on $dst_dev ✓; home on $home_dev)"
  fi
done
DRIFT=$((DRIFT + UCP_DRIFT))

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
#
# We can't trust `systemctl show UnitFileState=enabled` alone — that field
# reflects systemd's *cached* enablement database, which can say "enabled"
# long after the underlying unit file has been deleted (which is exactly
# the 2026-07-08 silent-failure mode that hid the missing timer from us
# for ~3 days). We have to check three things independently:
#   (a) the symlink in ~/.config/systemd/user/ points at a real source
#   (b) `systemctl is-enabled` exits 0 (and is not "static" or "masked")
#   (c) the unit loaded successfully (ActiveState != "failed")
# Any one failing is a DRIFT.
import os, subprocess

timer_link = os.path.expanduser('~/.config/systemd/user/mercury-state-backup.timer')
service_link = os.path.expanduser('~/.config/systemd/user/mercury-state-backup.service')

# (a) Symlink reality check
for link in (timer_link, service_link):
    if not (os.path.islink(link) and os.path.exists(link)):
        print(f"  ✗ DRIFT: {link} is missing or dangling")
        print(f"     daily backups have stopped — the unit file is no longer installed")
        print(f"     fix: bash scripts/restore.sh  (it re-creates the symlink)")
        drift += 1

# (b) systemctl is-enabled — catches "static", "masked", or non-zero exit
try:
    res = subprocess.run(
        ['systemctl', '--user', 'is-enabled', 'mercury-state-backup.timer'],
        capture_output=True, text=True
    )
    is_enabled = res.stdout.strip()
    if res.returncode != 0 or is_enabled not in ('enabled', 'enabled-runtime'):
        print(f"  ✗ DRIFT: mercury-state-backup.timer is-enabled={is_enabled!r} (rc={res.returncode})")
        print(f"     fix: bash scripts/restore.sh")
        drift += 1
    else:
        print(f"  ✓ timer: is-enabled={is_enabled}")
except FileNotFoundError:
    print("  ! systemctl not found, skipping timer check")

# (c) Loaded and not failed
try:
    state_out = subprocess.check_output(
        ['systemctl', '--user', 'show', 'mercury-state-backup.timer',
         '--property=ActiveState,NextElapseUSecRealtime'],
        text=True, stderr=subprocess.DEVNULL
    )
    state = dict(line.partition('=')[0::2] for line in state_out.splitlines() if '=' in line)
    active = state.get('ActiveState', '')
    next_run = state.get('NextElapseUSecRealtime', '')
    if active == 'failed':
        print(f"  ✗ DRIFT: mercury-state-backup.timer is in ActiveState=failed")
        print(f"     fix: bash scripts/restore.sh")
        drift += 1
    elif not next_run:
        print(f"  ✗ DRIFT: mercury-state-backup.timer has no scheduled next run")
        print(f"     ActiveState={active!r}, NextElapseUSecRealtime={next_run!r}")
        print(f"     fix: bash scripts/restore.sh")
        drift += 1
    else:
        print(f"  ✓ timer: active={active}, next_run={next_run}")
except (subprocess.CalledProcessError, FileNotFoundError) as e:
    print(f"  ! could not read timer state: {e!r}")

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

# ── 12. OpenWiki (LangChain repo-documentation agent) ───────────────────
# Verifies the openwiki CLI is installed (per packages/node.yaml →
# globally_pinned_packages) and that the configured ~/.openwiki/.env
# matches inventory.yaml → openwiki:. Does NOT verify the API key value.
# Source of truth: inventory.yaml (provider / base_url / model / required
# env vars). The env file is written by `openwiki --init` and is a hand-edit
# file thereafter; this section catches drift if any of the four required
# env vars gets dropped or the base_url drifts.
echo
echo "[openwiki]"
OW_OUT=$(python3 - "$INV" 2>&1 <<'PYEOF'
import os, pathlib, re, sys

inv_path = pathlib.Path(sys.argv[1])
text = inv_path.read_text()
home = pathlib.Path.home()
ow_env = home / '.openwiki' / '.env'

def get_value_block(block, key):
    """Read a key under an `openwiki:` block — top-level of the block
    means column 2 (one indent past `openwiki:`). Match either column.
    Strips inline trailing comments after whitespace."""
    m = re.search(rf'^[ \t]{{0,4}}{re.escape(key)}:\s*(.*)$', block, re.MULTILINE)
    if not m:
        return None
    v = m.group(1).strip()
    v = re.split(r'\s+#', v, maxsplit=1)[0].strip()
    if v in ('null', '~', ''):
        return None
    if (v.startswith('"') and v.endswith('"')) or (v.startswith("'") and v.endswith("'")):
        return v[1:-1]
    return v

# Find the openwiki: block. Match from `^openwiki:` (column 0) to the next
# column-0 key or EOF. Tolerate blank/comment lines between keys (mirrors
# the cron-block heredoc pattern).
ow = re.search(r'^openwiki:\n((?:[^\n]*\n)*?)(?=^[A-Za-z_][^\n]*:\n|\Z)', text, re.MULTILINE)
if not ow:
    print("  ! openwiki: section not found in inventory, skipping")
    print("__OW_DRIFT__:0")
    sys.exit(0)
block = ow.group(1)

expected_provider  = get_value_block(block, 'provider')
expected_base_url  = get_value_block(block, 'base_url')
expected_model     = get_value_block(block, 'model')
expected_cfg       = get_value_block(block, 'config_file')
expected_cfg_mode  = get_value_block(block, 'config_file_mode')

# Parse env_keys_required: list of env-var names. Mirrors [web_search] shape.
ek_match = re.search(r'^  env_keys_required:\n((?:    - [^\n]*\n)*)', block, re.MULTILINE)
expected_env_keys = set()
if ek_match:
    expected_env_keys = set(re.findall(r'^\s*- (\S+)', ek_match.group(1), re.MULTILINE))

drift = 0

import shutil

def find_openwiki():
    """Locate the openwiki binary on PATH (or under the volta tools dir).
    Mirrors `command -v openwiki` semantics: returns the absolute path or None."""
    return shutil.which('openwiki')

# 1. CLI on PATH
if expected_cfg is None:
    expected_cfg = '~/.openwiki/.env'   # safe default

# Sanity: if the user ran `openwiki --init`, ~/.openwiki/.env exists. Until
# that point we still want the binary check to pass (the binary is installed
# via volta; the env file is user-driven). Don't drift on the env file
# existence — drift on its CONFIG contents when present.
ow_bin = find_openwiki()
if ow_bin:
    print(f"  ✓ openwiki on PATH: {ow_bin}")
else:
    print("  ✗ DRIFT: openwiki not on PATH — reinstall with `volta install openwiki`")
    drift += 1

if ow_env.exists():
    mode = oct(ow_env.stat().st_mode & 0o777)
    # Python returns '0o600' (octal-prefixed) — strip for comparison.
    mode_digits = mode.lstrip('0o').lstrip('0') or '0'
    if mode_digits == str(expected_cfg_mode or 600):
        print(f"  ✓ ~/{ow_env.relative_to(home)} mode 0{mode_digits}")
    else:
        print(f"  ✗ DRIFT: ~/.openwiki/.env mode 0{mode_digits} (want 0{expected_cfg_mode})")
        drift += 1

    env_text = ow_env.read_text()
    def env_get(k):
        m = re.search(rf'^{re.escape(k)}=', env_text, re.MULTILINE)
        if not m:
            return None
        # Read the full line, strip key prefix + optional quotes.
        line_re = re.search(rf'^{re.escape(k)}=(.+)$', env_text, re.MULTILINE)
        if not line_re:
            return None
        v = line_re.group(1).strip()
        if (v.startswith('"') and v.endswith('"')) or (v.startswith("'") and v.endswith("'")):
            return v[1:-1]
        return v

    # Required keys present (presence only for ANTHROPIC_API_KEY; value-shape
    # checks for the rest, since those are configuration not credentials).
    for k in expected_env_keys:
        v = env_get(k)
        if v is None or v == '':
            print(f"  ✗ DRIFT: {k} missing/empty in {ow_env}")
            drift += 1
        else:
            masked = v
            if k == 'ANTHROPIC_API_KEY':
                # Never print the key value — mask to length only.
                masked = f"<{len(v)}-char present>"
            print(f"  ✓ {k} = {masked}")

    # Cross-checks against inventory expectations (when those are set)
    def check_eq(label, actual, expected, expected_label):
        if expected is None:
            return 0
        if actual != expected:
            print(f"  ✗ DRIFT: {label} = {actual!r} (expected {expected!r} per inventory.yaml → openwiki.{expected_label})")
            return 1
        return 0

    drift += check_eq('OPENWIKI_PROVIDER',  env_get('OPENWIKI_PROVIDER'),  expected_provider,  'provider')
    drift += check_eq('ANTHROPIC_BASE_URL', env_get('ANTHROPIC_BASE_URL'), expected_base_url,  'base_url')
    drift += check_eq('OPENWIKI_MODEL_ID',  env_get('OPENWIKI_MODEL_ID'),  expected_model,     'model')
else:
    # Env file not present yet — that's the "user hasn't run openwiki --init"
    # state we explicitly accepted at install time. Note, do not drift.
    print("  ! ~/.openwiki/.env not present yet — run `openwiki --init` to configure provider + API key")
    print("    (intentional per 2026-07-08 install decision; this NOTE does not count as drift)")

print(f"__OW_DRIFT__:{drift}")
PYEOF
)
echo "$OW_OUT" | grep -v '__OW_DRIFT__:' || true
OW_DRIFT=$(echo "$OW_OUT" | grep '__OW_DRIFT__:' | tail -1 | sed 's/.*://')
OW_DRIFT=${OW_DRIFT:-0}
DRIFT=$((DRIFT + OW_DRIFT))

# ── summary ──────────────────────────────────────────────────────────────
echo
if [ "$DRIFT" -eq 0 ]; then
  echo "✓ no drift"
  exit 0
else
  echo "✗ $DRIFT drift item(s)"
  exit 1
fi