# backup-omniroute-runtime

**Status:** arc complete (merged 2026-07-24).
**Source PR:** [#103](https://github.com/Mercury-Garden/mercury-host/pull/103) —
`feat(backup): capture omniroute runtime state + declare STORAGE_ENCRYPTION_KEY`.
**Merged as:** `534a7af` on `main` (squash, branch `feat/backup-omniroute-runtime`
auto-deleted).
**Follows:** PR #97 (`spec(sync-and-archive): archive omniroute first dev-stack entry`)
+ PR #97's underlying `feat/omniroute-first-dev-stack` which installed the
`omniroute` service on 2026-07-23. This change closes the **gap analysis** that the
2026-07-24 omniroute-coverage audit surfaced (gap #1 + gap #3: the daily state
tarball did not capture `~/.omniroute/`, and the `STORAGE_ENCRYPTION_KEY` was not
in the secrets backup).

## Deliverable

Three files, +37 lines, single-purpose: make the omniroute install **restorable
from cold**, including the at-rest-encrypted `storage.sqlite`.

1. **`scripts/backup-mercury-state.sh`** (+13 lines) — append `/home/ubuntu/.omniroute/`
   + `~/.omniroute/.env` to `BACKUP_PATHS` and to `PRIVILEGED_PATHS`. Mirrors the
   openchamber pattern (`openchamber-startup-env` has both the per-project `.env`
   entry AND its parent dir listed separately). The `~/.omniroute/.env` entry
   captures the `STORAGE_ENCRYPTION_KEY` so the captured `storage.sqlite` can be
   decrypted on restore.

2. **`scripts/backup-secrets.sh`** (+9 lines) — new `OR_ENV` variable + new
   `omniroute_env` b64 emission block alongside `openchamber_startup_env`. The b64
   payload is emitted into `~/.secrets/secrets.yaml` next to other per-service env
   blocks. Validated end-to-end during PR #103 review: `--force` landed the
   `omniroute_env` block at `~/.secrets/secrets.yaml:764`, file mode 0600.

3. **`secrets/inventory.yaml`** (+15 lines) — new `omniroute-env` pointer with
   purpose, location, rotation recipe (delete `.env` + sqlite, restart service,
   history lost), and a two-layer recovery note: the `STORAGE_ENCRYPTION_KEY` is
   in `~/.secrets/secrets.yaml` (encrypted on disk + off-host bundle) and the
   encrypted blob is in `~/.omniroute/storage.sqlite` (encrypted at rest by the
   key). Both layers must be present for recovery; restoring one without the
   other yields a non-functional service.

## Restore path (verified during PR #103 review)

```bash
# 1. Restore state tarball (now contains ~/.omniroute/)
tar --use-compress-program=zstd -xf mercury-state-YYYY-MM-DD.tar.zst -C /

# 2. Re-install binary (rebuildable; not in archive)
pnpm add -g omniroute@<pinned-version>   # from inventory.yaml pin

# 3. Restore secret key
bash scripts/restore-secrets.sh --include omniroute   # writes ~/.omniroute/.env

# 4. Restart service
systemctl --user restart omniroute
```

## Verification (captured in PR #103 body, all run on this host)

| Gate | Result |
|---|---|
| `yamllint -c .yamllint.yml --strict .` | rc=0 |
| `shellcheck scripts/*.sh` (both modified scripts) | rc=0 |
| `gitleaks detect --no-git --redact --exit-code 1 .` | 0 leaks |
| `bash -n` parse of both scripts | ok |
| `bash scripts/backup-secrets.sh --force` | landed `omniroute_env` block at `~/.secrets/secrets.yaml:764`, mode 0600 |
| `bash scripts/backup-mercury-state.sh` parse | 29 BACKUP_PATHS entries (was 24 → 27 effective with the 2 new explicit entries + parent dir) |
| `bash scripts/audit.sh` | same 2 pre-existing drift items (hermes-dashboard inactive + Jul 22 backup gap), **no new regressions** |

The repo's full CI gate is `yamllint → shellcheck → gitleaks → bash scripts/audit.sh || true`
(matches `.github/workflows/validate.yml`). No additional test surface required — this
PR touches scripts that the lint + gitleaks + audit gates already cover.

## What this does NOT cover (separate PRs in the same omniroute arc)

- PR #2: `scripts/audit.sh` doesn't yet know `omniroute` is a service that should
  be `active`, nor that `omniroute.mercury.garden` is a vhost that should resolve.
  The next arc PR fixes that.
- PR #3: Known-issues doc capturing the gap history so the next dev-stack entry
  doesn't repeat the same omission.

These are not in scope for this archive — they live in their own PRs.

## Arc-shape note (important)

**This stage did not follow the standard spec → feat → sync-and-archive template.**
The standard template is:
1. `openspec/changes/<name>/proposal.md` + `tasks.md` + `spec.md`
2. `feat/<name>` PR with implementation
3. `spec/sync-and-archive-<name>` PR after `pnpm openspec archive`

This change followed the **shortcut shape** (same as PR #92 / varlock-stage8-consolidate,
PR #97 / omniroute-first-dev-stack, and PR #101 / openviking-migrate-to-openrouter):
1. Open `feat/backup-omniroute-runtime` directly with the implementation
2. Squash-merge on approval
3. Sync-and-archive PR contains a real-record archive README documenting the
   deviation (this file), not a fabricated `pnpm openspec archive` output

The shortcut shape is appropriate here because:
- The change is a **gap fix** (3 files, +37 lines, single-purpose, fully reversible
  by reverting the 3 deletions), not a new capability — a full spec/feat/archive
  cycle would be ceremony disproportionate to the change.
- The spec artifacts (the 2026-07-24 omniroute-coverage audit listing gap #1 + gap #3)
  live in a separate doc, not under `openspec/changes/`. The audit doc is the
  source of truth for what the gap was; this PR is the closure.
- The PR body itself is structurally a spec: explicit "Why" (the gap), explicit
  "What changes" (3 files, line counts), explicit "Verification" (7 gates with
  results), explicit "What this does NOT cover" (out-of-scope follow-ups), and
  the restore path with copy-paste commands. Reviewers can audit the change
  surface from the PR body alone.

If the next change of this shape needs a fuller spec phase, open one — the arc
driver is happy to handle either template. The trigger for opening a spec PR is
"the change introduces new state that an on-call reader needs explained before
they can triage it"; this PR did not.
