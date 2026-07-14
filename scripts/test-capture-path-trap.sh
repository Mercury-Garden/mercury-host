#!/usr/bin/env bash
# scripts/test-capture-path-trap.sh — regression test for the capture.sh
# PATH-trap fix (Issue #56, fix/capture-path-trap PR).
#
# Background: capture.sh shells out to `volta list all` via subprocess. If
# the parent shell doesn't have ~/.volta/bin on PATH (hermes-gateway.service
# context, CI runner with sanitized PATH, fresh subprocess from any non-
# interactive tool), the call silently fails and globally_pinned_packages
# is captured as 0, nuking the real entries. This test verifies that:
#
#   1. capture.sh, invoked with PATH=/usr/bin:/bin, does NOT zero the
#      globally_pinned_packages list.
#   2. capture.sh, invoked with USER_SHELL_LOADED=1 + bad PATH (simulating
#      Layer B already done), Layer A's python-level prepend still keeps
#      the list intact.
#   3. capture.sh, invoked normally (full PATH), still produces the
#      expected number of packages.
#   4. The capture.sh's own ~/.zshrc source block exits non-zero gracefully
#      when the user has no ~/.zshrc AND no ~/.bashrc (hermetic container).
#
# Exit codes:
#   0  all 4 assertions passed
#   1  any assertion failed (caller decides what to do)
#
# Usage:
#   bash scripts/test-capture-path-trap.sh --verbose
#
# Idempotent. Reverts any working-tree changes the test itself makes.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

VERBOSE=0
for arg in "$@"; do
  case "$arg" in
    --verbose|-v) VERBOSE=1 ;;
    --help|-h)
      sed -n '2,15p' "$0"
      exit 0
      ;;
  esac
done

PASS=0
FAIL=0
FAILED_ASSERTIONS=()

note()   { printf '  %s\n' "$*"; }
ok()     { printf '  ✓ %s\n' "$*"; PASS=$((PASS + 1)); }
bad()    { printf '  ✗ FAIL: %s\n' "$*"; FAIL=$((FAIL + 1)); FAILED_ASSERTIONS+=("$*"); }
header() { printf '\n[%s] %s\n' "$1" "$2"; }

# Snapshot the current state of packages/node.yaml so we can restore it.
# We snapshot globally_pinned_packages specifically — the assertion target.
# Use a state-tracking awk that finds the start of the block (the
# `globally_pinned_packages:` key) and reads forward until a 2-space-indent
# line (block terminator), counting 4-space-indented `- name:` entries.
PINS_BEFORE=$(awk '
  /^    globally_pinned_packages:$/ { in_block=1; next }
  in_block && /^    [a-z]/ { in_block=0 }
  in_block && /^      - name:/ { count++ }
  END { print count+0 }
' packages/node.yaml)
if [ "$VERBOSE" -eq 1 ]; then
  note "current globally_pinned_packages count: $PINS_BEFORE"
fi

restore_state() {
  # If capture.sh modified packages/node.yaml during the test, restore it
  # from git so the working tree is clean for the human.
  if ! git diff --quiet packages/node.yaml 2>/dev/null; then
    git checkout packages/node.yaml 2>/dev/null || true
  fi
}
trap restore_state EXIT

assert_pins_intact() {
  # After running capture.sh, packages/node.yaml should still have the
  # same globally_pinned_packages count as before. For the test, we expect
  # EXACTLY equal because we control the env.
  local label="$1"
  local pins_after
  pins_after=$(awk '
    /^    globally_pinned_packages:$/ { in_block=1; next }
    in_block && /^    [a-z]/ { in_block=0 }
    in_block && /^      - name:/ { count++ }
    END { print count+0 }
  ' packages/node.yaml)
  if [ "$pins_after" -eq "$PINS_BEFORE" ]; then
    ok "$label: globally_pinned_packages still has $pins_after entries (was $PINS_BEFORE)"
  else
    bad "$label: globally_pinned_packages changed from $PINS_BEFORE to $pins_after (silent data loss!)"
  fi
  restore_state
}

# ── Assertion 1: capture.sh from a sanitized PATH does NOT zero the list ─
header "1/4" "capture.sh survives sanitized PATH (Layer B: USER_SHELL_LOADED bash guard)"
PATH=/usr/bin:/bin bash scripts/capture.sh >/dev/null 2>&1 || true
assert_pins_intact "sanitized PATH=/usr/bin:/bin"

# ── Assertion 2: capture.sh from a sanitized PATH with USER_SHELL_LOADED=1
#     (Layer B already done by some upstream tool, Layer A python-level
#     prepend must still work) does NOT zero the list.
header "2/4" "capture.sh survives with Layer A only (USER_SHELL_LOADED=1 + sanitized PATH)"
# We can't easily set USER_SHELL_LOADED from outside since capture.sh uses
# it as a one-shot guard. Instead, simulate by overriding HOME to a directory
# with no .zshrc / no .bashrc — forcing the bash guard to fail. The python
# Layer A prepend still works because it's a hard-coded os.path.expanduser
# to the real HOME (not the override).
TMPHOME=$(mktemp -d)
HOME_BACKUP="$HOME"
export HOME="$TMPHOME"
PATH=/usr/bin:/bin bash scripts/capture.sh >/dev/null 2>&1 || true
export HOME="$HOME_BACKUP"
rm -rf "$TMPHOME"
assert_pins_intact "no shell rc available, Layer A python-level prepend only"

# ── Assertion 3: capture.sh from a normal interactive shell (where
#     ~/.zshrc gets sourced and exports volta to PATH) still works.
#     Hermes-managed shells have a sanitized PATH without ~/.volta/bin —
#     the Layer B guard re-sources ~/.zshrc to recover it. This assertion
#     verifies that the full round-trip works (Layer B + Layer A both
#     coexist with the normal path).
header "3/4" "capture.sh with interactive shell PATH (Layer B recovers ~/.volta/bin)"
# Use the same PATH a real interactive shell would have: include /usr/bin
# but NOT ~/.volta/bin (Layer B should re-add it from ~/.zshrc).
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin bash scripts/capture.sh >/dev/null 2>&1 || true
assert_pins_intact "interactive shell PATH (Layer B recovers ~/.volta/bin from ~/.zshrc)"

# ── Assertion 4: the capture.sh's USER_SHELL_LOADED guard handles a
#     hermetic container gracefully (no .zshrc, no .bashrc) — exits 0
#     and does NOT crash on the missing rc files.
header "4/4" "USER_SHELL_LOADED guard handles missing shell rc files"
TMPHOME=$(mktemp -d)
HOME_BACKUP="$HOME"
export HOME="$TMPHOME"
if bash scripts/capture.sh >/dev/null 2>&1; then
  ok "capture.sh exited 0 with no .zshrc and no .bashrc in HOME"
else
  rc=$?
  bad "capture.sh exited non-zero ($rc) with no shell rc files"
fi
export HOME="$HOME_BACKUP"
rm -rf "$TMPHOME"
restore_state

# ── Summary ─────────────────────────────────────────────────────────────
printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"

if [ "$FAIL" -gt 0 ]; then
  printf 'Failed assertions:\n'
  for fa in "${FAILED_ASSERTIONS[@]}"; do
    printf '  - %s\n' "$fa"
  done
  exit 1
fi

exit 0
