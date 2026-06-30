#!/usr/bin/env bash
# scripts/backup-mercury-state.sh — snapshot irreplaceable host state to a local tarball.
#
# Captures config + data that cannot be rebuilt from the systems we already
# have (GitHub for code, package managers for software). Goes to:
#   /home/ubuntu/data/backups/mercury-state-YYYY-MM-DD.tar.zst
#
# Excludes (recoverable elsewhere or huge rebuild-from-source):
#   - node_modules, .pnpm-store, web/dist, coverage, test-results
#   - .git internals (code is in GitHub)
#   - package caches (.cache, ~/.local/share/uv, ~/.cargo/registry,
#     ~/.rustup/toolchains, ~/.npm, ~/.bun, ~/.volta)
#   - secrets.yaml (separate restore path: scripts/restore-secrets.sh)
#
# Each run produces:
#   - mercury-state-YYYY-MM-DD.tar.zst       the archive
#   - mercury-state-YYYY-MM-DD.manifest.json sidecar metadata (file count,
#                                          sizes, duration, sha256)
#   - mercury-state-YYYY-MM-DD.verify.json  integrity-check sample results
#
# Schedule: systemd timer (mercury-state-backup.timer) daily at 03:00 America/Bogota.
# Retention: keep last 7 tarballs (see prune logic at the bottom).
#
# Exit codes:
#   0 success
#   1 tar failed
#   2 manifest write failed
#   3 integrity check failed (warning — does not abort the backup)
#   4 prune failed (warning — does not abort the backup)

set -euo pipefail

BACKUP_ROOT="/home/ubuntu/data/backups"
STATE_NAME="mercury-state"
DATE_UTC="$(date -u +%Y-%m-%d)"
STAMP="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
TARBALL="${BACKUP_ROOT}/${STATE_NAME}-${DATE_UTC}.tar.zst"
MANIFEST="${BACKUP_ROOT}/${STATE_NAME}-${DATE_UTC}.manifest.json"
VERIFY="${BACKUP_ROOT}/${STATE_NAME}-${DATE_UTC}.verify.json"
# Use the backup dir for tmp scratch too — the boot volume (/tmp) is small
# and tends to fill up; /home/ubuntu/data lives on /dev/sdb with 45GB free.
TMP_DIR="$(mktemp -d -p "${BACKUP_ROOT}" -t mercury-state-XXXXXX)"
TMP_TAR="${TMP_DIR}/archive.tar.zst"
LOG_FILE="/home/ubuntu/data/backups/.backup.log"

mkdir -p "${BACKUP_ROOT}"

log() {
    printf '[%s] %s\n' "${STAMP}" "$*" | tee -a "${LOG_FILE}"
}

# ----- 1. list of paths to capture (must all be readable by $USER) -----
BACKUP_PATHS=(
    /home/ubuntu/.hermes
    /home/ubuntu/.config
    /home/ubuntu/.ssh
    /home/ubuntu/.gnupg
    /home/ubuntu/.local/share/opencode
    /home/ubuntu/.oh-my-zsh/custom
    /home/ubuntu/.plannotator
    /home/ubuntu/.codegraph
    /home/ubuntu/bin
    /home/ubuntu/update.sh
    /home/ubuntu/certbot-dns-hook.sh
    /home/ubuntu/wildcard-cert-instructions.md
    /home/ubuntu/data/code/mercury-host
    /home/ubuntu/.zshrc
    /home/ubuntu/.zshenv
    /home/ubuntu/.profile
    /home/ubuntu/.gitconfig
    /etc/systemd/system
    /etc/systemd/user
    /etc/nginx
    /etc/letsencrypt
)

# ----- 2. exclude list -----
EXCLUDES=(
    --exclude='*.log'
    --exclude='*.log.*'
    --exclude='__pycache__'
    --exclude='*.pyc'
    --exclude='*.wasm'
    --exclude='*.map'
    --exclude='node_modules'
    --exclude='.pnpm-store'
    --exclude='coverage'
    --exclude='test-results'
    --exclude='playwright-report'
    --exclude='web/dist'
    --exclude='.git'
    --exclude='.cache'
    --exclude='.cargo/registry'
    --exclude='.rustup/toolchains'
    --exclude='.npm'
    --exclude='.bun'
    --exclude='.local/share/uv'
    --exclude='.local/share/pnpm/store'
    --exclude='.local/share/Trash'
    --exclude='.volta'
    --exclude='.secrets/secrets.yaml'
)

# ----- 3. check inputs -----
missing_paths=()
for p in "${BACKUP_PATHS[@]}"; do
    [ -e "$p" ] || missing_paths+=("$p")
done
if [ ${#missing_paths[@]} -gt 0 ]; then
    log "WARN: ${#missing_paths[@]} source path(s) missing (skipped):"
    for p in "${missing_paths[@]}"; do
        log "  - $p"
    done
fi

# ----- 4. check disk space (need ~3x projected tarball size for safety) -----
avail_kb=$(df -P "${BACKUP_ROOT}" | awk 'NR==2 {print $4}')
avail_mb=$((avail_kb / 1024))
if [ "${avail_mb}" -lt 2048 ]; then
    log "ERROR: only ${avail_mb}MB free in ${BACKUP_ROOT}; need at least 2GB"
    exit 1
fi
log "disk free: ${avail_mb}MB in ${BACKUP_ROOT}"

# ----- 5. build the tarball -----
log "starting tar → ${TARBALL}"
START_NS=$(date +%s%N)

tar -C / -cf - \
    --one-file-system \
    --ignore-failed-read \
    --warning=no-file-changed \
    --warning=no-file-removed \
    "${EXCLUDES[@]}" \
    "${BACKUP_PATHS[@]}" \
    2> >(tee -a "${LOG_FILE}" >&2) \
    | zstd -9 -T0 -q -o "${TMP_TAR}"

# tar exits 0 if at least one file was archived, even if some files were
# unreadable. If we got a 0-byte archive something is very wrong.
TAR_PIPE_RC="${PIPESTATUS[0]:-0}"
ZSTD_PIPE_RC="${PIPESTATUS[1]:-0}"
if [ "${TAR_PIPE_RC}" -ne 0 ]; then
    log "ERROR: tar exited with status ${TAR_PIPE_RC}"
    rm -rf "${TMP_DIR}"
    exit 1
fi
if [ "${ZSTD_PIPE_RC}" -ne 0 ]; then
    log "ERROR: zstd exited with status ${ZSTD_PIPE_RC}"
    rm -rf "${TMP_DIR}"
    exit 1
fi
if [ ! -s "${TMP_TAR}" ]; then
    log "ERROR: tarball is empty"
    rm -rf "${TMP_DIR}"
    exit 1
fi

END_NS=$(date +%s%N)
DURATION_S=$(( (END_NS - START_NS) / 1000000000 ))

# ----- 6. move tmp tarball into final location (atomic on same fs) -----
mv "${TMP_TAR}" "${TARBALL}"
SIZE_BYTES=$(stat -c%s "${TARBALL}")
SHA256=$(sha256sum "${TARBALL}" | awk '{print $1}')
SIZE_MB=$((SIZE_BYTES / 1024 / 1024))

log "tarball built: ${SIZE_MB}MB in ${DURATION_S}s, sha256=${SHA256:0:16}..."

# ----- 7. count files + total uncompressed size via tar -tvf -----
log "computing manifest"
FILE_COUNT=$(tar -I zstd -tf "${TARBALL}" 2>/dev/null | grep -cv '/$')
# uncompressed size from tar header (sum of byte 124..136, base-8) is fiddly;
# use du on extracted listing — cheaper to approximate as 5-10x compressed.
# Instead, do a real count by extracting file sizes with `tar -tv`.
TOTAL_BYTES=$(tar -I zstd -tvf "${TARBALL}" 2>/dev/null \
    | awk '$1 ~ /^-/ { gsub(/[^0-9]/,"",$3); s+=$3 } END { print s+0 }')

cat > "${MANIFEST}" <<EOF
{
  "kind": "mercury-state-backup",
  "version": 1,
  "started_at_utc": "${STAMP}",
  "duration_seconds": ${DURATION_S},
  "archive": {
    "path": "${TARBALL}",
    "size_bytes": ${SIZE_BYTES},
    "size_mb": ${SIZE_MB},
    "sha256": "${SHA256}",
    "compression": "zstd -9"
  },
  "contents": {
    "file_count": ${FILE_COUNT},
    "uncompressed_bytes": ${TOTAL_BYTES}
  },
  "sources": $(printf '%s\n' "${BACKUP_PATHS[@]}" | jq -R . | jq -s .),
  "excludes_patterns": $(printf '%s\n' "${EXCLUDES[@]}" | jq -R . | jq -s .),
  "missing_at_run": $(if [ ${#missing_paths[@]} -gt 0 ]; then
                          printf '%s\n' "${missing_paths[@]}" | jq -R . | jq -s .
                      else
                          echo '[]'
                      fi),
  "host": {
    "hostname": "$(hostname)",
    "user": "${USER}",
    "disk_free_mb_at_start": ${avail_mb}
  }
}
EOF

log "manifest written: ${MANIFEST}"

# ----- 8. integrity check — sample 5 random files, restore + diff -----
log "running integrity check (5 random files)"
TMP_VERIFY="${TMP_DIR}/verify"
mkdir -p "${TMP_VERIFY}"

# Pick 5 regular files from the manifest (skip dirs/symlinks)
mapfile -t CANDIDATES < <(
    tar -I zstd -tvf "${TARBALL}" 2>/dev/null \
    | awk '$1 ~ /^-/ && $NF !~ /\/$/ {print $NF}' \
    | shuf -n 5
)

VERIFY_OK=0
VERIFY_FAIL=0
VERIFY_RESULTS="["
for sample in "${CANDIDATES[@]}"; do
    # paths inside the archive have no leading slash and no ./ prefix
    rel="${sample#/}"
    rm -rf "${TMP_VERIFY:?}/"*
    if tar -I zstd -xf "${TARBALL}" -C "${TMP_VERIFY}" "${rel}" 2>/dev/null \
       && [ -f "/${rel}" ] \
       && diff -q "/${rel}" "${TMP_VERIFY}/${rel}" >/dev/null 2>&1; then
        VERIFY_OK=$((VERIFY_OK + 1))
        VERIFY_RESULTS+="{\"path\":\"${rel}\",\"status\":\"ok\"},"
    else
        VERIFY_FAIL=$((VERIFY_FAIL + 1))
        VERIFY_RESULTS+="{\"path\":\"${rel}\",\"status\":\"mismatch_or_missing\"},"
    fi
done
VERIFY_RESULTS="${VERIFY_RESULTS%,}]"

cat > "${VERIFY}" <<EOF
{
  "kind": "mercury-state-integrity-check",
  "version": 1,
  "checked_at_utc": "$(date -u +%Y-%m-%dT%H-%M-%SZ)",
  "archive": "${TARBALL}",
  "samples_total": ${#CANDIDATES[@]},
  "samples_ok": ${VERIFY_OK},
  "samples_failed": ${VERIFY_FAIL},
  "results": ${VERIFY_RESULTS}
}
EOF

log "integrity: ${VERIFY_OK}/${#CANDIDATES[@]} ok"
if [ "${VERIFY_FAIL}" -gt 0 ]; then
    log "WARN: integrity check failed for ${VERIFY_FAIL} samples — see ${VERIFY}"
    rm -rf "${TMP_DIR}"
    exit 3
fi

# ----- 9. prune old backups (keep last 7) -----
log "pruning old backups (keeping last 7)"
PRUNED=0
# List tarballs sorted oldest-first, skip the most recent 7
mapfile -t OLD < <(
    find "${BACKUP_ROOT}" -maxdepth 1 -name "${STATE_NAME}-*.tar.zst" -type f \
    | sort \
    | head -n -7
)
for old in "${OLD[@]:-}"; do
    [ -z "${old}" ] && continue
    rm -f "${old}" "${old%.tar.zst}.manifest.json" "${old%.tar.zst}.verify.json"
    PRUNED=$((PRUNED + 1))
    log "  pruned: $(basename "$old")"
done
log "pruned ${PRUNED} old backup(s)"

# ----- 10. cleanup -----
rm -rf "${TMP_DIR}"

# Final status line — picked up by capture.sh / audit.sh
printf '%s\t%s\n' "${TARBALL}" "${SIZE_MB}" > "${BACKUP_ROOT}/.last_backup"
log "OK — backup complete"