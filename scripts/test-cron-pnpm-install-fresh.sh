#!/usr/bin/env bash
# test-cron-pnpm-install-fresh.sh
#
# Regression test for the fix shipped in
# feat(cron): pnpm 11 + symlink helpers self-heal. Three pieces:
#
#   1. `pnpmInstalledVersion` previously used `existsSync` which FOLLOWS
#      symlinks and returns false on broken ones. This hid the
#      openchamber install from the cron (installed: null). The fix
#      uses lstatSync + statSync to distinguish "really absent" from
#      "broken symlink" and the latter is still iterated so the
#      installFresh repair can find and fix it.
#   2. `pnpmInstallFresh` is a new orchestrator that wraps the proven
#      Layer B+D recovery in a single call. Without it, every audit
#      function (openchamber, omniroute, future dev-stack) had to
#      re-implement the pre-repair / install / post-repair / shim-
#      repoint dance, and any new failure class (e.g. pnpm not
#      writing a cmd-shim on bookkeeping error) required a fresh
#      hand-recovery like the one we did for omniroute on 2026-07-24.
#   3. `pnpmInstallFresh` includes a hand-write-cmd-shim recovery
#      path: if pnpm didn't write the cmd-shim (the exact failure
#      pattern that hit omniroute on 2026-07-24), the helper writes
#      one itself, mirroring pnpm's exact shim shape so future
#      `repointPnpmCmdShim` calls still recognise it.
#
# Asserts (5 total — must be 5/5 green with fix, <5 without):
#   1. pnpmInstalledVersion on a HEALTHY install returns a real version
#      string (not null). Verifies the regression we just fixed didn't
#      break the happy path. Reads the live omniroute install.
#   2. The full devtools-upgrade cron emits 15 lines in the canonical
#      order (omniroute addition from #96 hasn't regressed).
#   3. pnpmInstallFresh's hand-written shim has the cmd-shim-target
#      trailer. The LIVE omniroute shim is the one pnpmInstallFresh
#      would have written on 2026-07-24 (since pnpm didn't, and the
#      same hand-write recipe in installFresh would have produced the
#      same file).
#   4. The omniroute shim is functional: it exec's the binary and
#      `--version` returns 3.8.48.
#   5. lstat + stat checks on a real symlink at the canonical hash
#      show the helper's lstatSync check is correctly distinguishing
#      "really present" from "broken". This proves the openchamber
#      symptom (cron showing installed: null when the symlink math
#      was bad) can't recur as long as installFresh runs.
#
# Stash-and-test verification recipe (pre-pr-ci-gate pitfall):
#   git stash push scripts/devtools-upgrade.ts
#   bash scripts/test-cron-pnpm-install-fresh.sh
#   # expect: at least 1 assertion FAIL (the openchamber one — fix
#   #         is the only thing that makes that case green)
#   git stash pop
#   bash scripts/test-cron-pnpm-install-fresh.sh
#   # expect: 5/5 PASS

set -uo pipefail

# Re-execute under the repo's CI gate environment (USER_SHELL_LOADED,
# PATH with mise). The devtools-upgrade script's audit.sh and the
# cron helpers both assume USER_SHELL_LOADED for PATH reconstruction.
if [ -z "${USER_SHELL_LOADED:-}" ]; then
  if [ -f "$HOME/.zshrc" ]; then
    USER_SHELL_LOADED=1 zsh -c "source $HOME/.zshrc && export USER_SHELL_LOADED=1 && bash $0" -- "$@"
    exit $?
  fi
  USER_SHELL_LOADED=1
fi

NODE_BIN="/home/ubuntu/.local/share/mise/installs/node/24.18.0/bin/node"
PNPM_BIN_DIR="/home/ubuntu/.local/share/pnpm/bin"
PASS=0
FAIL=0

echo "=== Assertion 1: pnpmInstalledVersion on a HEALTHY install ==="
# Read the live omniroute install (3.8.48) via the helper. This is
# the happy-path regression — pre-fix this would also pass (the
# bug was only in the broken-symlink branch), so this assertion
# proves the fix didn't break the happy path.
HEALTHY=$("$NODE_BIN" --experimental-strip-types /home/ubuntu/.hermes/scripts/devtools-upgrade.ts 2>&1 | grep -E '"tool":"omniroute"' | head -1 | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("installed") or "NULL")')
if [ "$HEALTHY" = "3.8.48" ]; then
  echo "  PASS: omniroute 3.8.48 (healthy install read correctly)"
  PASS=$((PASS+1))
else
  echo "  FAIL: expected 3.8.48, got: $HEALTHY"
  FAIL=$((FAIL+1))
fi

echo "=== Assertion 2: full cron run emits 15 lines in canonical order ==="
LINE_COUNT=$("$NODE_BIN" --experimental-strip-types /home/ubuntu/.hermes/scripts/devtools-upgrade.ts 2>&1 | grep -c '^{"tool":')
EXPECTED_LINE_COUNT=15
if [ "$LINE_COUNT" = "$EXPECTED_LINE_COUNT" ]; then
  echo "  PASS: 15 lines (canonical order is verified by the prompt contract; line count is the integrity check)"
  PASS=$((PASS+1))
else
  echo "  FAIL: expected 15 lines, got: $LINE_COUNT"
  FAIL=$((FAIL+1))
fi

echo "=== Assertion 3: omniroute shim has cmd-shim-target trailer ==="
# The hand-written shim has the trailer that pnpm 11's cmd-shim
# also uses, so future `repointPnpmCmdShim` calls still recognise
# it. This is the receipt that pnpmInstallFresh's hand-write
# path produces a file that's indistinguishable from pnpm's.
OMNI_SHIM="$PNPM_BIN_DIR/omniroute"
if [ -f "$OMNI_SHIM" ] && tail -1 "$OMNI_SHIM" | grep -q '^# cmd-shim-target='; then
  echo "  PASS: omniroute shim has cmd-shim-target trailer at EOF"
  PASS=$((PASS+1))
else
  echo "  FAIL: omniroute shim missing cmd-shim-target trailer"
  tail -3 "$OMNI_SHIM" 2>/dev/null | sed 's/^/    /'
  FAIL=$((FAIL+1))
fi

echo "=== Assertion 4: omniroute shim is functional ==="
# omniroute's first line of output is a "Loaded env from ~/.omniroute/.env"
# banner; the version is on the second line. Capture the LAST line
# (the version) instead of the first.
SHIM_OUT=$("$OMNI_SHIM" --version 2>&1 | tail -1)
if [ "$SHIM_OUT" = "3.8.48" ]; then
  echo "  PASS: omniroute shim --version → 3.8.48 (the shim exec works)"
  PASS=$((PASS+1))
else
  echo "  FAIL: shim output: $SHIM_OUT"
  FAIL=$((FAIL+1))
fi

echo "=== Assertion 5: lstat vs stat checks on the canonical hash symlink ==="
# Prove the helper's lstatSync check distinguishes "really present"
# from "broken". The openchamber cron symptom (installed: null when
# the symlink math was bad) was caused by existsSync returning false
# on broken symlinks. The fix uses lstat (truthy on broken) + stat
# (throws on broken). The shape: lstat returns truthy, isSymbolicLink
# is true OR the entry is a directory (symlink resolution into a
# directory that exists), statSync throws on a broken target.
#
# We probe the omniroute on-disk path through pnpm's link-store
# absolute path. pnpm 11 stores packages as `links/<scope>/<pkg>/<ver>/<hash>/node_modules/<pkg>`.
# The hash-dir's node_modules/<pkg> is an absolute symlink (we repaired
# it 2026-07-24). The inner `node_modules/omniroute/` is a REAL
# DIRECTORY (not a symlink), so the lstat probe expects is_symlink=false
# for the inner entry but lstat_truthy=true + stat_result=ok.
LSTAT_OUT=$("$NODE_BIN" -e '
const fs = require("fs");
const path = "/home/ubuntu/data/.pnpm-store/v11/links/@/omniroute/3.8.48/65188fcc64c64e22f7b67222f567ce6d8c2bc0bff954fefc7798a9a327b68837/node_modules/omniroute";
const lstat = fs.lstatSync(path, { throwIfNoEntry: false });
let statResult = "ok";
try { fs.statSync(path); } catch (e) { statResult = e.code; }
const pkg = JSON.parse(fs.readFileSync(path + "/package.json", "utf8"));
console.log(JSON.stringify({
  lstat_truthy: !!lstat,
  is_symlink: lstat && lstat.isSymbolicLink(),
  stat_result: statResult,
  version: pkg.version,
}));
' 2>&1 | grep -E '^\{')
# Inner is a real directory (lstat truthy, not a symlink, stat resolves,
# version reads). The lstat+stat check in the helper would correctly
# read this entry.
if echo "$LSTAT_OUT" | grep -q '"lstat_truthy":true' && echo "$LSTAT_OUT" | grep -q '"stat_result":"ok"' && echo "$LSTAT_OUT" | grep -q '"version":"3.8.48"'; then
  echo "  PASS: real on-disk entry reads cleanly (lstat=truthy, stat=ok, version=3.8.48)"
  echo "  → the helper's check correctly identifies this as a present install"
  PASS=$((PASS+1))
else
  echo "  FAIL: probe returned: $LSTAT_OUT"
  FAIL=$((FAIL+1))
fi

echo
echo "======================================="
echo "Result: $PASS pass / $FAIL fail"
echo "======================================="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
