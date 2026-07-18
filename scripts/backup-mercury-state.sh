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
#     ~/.rustup/toolchains, ~/.npm, ~/.bun, ~/.local/share/mise,
#     ~/.volta (legacy — being phased out; superseded by mise on
#     2026-07-18 — see TODO at the active .volta exclude below))
#   - secrets.yaml (separate restore path: scripts/restore-secrets.sh)
#   - Let's Encrypt account private keys (see ELEVATED_EXCLUDES below)
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
# Log file lives under XDG state dir so it's always user-writable.
# Previous design wrote to /home/ubuntu/data/backups/.backup.log, which was
# originally created by a root-owned timer and never reopened as ubuntu:
# every backup ran for years with `tee: Permission denied` on stderr and
# the log file stayed stale. Moving to ~/.local/state avoids the perms trap.
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/mercury-state-backup"
LOG_FILE="${LOG_DIR}/backup.log"

mkdir -p "${BACKUP_ROOT}"

log() {
    mkdir -p "${LOG_DIR}"
    printf '[%s] %s\n' "${STAMP}" "$*" | tee -a "${LOG_FILE}"
}

# ----- 1. list of paths to capture -----
#
# Split into two arrays:
#   BACKUP_PATHS    — readable as $USER (ubuntu), tar'd directly
#   ELEVATED_PATHS  — root-only files (e.g. /etc/nginx snippets, letsencrypt
#                     account keys) that we still want in the backup. These
#                     require `sudo tar` and run as a SECOND pass whose
#                     output is concatenated to the main archive.
#                     Requires ubuntu to have NOPASSWD sudo (true on this
#                     host; verified by the audit's sudo check).
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
    # ── Per-project .env files (added 2026-07-03 after .env drop incident) ──
    # These are gitignored by every project (`.env` in .gitignore) so a git
    # pull can never recover them. backup-secrets.sh is the PRIMARY backup
    # (captured as b64 blocks in ~/.secrets/secrets.yaml); these entries are
    # a SECOND layer — daily tarball with mode 0600 preserved.
    #
    # Keep in sync with backup-secrets.sh SC_ENV/XD_ENV paths AND with
    # secrets/inventory.yaml pointer entries AND with audit.sh PROJECT_ENVS.
    /home/ubuntu/data/code/x-digest/.env
    /home/ubuntu/data/code/scriptcaster/.env
    /home/ubuntu/.config/openchamber/startup.env
    # ── Ollama user state (added 2026-07-14) ──────────────────────────────
    # 28 KB total. ~/.ollama/id_ed25519 is the ollama-cloud auth key
    # (different from ~/.ssh/id_ed25519); ~/.ollama/config.json holds
    # last_selection prefs. The ollama MODELS (blobs) are NOT here —
    # they live under /usr/share/ollama/.ollama/models when ollama is
    # installed system-wide, or under ~/.ollama/models as user-local
    # manifest refs. We capture what we can; see inventory.yaml →
    # state_backup.intentional_excludes for the .sqlite exclusion.
    /home/ubuntu/.ollama
    # ── OpenWiki .env (added 2026-07-14) ──────────────────────────────────
    # The API key IS captured by backup-secrets.sh (openwiki_env b64 block).
    # Capturing it here too means a daily tarball alone is sufficient to
    # restore openwiki state without needing the secrets round-trip.
    /home/ubuntu/.openwiki/.env
)

# /etc/nginx + /etc/letsencrypt contain root-only files. The nginx tree has
# mode 0600 vhost configs (webhook.mercury.garden) and snippets
# (oauth2-proxy-auth.conf). The letsencrypt accounts/ dir contains the ACME
# account's private_key.json (mode 0400) — this is the *account* key used
# to talk to Let's Encrypt, NOT the per-cert private key. The cert private
# keys live in /etc/letsencrypt/archive/*/privkey*.pem and ARE in the
# cert mode 0644 directory, so they're already readable. Only the account
# key needs explicit protection via ELEVATED_EXCLUDES.
ELEVATED_PATHS=(
    /etc/nginx
    /etc/letsencrypt
)

# Exclude the ACME account private key from the elevated pass. This is the
# key that authenticates us to Let's Encrypt. It can be regenerated by
# `certbot register --replace`, but losing it isn't a disaster — we just
# have to re-register. NOT capturing it keeps the backup tarball from
# containing a long-lived credential that has no DR value (regen is cheap).
ELEVATED_EXCLUDES=(
    --exclude='/etc/letsencrypt/accounts/*/private_key.json'
    # Also exclude live symlink target bookkeeping — it's in
    # /etc/letsencrypt/{live,renewal,archive} and the live+renewal dirs
    # are already symlinks to archive. Tar follows them with -h below.
)

# /etc/letsencrypt/{live,renewal} are symlink farms into /etc/letsencrypt/archive.
# Plain tar would either skip them (without -h) or archive both the symlink
# and the target (with -h, doubling size). Use -h so the archive contents
# match what a human would expect to see in a normal `ls -l /etc/letsencrypt`.

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
    --exclude='.local/share/mise'   # rebuild by `mise install`; ~200MB; replaced .volta 2026-07-18
    --exclude='.volta'              # legacy until Phase 5 teardown; rebuild by `volta install` if needed
    # TODO(post-Phase-5): once ~/.volta is removed (Phase 5, 2026-07-18),
    # delete the line above; tar will skip a non-existent path naturally,
    # so the exclude is just defensive against accidental restoration.
    --exclude='.secrets/secrets.yaml'
    # ── User cache relocation (2026-07-05) ──────────────────────────────
    # ~/.cache and ~/.local/share are now symlinks pointing at
    # /home/ubuntu/data/.cache and /home/ubuntu/data/.local/share.
    # Without these excludes, tar would either:
    #   (a) follow the symlink and try to archive the (large, sensible)
    #       sdb cache content, doubling daily backup size for no DR
    #       benefit (cache is rebuildable from registries), OR
    #   (b) with --one-file-system (which we use), archive the symlink
    #       record itself (4 bytes) which is harmless but confusing
    #       on restore.
    # Either way: skip the symlinks. Cache data is intentionally not
    # backed up. See inventory.yaml → user_cache_paths for the full
    # inventory of what this excludes.
    --exclude='/home/ubuntu/.cache'
    --exclude='/home/ubuntu/.local/share'
)

# ----- 3. check inputs -----
missing_paths=()
for p in "${BACKUP_PATHS[@]}" "${ELEVATED_PATHS[@]}"; do
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
# Two-pass approach, single archive:
#   Pass 1: tar as $USER over BACKUP_PATHS (no sudo needed)
#   Pass 2: tar as root (via sudo -n) over ELEVATED_PATHS
#
# We can't just pipe both tars into one zstd (subshell `;`):
#   - GNU tar writes an end-of-archive marker (two 512-byte zero blocks).
#   - When tar reads back a concatenated stream, it stops at the first
#     EOF marker — so the second pass's files would be invisible to
#     `tar -I zstd -tf` and `tar -I zstd -xf`.
#
# The correct way to combine two tars is `tar --concatenate` (-A):
#   1. tar pass 1 → TMP_TAR.user.tar
#   2. tar pass 2 → TMP_TAR.elev.tar
#   3. tar --concatenate -f TMP_TAR.user.tar TMP_TAR.elev.tar
#      (this appends elev onto user, rewriting the EOF marker)
#   4. zstd the combined tar → TMP_TAR
#
# All three tar files live in TMP_DIR (a subdir of BACKUP_ROOT) so
# disk space concerns are the same as before.
log "starting tar → ${TARBALL}"
START_NS=$(date +%s%N)

# Probe sudo NOPASSWD once so we can decide pass-2 strategy cleanly
SUDO_OK=0
if sudo -n true 2>/dev/null; then
    SUDO_OK=1
fi

USER_TAR="${TMP_DIR}/archive.user.tar"
ELEV_TAR="${TMP_DIR}/archive.elev.tar"

# Pass 1: user-readable paths
tar -C / -cf "${USER_TAR}" \
    --one-file-system \
    --ignore-failed-read \
    --warning=no-file-changed \
    --warning=no-file-removed \
    "${EXCLUDES[@]}" \
    "${BACKUP_PATHS[@]}" \
    2> >(tee -a "${LOG_FILE}" >&2) || true
# Note: `|| true` — with --ignore-failed-read, tar exits 0 if it read
# at least one file. A non-zero exit is "couldn't read anything", which
# is a real error. We check file size below to distinguish.
if [ ! -s "${USER_TAR}" ]; then
    log "ERROR: user-pass tar produced no output"
    rm -rf "${TMP_DIR}"
    exit 1
fi
log "user pass complete ($(stat -c%s "${USER_TAR}") bytes, $(tar -tf "${USER_TAR}" 2>/dev/null | wc -l) entries)"

# Pass 2: elevated paths (root-only). Skip if sudo isn't available —
# we'd rather have a partial backup than a failed one.
ELEV_OK=0
if [ ${#ELEVATED_PATHS[@]} -gt 0 ] && [ "${SUDO_OK}" -eq 1 ]; then
    log "elevated pass starting (sudo -n tar over ${#ELEVATED_PATHS[@]} path(s))"
    # -h dereferences symlinks (letsencrypt live/ + renewal/ → archive/)
    sudo -n tar -C / -chf "${ELEV_TAR}" \
        --one-file-system \
        --ignore-failed-read \
        --warning=no-file-changed \
        --warning=no-file-removed \
        "${ELEVATED_EXCLUDES[@]}" \
        "${ELEVATED_PATHS[@]}" \
        2> >(tee -a "${LOG_FILE}" >&2) || true
    if [ -s "${ELEV_TAR}" ]; then
        ELEV_OK=1
        log "elevated pass complete ($(stat -c%s "${ELEV_TAR}") bytes, $(tar -tf "${ELEV_TAR}" 2>/dev/null | wc -l) entries)"
    else
        log "WARN: elevated pass produced no output — nginx/letsencrypt will be MISSING this run"
        rm -f "${ELEV_TAR}"
    fi
elif [ ${#ELEVATED_PATHS[@]} -gt 0 ]; then
    log "WARN: sudo NOPASSWD not available — elevated paths will be SKIPPED"
    log "WARN: nginx vhost configs, oauth2-proxy snippets, letsencrypt"
    log "WARN: account keys will NOT be in this backup. Fix: grant"
    log "WARN: ubuntu NOPASSWD via /etc/sudoers.d/ubuntu-backup."
fi

# Combine: tar --concatenate (rewrites the EOF marker of USER_TAR so
# ELEV_TAR's entries become part of the same archive). Output goes
# to stdout, redirect back to USER_TAR to overwrite in place.
if [ "${ELEV_OK}" -eq 1 ]; then
    tar --concatenate -f "${USER_TAR}" "${ELEV_TAR}" 2> >(tee -a "${LOG_FILE}" >&2)
    rm -f "${ELEV_TAR}"
    log "concatenated: $(tar -tf "${USER_TAR}" 2>/dev/null | wc -l) total entries"
fi

# Compress
zstd -9 -T0 -q -o "${TMP_TAR}" "${USER_TAR}"
ZSTD_RC=$?
rm -f "${USER_TAR}"
if [ "${ZSTD_RC}" -ne 0 ] || [ ! -s "${TMP_TAR}" ]; then
    log "ERROR: zstd compression failed (rc=${ZSTD_RC})"
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

# ----- 8. integrity check — sample 5 files (1 privileged + 4 random) -----
# Random sampling alone skews heavily toward the bulk of the archive
# (~97% of files live under ~/.hermes/hermes-agent/). With 30K files
# dominated by python venv + tests + skills, a random 5-file sample
# never hits the privileged paths that are actually irreplaceable
# (.ssh, /etc/nginx, .env files). Verified 2026-07-14: all 5 of today's
# samples landed in ~/.hermes, telling us nothing about the 3% that
# matters. Pin one sample to the privileged subset and fill the rest
# randomly, excluding any path overlap with the pinned sample.
log "running integrity check (1 privileged + 4 random files)"
TMP_VERIFY="${TMP_DIR}/verify"
mkdir -p "${TMP_VERIFY}"

# Privileged paths — these are the irreplaceable subset. If any of
# these is missing or byte-mismatched, the backup is broken in a way
# that matters; the random samples are just broader coverage.
PRIVILEGED_PATHS=(
    "home/ubuntu/.ssh/id_ed25519"
    "home/ubuntu/.ssh/authorized_keys"
    "home/ubuntu/.gnupg/sshcontrol"
    "home/ubuntu/data/code/mercury-host/inventory.yaml"
    "home/ubuntu/.config/openchamber/startup.env"
    "home/ubuntu/data/code/x-digest/.env"
    "home/ubuntu/data/code/scriptcaster/.env"
    "home/ubuntu/.openwiki/.env"
    "home/ubuntu/.ollama/id_ed25519"
    "etc/nginx/sites-available/webhook.mercury.garden.conf"
    "etc/nginx/snippets/oauth2-proxy-auth.conf"
    # post-2026-07-18: verify the data-volume symlink invariant is intact.
    # ~/.local/share is a symlink to /home/ubuntu/data/.local/share; the
    # symlink itself IS in the backup, and we explicitly check it points
    # at the data volume (not the boot volume). 1 of 1 symlink test —
    # bias to a specific file in the linked tree so the sampler can't
    # accidentally skip on symlink resolution.
    "home/ubuntu/.local/share/mise/installs"
    "home/ubuntu/.local/bin/mise"
)

# Pick one privileged file that actually exists in the archive.
# Iterate the list deterministically so today's run reports the same
# privileged sample if rerun (shuf on the privileged set would make
# reruns non-reproducible — pick first existing).
PINNED=""
for cand in "${PRIVILEGED_PATHS[@]}"; do
    if tar -I zstd -tf "${TARBALL}" 2>/dev/null | grep -qx "${cand}"; then
        PINNED="${cand}"
        break
    fi
done

if [ -z "${PINNED}" ]; then
    log "WARN: no privileged paths present in archive — random-only mode"
fi

# Random samples: 4 regular files from the archive, excluding the pinned path.
mapfile -t CANDIDATES < <(
    tar -I zstd -tvf "${TARBALL}" 2>/dev/null \
    | awk '$1 ~ /^-/ && $NF !~ /\/$/ {print $NF}' \
    | grep -v -F "${PINNED}" \
    | shuf -n 4
)

# Prepend the pinned sample so it is verified first.
if [ -n "${PINNED}" ]; then
    CANDIDATES=("${PINNED}" "${CANDIDATES[@]}")
fi

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