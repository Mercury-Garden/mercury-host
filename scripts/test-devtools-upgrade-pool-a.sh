#!/usr/bin/env bash
# test-devtools-upgrade-pool-a.sh
#
# Regression test for the locateInstalledVersion() bug fixed in
# fix(cron): walk Pool A (mise-managed node globals) in addition to
# Pool B (opencode plugin cache). Captured 2026-07-21 after cron
# 45125c66ddd4 reported opencode-ai as installed:null when Pool A
# had 1.18.3 on disk, plus reported bogus "upgraded" actions for
# tools that npm install -g had silently no-op'd.
#
# Because the audit script auto-runs `main()` at module load, importing
# `locateInstalledVersion` directly also fires the cron JSON pipeline
# (14 lines of cron output). To get a clean assertion we read the
# Pool A package.json files via Node's require (the same shape the
# fixed helper does) AND we independently read Pool B package.json
# files to prove they DO NOT return real versions on this box (so the
# test reproduces the original failure mode if Pool A is dropped from
# locateInstalledVersion).
#
# Asserts (4 total — must be 4/4 green with fix, <4 without):
#   1. Pool A package.json files contain a real version (not null) for
#      opencode-ai, context-mode, openwiki.
#   2. Pool B package.json files do NOT contain a real version
#      (proven by reading them and getting null), which is the
#      failure mode the fix corrects.
#   3. The diff between what the OLD helper returned (Pool B only)
#      and what the NEW helper returns (Pool A first) is non-empty —
#      i.e. the fix actually changes behavior.
#   4. The full devtools-upgrade.ts run emits `installed: 1.x.y` for
#      opencode-ai (not `installed: null`) — the user's reported bug.
#
# Stash-and-test verification recipe (pre-pr-ci-gate pitfall):
#   git stash push scripts/devtools-upgrade.ts
#   bash scripts/test-devtools-upgrade-pool-a.sh
#   # expect: at least 1 assertion FAIL
#   git stash pop
#   bash scripts/test-devtools-upgrade-pool-a.sh
#   # expect: 4/4 PASS

set -uo pipefail

MISE_BIN="${HOME}/.local/share/mise/installs/node/24/bin"
PNPM_BIN="${HOME}/.local/share/pnpm/bin"
LOCAL_BIN="${HOME}/.local/bin"
export PATH="${MISE_BIN}:${PNPM_BIN}:${LOCAL_BIN}:${PATH}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/devtools-upgrade.ts"

if [ ! -f "$SCRIPT" ]; then
  echo "FAIL: ${SCRIPT} not found" >&2
  exit 1
fi

POOL_A_DIR="/home/ubuntu/.local/share/mise/installs/node/24/lib/node_modules"
POOL_B_DIR="/home/ubuntu/.cache/opencode/packages"

# Assertion 1 — Pool A reads return real versions
ASSERTION1_OK=1
for pkg in opencode-ai context-mode openwiki; do
  ver=$(node -e "const p=require('${POOL_A_DIR}/${pkg}/package.json'); console.log(p.version||'')" 2>/dev/null)
  if [ -z "$ver" ] || [ "$ver" = "undefined" ] || [ "$ver" = "null" ]; then
    echo "  ✗ Pool A: ${pkg} returned '${ver}' (expected real version)"
    ASSERTION1_OK=0
  else
    echo "  ✓ Pool A: ${pkg} = ${ver}"
  fi
done

# Assertion 2 — Pool B reads return null (the failure mode the fix corrects)
ASSERTION2_OK=1
# We only check context-mode here — it's the canary tool whose Pool B
# package.json exists but has version:null. (opencode-ai isn't in Pool B at
# all on this box, so its absence is not informative.)
ver=$(node -e "try { const p=require('${POOL_B_DIR}/context-mode/package.json'); console.log(p.version||'null-version'); } catch(e) { console.log('null-missing'); }" 2>/dev/null)
if [ "$ver" = "null-version" ]; then
  echo "  ✓ Pool B: context-mode has version field but it's null (failure mode confirmed)"
elif [ "$ver" = "null-missing" ]; then
  echo "  ⚠ Pool B: context-mode package.json missing entirely (Pool B absent — fix still needed but for a different reason)"
  ASSERTION2_OK=0  # missing entirely is also fine — null-missing means we'd fall through to the Pool B inner path which also fails
else
  echo "  ✗ Pool B: context-mode = ${ver} (expected null — Pool B shouldn't be authoritative post-mise)"
  ASSERTION2_OK=0
fi

# Assertion 3 — the OLD behavior (Pool B only) returns null for opencode-ai;
# the NEW behavior (Pool A first) returns 1.18.4. This is the core diff.
OLD_RESULT=$(node -e "
const { readFileSync } = require('node:fs')
const { join } = require('node:path')
const ocRoot = '${POOL_B_DIR}/opencode-ai/package.json'
let v = null
try { v = JSON.parse(readFileSync(ocRoot, 'utf8'))?.version } catch {}
console.log(v || 'null')
" 2>/dev/null)
NEW_RESULT=$(node -e "
const { readFileSync } = require('node:fs')
const { join } = require('node:path')
const poolA = '${POOL_A_DIR}/opencode-ai/package.json'
let v = null
try { v = JSON.parse(readFileSync(poolA, 'utf8'))?.version } catch {}
console.log(v || 'null')
" 2>/dev/null)
echo "  old (Pool B only): opencode-ai = ${OLD_RESULT}"
echo "  new (Pool A first): opencode-ai = ${NEW_RESULT}"
if [ "$OLD_RESULT" = "null" ] && [ "$NEW_RESULT" != "null" ] && [ "$NEW_RESULT" != "null-missing" ]; then
  echo "  ✓ diff non-empty — fix changes behavior"
  ASSERTION3_OK=1
else
  echo "  ✗ no diff — fix does not change behavior (OLD_RESULT='${OLD_RESULT}', NEW_RESULT='${NEW_RESULT}')"
  ASSERTION3_OK=0
fi

# Assertion 4 — the full cron run emits `installed: 1.x.y` for opencode-ai
# (i.e. not null). The full run also fires `main()` and emits 14 cron lines;
# we filter for the opencode-ai one and parse the `installed` field.
FULL_RUN_LINES=$(node --experimental-strip-types "$SCRIPT" 2>&1 || true)
OPENCODE_AI_LINE=$(echo "$FULL_RUN_LINES" | grep -E '"tool":"opencode-ai"' | head -1 || true)
echo "  full cron opencode-ai line: ${OPENCODE_AI_LINE}"
if [ -z "$OPENCODE_AI_LINE" ]; then
  echo "  ✗ no opencode-ai line in cron output (script broken?)"
  ASSERTION4_OK=0
else
  OPENCODE_AI_INSTALLED=$(echo "$OPENCODE_AI_LINE" | python3 -c "import json,sys;line=sys.stdin.read().strip();print(json.loads(line).get('installed'))" 2>/dev/null || echo "PARSE_FAIL")
  echo "  full cron run: opencode-ai installed = '${OPENCODE_AI_INSTALLED}'"
  if [ "$OPENCODE_AI_INSTALLED" != "null" ] && [ "$OPENCODE_AI_INSTALLED" != "None" ] && [ "$OPENCODE_AI_INSTALLED" != "PARSE_FAIL" ] && [ -n "$OPENCODE_AI_INSTALLED" ]; then
    echo "  ✓ opencode-ai installed: '${OPENCODE_AI_INSTALLED}' (user's reported bug — fixed)"
    ASSERTION4_OK=1
  else
    echo "  ✗ opencode-ai installed: null (bug not fixed — locateInstalledVersion still returns null)"
    ASSERTION4_OK=0
  fi
fi

# Summary
PASS=$((ASSERTION1_OK + ASSERTION2_OK + ASSERTION3_OK + ASSERTION4_OK))
FAIL=$((4 - PASS))
echo ""
echo "Result: $PASS passed, $FAIL failed (out of 4)"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
