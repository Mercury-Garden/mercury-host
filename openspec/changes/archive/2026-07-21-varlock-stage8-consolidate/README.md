# Archive: varlock-stage8-consolidate

**Status:** arc stage 8 — consolidate (post-migration retirement of the
legacy `.env`-input path) — complete (merged 2026-07-21).
**Source PR:** [#92](https://github.com/Mercury-Garden/mercury-host/pull/92) —
`feat(varlock): Stage 8 — consolidate (audit-script check + rotation
policy + restore-drill + .env.schema mode)`.
**Merged as:** `fb1ed98` on `main` (squash, branch auto-deleted).
**Follows:** Stage 7 (the `feat/varlock-stage5-x-digest-cron-cutover`
+ sync-and-archive arc that closed Stages 5–7). Stage 8 is the
post-migration consolidation delivered directly as a `feat:` PR — see
"Arc-shape note" below.

## Deliverable

Stage 8 of the varlock plan, **consolidation of the post-migration
state**. Five deliverables in a single PR:

1. **`scripts/audit.sh`** — new `[varlock-migrated-repos]` section that
   checks every migrated repo's `.env.schema` parses AND
   `varlock load --agent --skip-cache` returns rc=0. Currently 3/3
   healthy (`x-digest`, `better-bet`, `scriptcaster`). Also excludes
   `.env.schema` from the auto-discovered `*.env*` mode-600 check
   (the schema is not a secret-bearing file — only the resolved
   `.env` produced by `varlock run --inject vars` is).

2. **`secrets/varlock-rotation.md`** (new, ~250 lines) — the rotation
   & offboarding procedure doc. Covers: full key rotation (mint new
   identity, re-encrypt all entries, re-mint recovery bundle),
   scheduled key-refresh schedule (default 2y, annual recommended),
   total-loss scenarios (off-host bundle is the unlock),
   migration-era retention policy (30 days for `secrets.yaml`;
   indefinite for off-host bundle), and the test surface (which
   scripts prove what).

3. **`scripts/test-varlock-stage8-restore-drill.sh`** (new, ~115
   lines) — restores `~/.gnupg/*` and `~/.password-store/*` to a
   synthetic HOME and verifies: (a) canary decrypts from a cold
   gpg-agent in the synthetic HOME, (b) each of the three migrated
   repos' `.env.schema` resolves, (c) cold-decrypt works after
   `gpgconf --kill gpg-agent && gpgconf --launch gpg-agent`. This
   complements `test-varlock-backup-restore.sh` (tar + restore
   cycle, the store-level test); Stage 8 is the per-repository
   smoke.

4. **`AGENTS.md`** (+25 lines) — documents the "varlock + pass =
   manual upgrade policy" (deliberate exclusion from
   `devtools-upgrade.ts`'s auto-upgrade loop because both have
   manual-review requirements). Includes the manual upgrade recipe
   (apt for pass, sha256-verified tarball for varlock).

5. **`cron-recipes/x-digest-daily.md`** — Stage 5.5 follow-up:
   removes the legacy `.env` fallback block. Step 2 now exits loud
   on varlock failure rather than silently restoring plaintext.
   The removed code is preserved in step 2a's comment block for
   posterity / rollback.

## Verification (captured in PR #92 body, all run on this host)

| Check | Result |
|---|---|
| `yamllint -c .yamllint.yml --strict .` | rc=0 |
| `shellcheck scripts/*.sh` (warning mode) | rc=0 |
| `gitleaks detect --no-git --redact --exit-code 1 .` | 0 leaks |
| `bash scripts/audit.sh` | `✓ no drift` |
| `bash scripts/test-varlock-stage8-restore-drill.sh` | rc=0, 3/3 repos |

The repo's full CI gate is `yamllint → shellcheck → gitleaks → bash
scripts/audit.sh || true` (matches `.github/workflows/validate.yml`).
No additional test surface required for this PR — it touches scripts,
cron recipe docs, AGENTS.md, and a new secrets-rotation doc, all of
which the lint + gitleaks + audit gates already cover.

## Arc-shape note (important)

**This stage did not follow the standard spec → feat → sync-and-archive
template.** All earlier varlock stages (1, 2, 3) were:
1. `openspec/changes/<name>/proposal.md` + `tasks.md` + `spec.md`
2. `feat/<name>` PR with implementation
3. `spec/sync-and-archive-<name>` PR after `pnpm openspec archive`

Stage 8 was an **aggregation of post-migration polish items** delivered
directly as `feat/varlock-stage8-consolidate` (PR #92). There was no
prior `openspec/changes/varlock-stage8-consolidate/` directory on
disk, and `pnpm openspec archive` would have had nothing to move.

This README exists to:
1. **Record the arc closure** so the next person searching for
   "what was Stage 8" finds a coherent artifact under
   `openspec/changes/archive/`, alongside Stages 1/2/3.
2. **Acknowledge the deviation** explicitly, so the
   `mercury-tasks` / `webhook-server` / `mercury.garden` agents (and
   the controller) understand that "no prior spec PR" is intentional
   for Stage 8, not an oversight.
3. **Provide the linkage** from this archive back to the source PR
   (#92) and forward to the open follow-ups (Stage 8.1, 8.6 — see
   PR #92's "Out of scope" section).

If a future stage follows the standard spec → feat → sync-and-archive
flow, this README is the template that gets superseded by the new
archive README — not edited in place.

## Files archived

- `AGENTS.md` (+25 lines, manual-upgrade-policy section)
- `cron-recipes/x-digest-daily.md` (Stage 5.5 cleanup — legacy `.env`
  fallback removed, preserved in comment)
- `scripts/audit.sh` (+35 lines, `[varlock-migrated-repos]` section +
  `.env.schema` mode check exclusion)
- `scripts/test-varlock-stage8-restore-drill.sh` (new, 150 lines
  final, mode 0755)
- `secrets/varlock-rotation.md` (new, 229 lines final)

5 files, +480 insertions / -6 deletions on `main` after merge.

## Open follow-ups (per PR #92 "Out of scope")

- **Stage 8.1** — CI workflows for `x-digest`, `better-bet`,
  `scriptcaster` (lint + test + config:check + secrets:scan). One PR
  per repo.
- **Stage 8.6** — `AGENTS.md` post-migration updates on the three
  project repos. One PR per repo.
- **Stage 5.5 explicit declaration** — already succeeded on
  `x-digest` 2026-07-21 (PR #88 + #89). Pending for `better-bet` +
  `scriptcaster` once their projects actively run cron or interact.

## Rollback

Revert the merge commit `fb1ed98`. None of the changes are
runtime-impacting:

- The audit-script section is additive; existing drift counts are
  unchanged. Only `.env.schema` is excluded from the mode-600 check,
  which would re-enable the previous noise (the schema is committed
  plaintext; flagging it as secret-bearing was wrong).
- The rotation doc is documentation only.
- The restore-drill script is opt-in (must be called explicitly).
- For the cron-recipe change: the legacy `.env` fallback code is
  preserved in step 2a's comment block for archival. Re-introducing
  it is a 1-line paste from the comment.

## Arc closure

Stage 8 closes the **post-migration retirement arc** (the cleanup of
the legacy `.env`-input path on the three project repos). Combined
with:

- **Stage 5** (cron cutover to `varlock run --inject vars`) —
  PR #88, merged 2026-07-21.
- **Stage 5.5** (explicit declaration on x-digest) — PR #89,
  merged 2026-07-21.
- **Stage 7** (sync-and-archive closure of Stages 1–3 + the
  audit-openviking side-arc) — PRs #79, #82, #84, #87.

…this stage completes the production cutover. The `pass` store +
GPG identity are the canonical secret source for the three project
repos. Migration-era `secrets.yaml` retention is the rotation doc's
30-day policy; off-host bundle retention is indefinite.
