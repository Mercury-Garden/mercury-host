# cron-recipes/x-digest-daily.md — declarative reference for the x-digest-daily cron
#
# This file is the source of truth for the x-digest-daily cron recipe
# live in `~/.hermes/cron/jobs.json` (id `59b7302d21b7`). The JSON
# entry itself is regenerated from this template by the cron-jobs.json
# sync process; any drift between this file and the live JSON entry
# is itself drift detection territory — see `scripts/audit.sh`'s cron section.
#
# Stage 5 of the Varlock plan (2026-07-21): x-digest-daily cuts over from
# `source .env` to `varlock run --inject vars --`. Before this change,
# secrets were loaded from `~/data/code/x-digest/.env` (mode 0600); after,
# they come from the host-local encrypted store at `~/.password-store/`,
# decrypted under GPG identity `1783B58858FD26D16D4BF58C490FE2DCACFEE578`
# (subkey `F7C29CD4E50186EF8B1BEFEAABE4E09A78765D16`).
#
# IMPORTANT:
#   - The .env file stays on disk during the Stage 5 observation window
#     (3 clean cron ticks). Stage 5.5 (post-observation) is what removes it.
#   - Until Stage 5.5 lands, the cron continues to source .env as a
#     fallback if varlock fails. After Stage 5.5, .env is removed and
#     varlock is the only path.
#   - The pre-flight in step 2 catches varlock-failure paths gracefully
#     (falls back to .env) before any pipeline work, so a broken
#     gpg-agent doesn't poison cron ticks.

## Schedule
`0 14 * * 1-5` — Mon–Fri 14:00 UTC (americas morning, europe afternoon,
no overlap with cron jobs from other agents).

## Steps

### Step 1 — `cd /home/ubuntu/data/code/x-digest`
Already in the canonical workdir per `cron.jobs.json#workdir`. No-op in practice.

### Step 2 — **Varlock preflight (NEW for Stage 5)**

```bash
# Verify varlock can resolve all 8 schema keys WITHOUT touching secrets
# (--agent redacts sensitive values). This catches gpg-agent / pass-store
# issues BEFORE we attempt the pipeline.
if ! varlock load --agent --skip-cache > /dev/null 2>&1; then
  echo "varlock preflight failed: gpg-agent or pass-store issue; falling back to .env"
  # Fallback to .env-restore (Stage 5 only; Stage 5.5 will instead exit loud)
  if ! [[ -f .env ]]; then
    bash ~/.hermes/scripts/restore-secrets.sh --env /home/ubuntu/data/code/x-digest/.env
  fi
  set -a; source .env; set +a
else
  # varlock works; let step 4 invoke pnpm under varlock run --inject vars
  export VARLOCK_INJECT=ok  # marker for step 4
fi
```

### Step 3 — **Removed** (was: `set -a && source .env && set +a`)
The old step 3 (the `set -a; source .env; set +a`) is **only** invoked
in the varlock-fallback path inside step 2. Stage 5.5 will remove this
fallback entirely.

### Step 4 — Run pipeline (NEW for Stage 5)

```bash
if [[ "$VARLOCK_INJECT" = "ok" ]]; then
  # Varlock path: secrets are decrypted under gpg-agent and exported into
  # the child's process.env. No `.env` reads happen.
  varlock run --inject vars --skip-cache -- pnpm run run
else
  # Fallback (Stage 5 only): old .env-sourcing behavior
  pnpm run run
fi
```

### Steps 5–9 — unchanged
The pipeline's stdout parsing, failure-handling rules, and "DO NOT
re-run" hard constraints from the original prompt are inherited verbatim.

## Why varlock run --inject vars (and not varlock load + wrapper)

`varlock run` is the documentation-supported wrapper for non-integrated
children. The pipeline reads its config from `process.env` at the top
of `run.ts` (NOT from `.env` files at runtime — `config.ts` was slimmed
in Stage 4 PR #17 to read from process.env only). So `varlock run`
injects the 8 resolved keys into the child's process.env and `run.ts`
picks them up unchanged.

If we used `varlock load` and exported manually, we'd lose the redaction
guarantees and have to hand-roll the `--agent` flag and `process.env`
injection — exactly what `varlock run` already does correctly.

## Rollback

If three cron ticks fail under the varlock path, regression:
```bash
# 1. restore the old cron prompt body (text below) to jobs.json
# 2. test with `bash /tmp/varlock-stage5-rollback.sh`
# 3. leave .env in place (Stage 5.5 doesn't fire)
```

Old prompt body's step 2:
```
2. Ensure .env exists. … if `ls .env` fails, run:
   `bash ~/.hermes/scripts/restore-secrets.sh --env /home/ubuntu/data/code/x-digest/.env`
3. Load env: `set -a && source .env && set +a`
4. Run: `pnpm run run`
```

These 3 lines are the original 2026-06-24 prompt — confirmed archived
in `cron-recipes/x-digest-daily.pre-2026-07-21.md`.
