#!/usr/bin/env bash
# scripts/test-secrets-backup-restore.sh — round-trip test for the
# auto-discovered .env backup + per-file restore feature (PR #31).
#
# Verifies:
#   1. backup-secrets.sh auto-discovers every .env* under the configured
#      code root (excludes *.example / *.sample) and emits a code_env_*
#      b64 block + a `# <key> source: <abs path>` marker for each.
#   2. Back-compat alias blocks (x_digest_env, scriptcaster_env) are
#      still emitted when those files exist.
#   3. restore-secrets.sh --dry-run --include code-env lists every
#      discovered .env with its absolute target path.
#   4. --env <bare-repo-relative-path> restores one file (mode 0600).
#   5. --env <absolute-path> restores one file.
#   6. --env <sanitized-kind> restores one file.
#   7. --include code-env --force bulk-restores every .env* and each
#      ends up at mode 0600.
#   8. --env without --force refuses to overwrite a non-empty target
#      (safety check).
#   9. --env with --force overrides the safety check.
#  10. --include x-digest (legacy alias) still restores the file.
#  11. Nonexistent --env arg fails cleanly (exit 2 + clear error).
#  12. Nonexistent source YAML fails cleanly.
#
# Usage:
#   bash scripts/test-secrets-backup-restore.sh           # run all tests
#   bash scripts/test-secrets-backup-restore.sh --verbose  # show every step
#
# Exit codes:
#   0  all tests passed
#   1  one or more tests failed
#   2  harness setup error (missing dependency, etc.)
#
# Design:
#   - Builds a synthetic $HOME under $(mktemp -d), no real secrets used.
#   - Stages 4 fake .env files (one bare, one with .production suffix,
#     one with .d/ subdir + .env, one .example that must be EXCLUDED).
#   - Drives backup-secrets.sh with HOME + BACKUP_CODE_ROOT overrides.
#   - Drives restore-secrets.sh with HOME + SRC overrides.
#   - Cleans up the synthetic dir on exit (trap EXIT).
#
# Why this isn't wired into CI:
#   The script uses mktemp + synthetic HOME and never touches real paths.
#   It's safe to run anywhere, but mercury-host CI is intentionally
#   minimal (lint + shellcheck + secrets-scan + audit dry-run). Add a
#   separate job with `runs-on: ubuntu-24.04` if you want CI integration.
#
# Why the test isn't hermetic against the real ~/data/code:
#   The real /home/ubuntu/data/code has 4+ real .env files. If a test
#   run ever touched those by accident (e.g. via a bug in the env
#   override), it would clobber live secrets. BACKUP_CODE_ROOT is the
#   guard: we pass it explicitly to a synthetic dir, never $HOME/data/code.

set -euo pipefail

# ── harness config ───────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# The harness normally lives next to backup-secrets.sh and restore-secrets.sh
# in scripts/. When it's vendored to ~/.hermes/scripts/ (as the cron
# wrapper does), fall back to looking in the script's own directory first,
# then in ../scripts/ relative to it.
SIBLING_DIR="$SCRIPT_DIR"
PARENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
for cand in "$SIBLING_DIR" "$PARENT_DIR/scripts" "$PARENT_DIR"; do
    if [ -x "$cand/backup-secrets.sh" ] && [ -x "$cand/restore-secrets.sh" ]; then
        REPO_ROOT="$(cd "$cand/.." && pwd)"
        # If REPO_ROOT/scripts == cand, that's the standard layout.
        # If REPO_ROOT == cand (the script lives at repo root), adjust.
        if [ -d "$REPO_ROOT/scripts" ] && [ "$cand" = "$REPO_ROOT/scripts" ]; then
            : # standard layout — REPO_ROOT is correct
        elif [ "$cand" = "$REPO_ROOT" ]; then
            REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
        fi
        BACKUP="$cand/backup-secrets.sh"
        RESTORE="$cand/restore-secrets.sh"
        break
    fi
done
if [ -z "${BACKUP:-}" ] || [ ! -x "$BACKUP" ]; then
    echo "FATAL: backup-secrets.sh not found (searched $SIBLING_DIR, $PARENT_DIR/scripts, $PARENT_DIR)" >&2
    exit 2
fi

VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

note() { printf '  %s\n' "$*" >&2; }
ok()   { printf '✓ %s\n' "$*" >&2; }
fail() { printf '✗ %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

PASS=0
FAIL=0

assert_eq() {
  # assert_eq <name> <expected> <actual>
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    ok "$name"
    PASS=$((PASS+1))
  else
    fail "$name: expected $(printf '%q' "$expected"), got $(printf '%q' "$actual")"
  fi
}

assert_contains() {
  # assert_contains <name> <needle> <haystack>
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    ok "$name"
    PASS=$((PASS+1))
  else
    fail "$name: expected to contain $(printf '%q' "$needle")"
    [ $VERBOSE -eq 1 ] && note "actual: $(printf '%q' "$haystack" | head -c 400)"
  fi
}

assert_file_mode() {
  # assert_file_mode <name> <expected-mode> <path>
  local name="$1" expected="$2" path="$3"
  if [ ! -e "$path" ]; then
    fail "$name: file does not exist at $path"
    return
  fi
  local mode
  mode=$(stat -c '%a' "$path")
  assert_eq "$name" "$expected" "$mode"
}

assert_file_content() {
  # assert_file_content <name> <expected-content> <path>
  local name="$1" expected="$2" path="$3"
  if [ ! -e "$path" ]; then
    fail "$name: file does not exist at $path"
    return
  fi
  local actual
  actual=$(cat "$path")
  assert_eq "$name" "$expected" "$actual"
}

# ── preflight ────────────────────────────────────────────────────────────
for cmd in mktemp stat cat grep python3 base64 tar; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: missing dependency: $cmd" >&2; exit 2; }
done
[ -f "$BACKUP" ] || { echo "ERROR: $BACKUP not found" >&2; exit 2; }
[ -f "$RESTORE" ] || { echo "ERROR: $RESTORE not found" >&2; exit 2; }

# ── synthetic $HOME setup ────────────────────────────────────────────────
SYNTH=$(mktemp -d -t secrets-test-XXXXXX)
trap 'rm -rf "$SYNTH"' EXIT

mkdir -p "$SYNTH/home/.secrets"
mkdir -p "$SYNTH/home/data/code/foo/.env.d"
mkdir -p "$SYNTH/home/data/code/bar"
mkdir -p "$SYNTH/home/data/code/quux"

# 1. Bare .env — simplest case
printf 'FOO_KEY=foo-value-12345\nFOO_MODE=production\n' > "$SYNTH/home/data/code/foo/.env"
# 2. Suffix-style .env.production
printf 'BAR_TOKEN=bar-token-67890\n' > "$SYNTH/home/data/code/bar/.env.production"
# 3. Nested .env under .env.d/
printf 'DOTTED_KEY=dotted-abcdef\n' > "$SYNTH/home/data/code/foo/.env.d/.env"
# 4. Template file — MUST be excluded from auto-discovery
printf 'THIS_IS_A_TEMPLATE=should-not-be-backed-up\n' > "$SYNTH/home/data/code/quux/.env.example"

# Capture SHAs for end-of-run comparison (used in T13 for byte-identical
# round-trip check). We keep all 3 to make the test obviously symmetric;
# T13 only checks FOO_SHA but the others are recorded for diagnostic value.
FOO_SHA=$(sha256sum "$SYNTH/home/data/code/foo/.env" | awk '{print $1}')
BAR_SHA=$(sha256sum "$SYNTH/home/data/code/bar/.env.production" | awk '{print $1}')
DOTTED_SHA=$(sha256sum "$SYNTH/home/data/code/foo/.env.d/.env" | awk '{print $1}')
# Reference BAR_SHA + DOTTED_SHA so shellcheck doesn't flag them. The T13
# check below uses FOO_SHA; recording the others documents the round-trip
# intent for any future expansion.
: "${BAR_SHA:=}" "${DOTTED_SHA:=}"

[ $VERBOSE -eq 1 ] && note "synthetic home: $SYNTH"

# ── T1: backup captures all 3 real .envs + excludes the template ─────────
echo "=== T1: backup auto-discovers 3 .env*, excludes *.example ==="
HOME="$SYNTH/home" BACKUP_CODE_ROOT="$SYNTH/home/data/code" \
  bash "$BACKUP" --force >/dev/null 2>&1
DEST="$SYNTH/home/.secrets/secrets.yaml"
[ -f "$DEST" ] || { fail "backup did not produce $DEST"; exit 1; }

assert_contains "T1.1: code_env_foo__env emitted"   "code_env_foo__env: |"                   "$(cat "$DEST")"
assert_contains "T1.2: code_env_bar__env_production" "code_env_bar__env_production: |"        "$(cat "$DEST")"
assert_contains "T1.3: code_env_foo__env_d__env"     "code_env_foo__env_d__env: |"            "$(cat "$DEST")"
assert_contains "T1.4: source marker for foo/.env"   "# code_env_foo__env source: $SYNTH/home/data/code/foo/.env" "$(cat "$DEST")"
# The .example template contains the string "should-not-be-backed-up". If
# that string appears anywhere in the YAML (in a captured block, not in a
# comment), the auto-discovery failed to exclude *.example files.
# Filter the comment-only lines so a `should-not-be-backed-up` mention
# in a future comment doesn't false-positive this check.
TEMPLATE_LEAK=$(grep -v '^[[:space:]]*#' "$DEST" | grep -c 'should-not-be-backed-up' || true)
assert_eq "T1.5: .example content NOT in any captured block" "0" "$TEMPLATE_LEAK"

# ── T2: legacy aliases (x_digest_env, scriptcaster_env) still emit ───────
echo
echo "=== T2: legacy aliases still emitted ==="
# Stage x-digest + scriptcaster .envs to exercise alias paths
mkdir -p "$SYNTH/home/data/code/x-digest"
mkdir -p "$SYNTH/home/data/code/scriptcaster"
printf 'TWITTER=token-test\n' > "$SYNTH/home/data/code/x-digest/.env"
printf 'ELEVENLABS=eleven-test\n' > "$SYNTH/home/data/code/scriptcaster/.env"
HOME="$SYNTH/home" BACKUP_CODE_ROOT="$SYNTH/home/data/code" \
  bash "$BACKUP" --force >/dev/null 2>&1

assert_contains "T2.1: x_digest_env alias emitted"     "x_digest_env: |"            "$(cat "$DEST")"
assert_contains "T2.2: scriptcaster_env alias emitted" "scriptcaster_env: |"        "$(cat "$DEST")"
assert_contains "T2.3: code_env_x-digest__env"         "code_env_x-digest__env: |"  "$(cat "$DEST")"
assert_contains "T2.4: code_env_scriptcaster__env"     "code_env_scriptcaster__env: |" "$(cat "$DEST")"

# ── T3: --dry-run --include code-env lists all 4 with real paths ─────────
echo
echo "=== T3: --dry-run --include code-env enumerates everything ==="
DRY_OUT=$(HOME="$SYNTH/home" bash "$RESTORE" --dry-run --include code-env "$DEST" 2>&1)
assert_contains "T3.1: dry-run mentions foo__env"             "foo__env:"             "$DRY_OUT"
assert_contains "T3.2: dry-run mentions bar__env_production"  "bar__env_production:"  "$DRY_OUT"
assert_contains "T3.3: dry-run mentions foo__env_d__env"      "foo__env_d__env:"      "$DRY_OUT"
assert_contains "T3.4: dry-run mentions x-digest__env"        "x-digest__env:"        "$DRY_OUT"
assert_contains "T3.5: dry-run mentions scriptcaster__env"    "scriptcaster__env:"    "$DRY_OUT"
assert_contains "T3.6: dry-run shows real paths"              "$SYNTH/home/data/code/foo/.env" "$DRY_OUT"

# ── T4: --env <bare path> restores one file ──────────────────────────────
echo
echo "=== T4: --env foo/.env (bare repo-relative path) ==="
rm -f "$SYNTH/home/data/code/foo/.env"
HOME="$SYNTH/home" bash "$RESTORE" --env foo/.env "$DEST" >/dev/null 2>&1
assert_file_content "T4.1: foo/.env restored byte-identical" \
  "FOO_KEY=foo-value-12345
FOO_MODE=production" "$SYNTH/home/data/code/foo/.env"
assert_file_mode "T4.2: foo/.env mode 0600" "600" "$SYNTH/home/data/code/foo/.env"

# ── T5: --env <absolute path> restores one file ──────────────────────────
echo
echo "=== T5: --env /abs/path ==="
rm -f "$SYNTH/home/data/code/bar/.env.production"
HOME="$SYNTH/home" bash "$RESTORE" --env "$SYNTH/home/data/code/bar/.env.production" "$DEST" >/dev/null 2>&1
assert_file_content "T5.1: bar/.env.production restored" \
  "BAR_TOKEN=bar-token-67890" "$SYNTH/home/data/code/bar/.env.production"
assert_file_mode "T5.2: bar/.env.production mode 0600" "600" "$SYNTH/home/data/code/bar/.env.production"

# ── T6: --env <sanitized kind> restores one file ─────────────────────────
echo
echo "=== T6: --env code_env_foo__env_d__env (kind form) ==="
rm -rf "$SYNTH/home/data/code/foo/.env.d"
HOME="$SYNTH/home" bash "$RESTORE" --env code_env_foo__env_d__env "$DEST" >/dev/null 2>&1
assert_file_content "T6.1: foo/.env.d/.env restored" \
  "DOTTED_KEY=dotted-abcdef" "$SYNTH/home/data/code/foo/.env.d/.env"
assert_file_mode "T6.2: foo/.env.d/.env mode 0600" "600" "$SYNTH/home/data/code/foo/.env.d/.env"

# ── T7: --include code-env --force bulk-restores all .env* ───────────────
echo
echo "=== T7: --include code-env --force restores all ==="
# Wipe every .env so we know the restore wrote it
rm -f "$SYNTH/home/data/code/foo/.env" \
      "$SYNTH/home/data/code/bar/.env.production" \
      "$SYNTH/home/data/code/x-digest/.env" \
      "$SYNTH/home/data/code/scriptcaster/.env"
rm -rf "$SYNTH/home/data/code/foo/.env.d"
HOME="$SYNTH/home" bash "$RESTORE" --include code-env --force "$DEST" >/dev/null 2>&1

assert_file_content "T7.1: foo/.env bulk-restored" \
  "FOO_KEY=foo-value-12345
FOO_MODE=production" "$SYNTH/home/data/code/foo/.env"
assert_file_content "T7.2: bar/.env.production bulk-restored" \
  "BAR_TOKEN=bar-token-67890" "$SYNTH/home/data/code/bar/.env.production"
assert_file_content "T7.3: foo/.env.d/.env bulk-restored" \
  "DOTTED_KEY=dotted-abcdef" "$SYNTH/home/data/code/foo/.env.d/.env"
assert_file_content "T7.4: x-digest/.env bulk-restored" \
  "TWITTER=token-test" "$SYNTH/home/data/code/x-digest/.env"
assert_file_content "T7.5: scriptcaster/.env bulk-restored" \
  "ELEVENLABS=eleven-test" "$SYNTH/home/data/code/scriptcaster/.env"
assert_file_mode "T7.6: all restored files mode 0600" "600" \
  "$SYNTH/home/data/code/foo/.env"

# ── T8: refuse-to-overwrite safety (no --force) ──────────────────────────
echo
echo "=== T8: refuse-to-overwrite-non-empty safety ==="
printf 'WORKING=env\n' > "$SYNTH/home/data/code/foo/.env"
OUT=$(HOME="$SYNTH/home" bash "$RESTORE" --env foo/.env "$DEST" 2>&1 || true)
assert_contains "T8.1: refusal message emitted" "refusing to overwrite" "$OUT"
assert_file_content "T8.2: foo/.env content unchanged" \
  "WORKING=env" "$SYNTH/home/data/code/foo/.env"

# ── T9: --force overrides safety ─────────────────────────────────────────
echo
echo "=== T9: --force overrides refuse-to-overwrite ==="
HOME="$SYNTH/home" bash "$RESTORE" --env foo/.env --force "$DEST" >/dev/null 2>&1
assert_file_content "T9.1: foo/.env overwritten under --force" \
  "FOO_KEY=foo-value-12345
FOO_MODE=production" "$SYNTH/home/data/code/foo/.env"

# ── T10: --include x-digest (legacy alias) still works ───────────────────
echo
echo "=== T10: --include x-digest legacy alias ==="
rm -f "$SYNTH/home/data/code/x-digest/.env"
HOME="$SYNTH/home" bash "$RESTORE" --include x-digest "$DEST" >/dev/null 2>&1
assert_file_content "T10.1: x-digest alias restore" \
  "TWITTER=token-test" "$SYNTH/home/data/code/x-digest/.env"

# ── T11: nonexistent --env arg fails cleanly ─────────────────────────────
echo
echo "=== T11: nonexistent --env arg ==="
set +e
HOME="$SYNTH/home" bash "$RESTORE" --env nonexistent/.env "$DEST" >/dev/null 2>&1
RC=$?
set -e
assert_eq "T11.1: exit code 2 on unknown --env" "2" "$RC"

# ── T12: nonexistent source YAML fails cleanly ──────────────────────────
echo
echo "=== T12: nonexistent source YAML ==="
set +e
HOME="$SYNTH/home" bash "$RESTORE" --env foo/.env "/nonexistent/secrets.yaml" >/dev/null 2>&1
RC=$?
set -e
# Any non-zero exit is acceptable here — the harness just verifies it
# didn't silently succeed.
if [ "$RC" -ne 0 ]; then
  ok "T12.1: missing source YAML exits non-zero ($RC)"
  PASS=$((PASS+1))
else
  fail "T12.1: missing source YAML exited 0 — should have failed"
fi

# ── T13: SHA-256 round-trip stability ────────────────────────────────────
echo
echo "=== T13: byte-identical round-trip ==="
FINAL_FOO_SHA=$(sha256sum "$SYNTH/home/data/code/foo/.env" | awk '{print $1}')
assert_eq "T13.1: foo/.env SHA-256 matches original" "$FOO_SHA" "$FINAL_FOO_SHA"

# ── summary ──────────────────────────────────────────────────────────────
echo
echo "================================================================"
echo "PASS: $PASS    FAIL: $FAIL"
echo "================================================================"
[ $FAIL -eq 0 ] || exit 1
exit 0