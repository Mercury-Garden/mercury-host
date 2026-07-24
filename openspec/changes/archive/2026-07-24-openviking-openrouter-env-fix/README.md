# openviking-openrouter-env-fix

**Status:** arc complete (merged 2026-07-24).
**Source PR:** [#107](https://github.com/Mercury-Garden/mercury-host/pull/107) —
`fix(systemd): inject OPENROUTER_API_KEY into openviking-server`.
**Merged as:** `b49b009` on `main` (squash).
**Follows:** PR #101 (`feat(openviking): migrate embedding + VLM to OpenRouter`)
+ PR #102 (`spec(sync-and-archive): archive openviking-migrate-to-openrouter`).
This change is the **runtime-plumbing half** of the OpenRouter migration:
PR #101 swapped the config file (`ov.conf`) to use `${OPENROUTER_API_KEY}`
substitution, but the systemd unit was never updated to actually export
that env var into the OpenViking process. PR #107 closes the gap.

## What it fixes

The OpenViking context database server (`openviking-server` on
`127.0.0.1:1933`, backed by `memory.mercury.garden`) had been running
**without OpenRouter auth** since PR #101 merged at 2026-07-24T04:11:22Z.
Embedding probes succeeded only because OpenRouter's free-tier routing
for `qwen/qwen3-embedding-8b` answers without strict auth in the
common cases OpenViking probes. The contract was broken: any
auth-required provider route would 401 and silently fail.

## Deliverable

Two files, +36 / -3 lines:

1. **`systemd/user/openviking-prepare-openrouter-env.sh`** (new, 24 lines,
   mode 0755) — bash script that materializes a single-key tempfile at
   `~/.openviking/.openrouter-env` (mode 0600) from `~/.hermes/.env`.
   Idempotent; re-runs just refresh the tempfile.

2. **`systemd/user/openviking-server.service`** (+12 / -3 lines) — adds
   `ExecStartPre=` for the materialize script and `EnvironmentFile=` for
   the tempfile, with an inline comment explaining the design choice
   (env-as-secrets discipline preserved: no key value in unit file).

## Restore recipe (verified end-to-end)

```bash
# 1. Restore the unit file (rebuildable from repo)
git checkout main && git pull --ff-only origin main
# ~/.config/systemd/user/openviking-server.service is a symlink to
# this repo's systemd/user/openviking-server.service; the pull
# updates the symlink target.

# 2. Restore the materialize script (also in repo)
# auto-picked-up by the unit's ExecStartPre=

# 3. Reload + restart
systemctl --user daemon-reload
systemctl --user restart openviking-server

# 4. Verify
ls -la ~/.openviking/.openrouter-env   # mode 0600, 93 bytes
curl http://127.0.0.1:1933/health     # {"status":"ok","healthy":true,...}
```

## Out-of-scope follow-ups (tracked but not in this PR)

- **audit.sh drift check** — adding `curl /health` + assert `auth_mode`
  match to `[openviking-server]` block would have caught this sooner.
  Rubric criterion `openviking_healthy_post_restart` becomes the audit
  check. ~20 lines, single PR.
- **OpenViking 0.4.10 semantic search bug** — `/api/v1/search/search`
  returns 0 hits despite 10 valid Qwen embeddings (norm 1.0) in the
  vector store. Content-truncation or threshold-filter bug, not auth.
  Tracked separately; embedding + storage paths healthy.

## Cross-references

- PR #107: https://github.com/Mercury-Garden/mercury-host/pull/107
- Parent arc PR #101: https://github.com/Mercury-Garden/mercury-host/pull/101
- Parent sync-and-archive PR #102: https://github.com/Mercury-Garden/mercury-host/pull/102
- Archive dir parent: `openspec/changes/archive/2026-07-24-2026-07-24-openviking-migrate-to-openrouter/`
