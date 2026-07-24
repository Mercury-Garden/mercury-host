# OmniRoute coverage — known limitations & onboarding checklist (2026-07-24)

This is the host-side record for **OmniRoute coverage gaps discovered
during the 2026-07-24 audit** (post-install, after the 2026-07-23 dev-stack
entry landed). The audit caught three real gaps that the install path
didn't wire up. Two are now closed (PRs #103 + #105); one remains by
design.

This doc exists so the **next dev-stack entry** doesn't repeat the same
gap pattern. Each section mirrors the [varlock-known-issues](varlock-known-issues.md)
shape: Symptom → Root cause → Mitigation → Restore recipe.

## Summary by gap

| # | Gap | Class | Closed by | Notes |
|---|---|---|---|---|
| 1 | `~/.omniroute/` runtime state not in DR tarball | **Real data-loss hole** | PR #103 | Storage.sqlite + .env now in BACKUP_PATHS |
| 2 | `audit.sh` did not check omniroute service / vhost / runtime | **Real silent-drift hole** | PR #105 | 4 new audit checks fire under `[omniroute-state]` |
| 3 | Binary at `~/.local/share/pnpm/bin/omniroute` not in DR tarball | By design | n/a | Rebuildable via `pnpm add -g omniroute@<pin>`; excluded by `.local/share` symlink |
| 4 | `STORAGE_ENCRYPTION_KEY` in `~/.omniroute/.env` had no pointer in `secrets/inventory.yaml` | **Real secret-coverage hole** | PR #103 | New `omniroute-env` entry; key captured by `backup-secrets.sh` |

## A. Gap #1 — `~/.omniroute/` was not in the DR tarball (closed by PR #103)

### Symptom
The daily `mercury-state-YYYY-MM-DD.tar.zst` tarball (created by
`backup-mercury-state.sh`) did not capture `~/.omniroute/`. Result:
storage.sqlite (request history + provider config), call_logs, logs,
db_backups, and the `.env` file containing `STORAGE_ENCRYPTION_KEY`
were all unrecoverable from a cold restore.

### Root cause
The 2026-07-23 install added the omniroute binary + service + vhost +
landing-page card, but the install path did not touch
`backup-mercury-state.sh`'s `BACKUP_PATHS` array. The script was the
same as it was when omniroute didn't exist.

### Mitigation
PR #103 added:
- `BACKUP_PATHS` entry: `/home/ubuntu/.omniroute/.env` (with comment
  block explaining storage.sqlite semantics)
- `BACKUP_PATHS` entry: `/home/ubuntu/.omniroute` (the parent dir)
- `PRIVILEGED_PATHS` entry: `"home/ubuntu/.omniroute/.env"` so the
  post-archive verify step fails loud if the .env is missing

### Restore recipe (verified end-to-end)

```bash
# 1. Restore state tarball (now contains ~/.omniroute/)
tar --use-compress-program=zstd -xf mercury-state-YYYY-MM-DD.tar.zst -C /

# 2. Re-install binary (NOT in archive; rebuildable)
pnpm add -g omniroute@<pinned-version>   # version from inventory.yaml

# 3. Restore secret key
bash scripts/restore-secrets.sh --include omniroute   # writes ~/.omniroute/.env

# 4. Restart service
systemctl --user restart omniroute
```

## B. Gap #2 — `audit.sh` did not check omniroute (closed by PR #105)

### Symptom
The omniroute service was in `inventory.yaml#services[]` and the
vhost was in `inventory.yaml#nginx.enabled_vhosts`, but `audit.sh`'s
hardcoded lists (`for svc`, `for vhost`, `ACTIVE_SERVICES`) did not
include them. Result: if omniroute died or the vhost symlink was
removed, audit.sh reported clean. Same failure mode as the
hermes-dashboard 4-day outage (2026-07-05 → 2026-07-09) that
motivated the `ACTIVE_SERVICES` block.

### Root cause
Inventory.yaml was updated when omniroute was added (PR #96 + #97
arc), but `audit.sh` was not. The repo's standing rule is "single
PR per concern" so the install PR didn't touch the audit script;
the gap was discovered in the post-install audit on 2026-07-24.

### Mitigation
PR #105 added four drift checks:
1. **`[systemd-user]` list** — added `omniroute` to the `for svc`
   loop so the service being enabled is verified.
2. **`[active-services]` list** — added `user:omniroute` so the
   service actually running is verified (the hermes-dashboard
   silent-stale failure mode).
3. **`[nginx]` vhost list** — added `omniroute.mercury.garden` so
   the vhost symlink is verified.
4. **`[omniroute-state]` block** (new) — three sub-checks:
   - `~/.omniroute/.env` mode 0600 (STORAGE_ENCRYPTION_KEY not
     world-readable)
   - `~/.omniroute/storage.sqlite` freshness (mtime within
     `omniroute_state.max_age_hours`, default 48h) — catches
     "service alive but request loop stalled"
   - Advisory note if `storage.sqlite.corrupt-*` siblings exist
     in last 7 days (sqlite has crashed; investigate logs)

The configurability claim: `omniroute_state.max_age_hours` is read
from `inventory.yaml` and scopes only to that block (regex anchored
on `^omniroute_state:` line so it can't accidentally pick up
`state_backup.max_age_hours`).

### Restore recipe (if audit reports drift after PR #105)

| Drift | Cause | Fix |
|---|---|---|
| `~/.omniroute/.env mode $X (want 600)` | Wrong permissions on .env | `chmod 600 ~/.omniroute/.env` |
| `~/.omniroute/.env: MISSING` | Service wiped or never started | Re-run `backup-secrets.sh --force` and `restore-secrets.sh --include omniroute` |
| `~/.omniroute/storage.sqlite: STALE (Xh old)` | Request loop stalled or service died | `systemctl --user status omniroute`; restart if needed; investigate logs |
| `storage.sqlite.corrupt-* in last 7 days` | sqlite WAL corruption | Check `/var/log` + `~/.omniroute/logs/`; consider restarting service |

## C. Gap #3 — Binary not in DR tarball (by design, not closing)

### Symptom
`~/.local/share/pnpm/bin/omniroute` is NOT in the DR tarball. The
`~/.local/share` path is a symlink to `/home/ubuntu/data/.local/share`
(relocated 2026-07-05), and `backup-mercury-state.sh` excludes
`.local/share` from the tarball because of the (large) cache.

### Why this is OK
The binary is reproducible: `pnpm add -g omniroute@<pinned-version>`
re-creates it from the pnpm store cache + the version pin in
`inventory.yaml`. The same applies to every other pnpm-global
binary on the box (openchamber, future dev-stack entries).

### Mitigation
Restore recipe step 2 (in section A above) re-installs the binary.
Cost: ~30s + the download (the pin is the source of truth, so the
result is deterministic).

### Why this ISN'T gap #1
Gap #1 is `~/.omniroute/` (mutable runtime data: sqlite + logs + .env)
which is *not* rebuildable from a package install — that's the loss.
The binary itself is a stateless wrapper; re-installing it is fine.

## D. Gap #4 — `STORAGE_ENCRYPTION_KEY` had no secret pointer (closed by PR #103)

### Symptom
`secrets/inventory.yaml` had no entry for `~/.omniroute/.env`. Result:
- `backup-secrets.sh` did not capture the key to `~/.secrets/secrets.yaml`
- A bare-state-tarball restore could land the captured `.env` file but
  no canonical record of where it came from

### Mitigation
PR #103 added `omniroute-env` pointer to `secrets/inventory.yaml` with
purpose, location, rotation recipe, and two-layer recovery note.
PR #103 also wired the capture into `backup-secrets.sh` (`OR_ENV`
variable + `omniroute_env` b64 emission alongside `openchamber_startup_env`).

### Rotation recipe
```bash
# Lose the key deliberately (rotates the encryption):
rm -f ~/.omniroute/.env ~/.omniroute/storage.sqlite*
systemctl --user restart omniroute
# First launch will mint a fresh key + empty sqlite.
# ALL prior call history + provider config is lost.
```

This is a destructive single-character decision — do NOT automate.
Operator chooses.

## E. Onboarding checklist for the NEXT dev-stack entry

Mirror this list when adding any new pnpm-global binary to the box:

- [ ] `inventory.yaml#services[]` — add the systemd-user entry
- [ ] `inventory.yaml#nginx.enabled_vhosts` — add the vhost
- [ ] `scripts/audit.sh` — add to `for svc`, `ACTIVE_SERVICES`, `for vhost`
- [ ] `scripts/devtools-upgrade.ts` — add `auditXxx()` cron check
- [ ] `secrets/inventory.yaml` — declare ALL env-file pointers
- [ ] `scripts/backup-secrets.sh` — emit b64 blocks for every env file
- [ ] `scripts/backup-mercury-state.sh` — add to BACKUP_PATHS
- [ ] `mercury.garden/index.html` — add landing-page card
- [ ] Run `bash scripts/audit.sh` and verify NO new drift
- [ ] Run `bash scripts/backup-secrets.sh --force` and verify all
      new b64 blocks landed
- [ ] Inspect latest `mercury-state-*.tar.zst` to verify all new
      BACKUP_PATHS entries are present

Skipping any of these re-opens the gap pattern this doc captures.

## F. Cross-references

* PR #103 (`feat(backup): capture omniroute runtime state`):
  https://github.com/Mercury-Garden/mercury-host/pull/103
* PR #104 (sync-archive): https://github.com/Mercury-Garden/mercury-host/pull/104
* PR #105 (`feat(audit): omniroute coverage + known-issues`):
  https://github.com/Mercury-Garden/mercury-host/pull/105
* omniroute install arc (PRs #96 + #97):
  https://github.com/Mercury-Garden/mercury-host/pull/96 +
  https://github.com/Mercury-Garden/mercury-host/pull/97
* Live-host audit: `bash /home/ubuntu/data/code/mercury-host/scripts/audit.sh`
