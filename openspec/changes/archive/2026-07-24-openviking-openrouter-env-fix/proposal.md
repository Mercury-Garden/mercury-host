# OpenViking — inject OPENROUTER_API_KEY into openviking-server (PR #107)

## Task Signature

PR #101 (OpenViking → OpenRouter migration) updated `~/.openviking/ov.conf`
to use `${OPENROUTER_API_KEY}` env-var substitution for both embedding
and VLM providers, but the systemd unit `~/.config/systemd/user/openviking-server.service`
was not updated to actually export that env var into the OpenViking
process. Result: the live server has been running **without OpenRouter
auth** since the migration landed.

It happened to keep working because OpenRouter's free-tier routing for
`qwen/qwen3-embedding-8b` answers without strict auth in the cases
OpenViking's `embedding.dense` path probes, but the contract is broken:
any provider route that requires strict auth (paid tier, stricter
free-tier limits, future providers) will return **401** and OpenViking
embedding/VLM calls will silently fail or fall back to no-op responses.

Fix scope is narrow: get `OPENROUTER_API_KEY` from `~/.hermes/.env` into
the OpenViking process via a small `ExecStartPre=` materialization step
+ a single-key `EnvironmentFile=`, without inlining the key value in
the systemd unit file (preserves the env-as-secrets discipline).

## Input

- `~/.openviking/ov.conf` on `main` already uses `${OPENROUTER_API_KEY}`
  substitution (PR #101, merged 2026-07-24T04:11:22Z as commit `2ab6257`).
- `~/.hermes/.env` carries the canonical `OPENROUTER_API_KEY` value
  (OpenRouter provider key, mode 0600).
- The current systemd unit `~/.config/systemd/user/openviking-server.service`
  is a symlink to `systemd/user/openviking-server.service` in this repo.
  Pre-fix, the unit's `ExecStart=` line was:
  ```
  ExecStart=/home/ubuntu/.hermes/hermes-agent/venv/bin/openviking-server
  ```
  with no `EnvironmentFile=` for OpenRouter auth.

## Root cause (one paragraph for the archive record)

The PR #101 migration was scoped to **config file** edits (`ov.conf`),
not to **runtime plumbing** (systemd unit). The audit-sh gap that
caught this was the *absence* of a drift check that would have flagged
"OpenViking is running but its auth is broken" — there was no such
check because audit.sh's `[openviking-server]` block only checks the
service is `active` and the port is bound, not the auth handshake.

A better long-term fix would be a drift check like
`curl http://127.0.0.1:1933/api/v1/health/auth` returning 200, or an
`openviking-server doctor` exit-0 probe in audit.sh. Out of scope
for this PR; tracked as a follow-up.

## Rubric

```json
{
  "name": "openviking-openrouter-env-fix",
  "description": "Inject OPENROUTER_API_KEY into the openviking-server systemd process via a single-key materialization step (no key in unit file).",
  "criteria": [
    {
      "name": "openrouter_env_file_materialized",
      "description": "After restart, ~/.openviking/.openrouter-env exists with mode 0600 and contains a valid 73-char OPENROUTER_API_KEY line.",
      "required": true,
      "weight": 1.0
    },
    {
      "name": "unit_consumes_env_file",
      "description": "systemd unit has EnvironmentFile=%h/.openviking/.openrouter-env AND ExecStartPre runs the materialize script.",
      "required": true,
      "weight": 1.0
    },
    {
      "name": "openviking_healthy_post_restart",
      "description": "After restart, /health returns {status:ok, healthy:true, auth_mode:dev} AND embedding probe returns a valid vector (length 4096).",
      "required": true,
      "weight": 1.0
    },
    {
      "name": "no_key_in_unit_file",
      "description": "systemd/user/openviking-server.service does NOT contain a literal sk-or-v1- key value (gitleaks clean).",
      "required": true,
      "weight": 1.0
    }
  ]
}
```

## Approach

1. **New file** `systemd/user/openviking-prepare-openrouter-env.sh`
   (mode 0755) — bash script that materializes a single-key tempfile
   at `~/.openviking/.openrouter-env` (mode 0600) from `~/.hermes/.env`.
   Idempotent; re-runs just refresh the tempfile.

2. **Modified** `systemd/user/openviking-server.service`:
   - Add `ExecStartPre=%h/.openviking/openviking-prepare-openrouter-env.sh`
   - Add `EnvironmentFile=%h/.openviking/.openrouter-env`
   - Keep `ExecStart=` and `WorkingDirectory=` as before

3. **The systemd unit is symlinked** from
   `/etc/systemd/system/hermes-dashboard.service`-style `~/.config/systemd/user/`,
   so a `systemctl --user daemon-reload && systemctl --user restart openviking-server`
   picks up the new unit file (which itself was synced by the repo pull
   + git push).

4. **No secrets leave the machine** — the materialize script sources
   `~/.hermes/.env`, writes the tempfile under the user's home dir,
   and the systemd unit only references the tempfile path (not the key).
   `gitleaks detect --no-git --redact --exit-code 1 .` passes.

5. **No backup-secrets change needed** — `~/.openviking/.openrouter-env`
   is rewritten on every restart by the prepare script (deterministic
   from `~/.hermes/.env`), so it does NOT need to be in
   `~/.secrets/secrets.yaml`. The existing `openviking_ov_conf` block
   already captures `~/.openviking/ov.conf`, which is the authoritative
   config file (this PR does not change ov.conf).

## Evidence

**Pre-fix:**
- OpenViking service active, but `~/.openviking/.openrouter-env` did not exist
- The `${OPENROUTER_API_KEY}` substitution in `ov.conf` resolved to empty string
- Embedding probes succeeded by luck on free-tier routes

**Post-fix (verified end-to-end on 2026-07-24 after merge):**
```
$ ls -la /home/ubuntu/.openviking/.openrouter-env
-rw------- 1 ubuntu ubuntu 93 Jul 24 04:39 /home/ubuntu/.openviking/.openrouter-env

$ systemctl --user status openviking-server
● openviking-server.service - OpenViking context database server (local)
     Active: active (running) since Fri 2026-07-24 04:39:24 UTC
    Process: 55215 ExecStartPre=/home/ubuntu/.openviking/openviking-prepare-openrouter-env.sh
                                                  (code=exited, status=0/SUCCESS)

$ curl -sS http://127.0.0.1:1933/health
{"status":"ok","healthy":true,"version":"0.4.10","auth_mode":"dev"}
```

## Linked Experiences

- **Parent arc** — `openspec/changes/archive/2026-07-24-2026-07-24-openviking-migrate-to-openrouter/`
  (PR #101: `feat(openviking): migrate embedding + VLM to OpenRouter`).
  This fix (#107) is the **second step** of the OpenRouter migration —
  the config-file half shipped first, the runtime plumbing shipped
  ~38 min later when the auth-broken state was diagnosed.

- **Future follow-up** — adding an `openviking-server doctor` drift
  check to `audit.sh` would have caught this sooner. The rubric
  criterion `openviking_healthy_post_restart` would be promoted to
  an audit check that fires `curl /health` + asserts `auth_mode`
  matches the configured provider. Estimated scope: ~20 lines in
  `[openviking-server]` block.

## Cross-references

- PR #107: https://github.com/Mercury-Garden/mercury-host/pull/107
  (squash merged 2026-07-24T04:49:16Z as `b49b009`)
- PR #101: https://github.com/Mercury-Garden/mercury-host/pull/101
  (the parent migration arc)
- PR #102: https://github.com/Mercury-Garden/mercury-host/pull/102
  (sync-and-archive wrapper for #101)
