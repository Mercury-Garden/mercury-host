# audit-omniroute-coverage

**Status:** arc complete (merged 2026-07-24).
**Source PR:** [#105](https://github.com/Mercury-Garden/mercury-host/pull/105) —
`feat(audit): add omniroute service + vhost + runtime state drift checks`.
**Merged as:** `5d93180` on `main` (squash, branch `feat/audit-omniroute-coverage`
auto-deleted on origin; local branch retained per dispatcher conventions).
**Follows:** PR #96 (`feat(omniroute): first dev-stack entry`) + PR #97
(`spec(sync-and-archive): archive omniroute first dev-stack entry`) +
PR #103 (`feat(backup): capture omniroute runtime state + declare
STORAGE_ENCRYPTION_KEY`) + PR #104 (`spec(sync-and-archive): archive
backup-omniroute-runtime`). This change closes **gap #2 + gap #4-knowledge**
of the 2026-07-24 omniroute-coverage audit: `audit.sh` did not check
omniroute service health, vhost, or runtime state, and there was no
onboarding-checklist doc that would prevent the same gap pattern from
recurring on the next dev-stack entry.

## Deliverable

Three files, +305 lines, single-purpose: make the omniroute install
**auditable in steady state** (service alive, vhost enabled, sqlite
mutable, .env world-readable check fails loud) AND **onboarding-safe for
the next dev-stack entry** (a checklist doc that captures the gap history
with who closed them and the restore recipe).

1. **`scripts/audit.sh`** (+101 lines) — four new drift surfaces, all
   anchored to existing block patterns:
   - **`[systemd-user]`** `for svc` loop adds `omniroute` (enabled check).
   - **`[active-services]`** adds `"user:omniroute"` (running check, mirrors
     the `hermes-dashboard` 4-day silent-outage failure mode that
     motivated this block in the first place — a service that exists but
     is dead-but-reports-healthy is now flagged here, not silently
     missed).
   - **`[nginx]`** `for vhost` loop adds `omniroute.mercury.garden`
     (symlink check, same shape as the other 8 vhosts).
   - **`[omniroute-state]`** (new block, +88 lines) — three sub-checks:
     1. `~/.omniroute/.env` exists + mode `0600` (the runtime secret
        that decrypts the sqlite on restore; twin of
        `secrets/inventory.yaml#omniroute-env` and of the
        `[project_env]` block — listed here so the omniroute cluster
        reads together in audit output).
     2. `~/.omniroute/storage.sqlite` freshness — mtime within
        `omniroute_state.max_age_hours` (default `48h`, configurable
        via `inventory.yaml`). A frozen sqlite means either the service
        died (covered by `[active-services]`) or the request loop
        stalled. Catching it here keeps a frozen-mutable-state failure
        from looking like "service is fine" in the audit output.
     3. Advisory note if `storage.sqlite.corrupt-*` siblings exist in
        the last 7 days — sqlite has crashed at least once; this is
        informational, not auto-fixable (corruption logs need
        investigation).

2. **`inventory.yaml`** (+14 lines) — new `omniroute_state:` block under
   `state_backup:` with `max_age_hours: 48`. Anchored regex in `audit.sh`
   reads this block specifically (cannot accidentally pick up
   `state_backup.max_age_hours`). Single source of truth for the
   freshness threshold; an operator who wants to tune the staleness
   window edits one value in `inventory.yaml` and the audit picks it up.

3. **`docs/omniroute-known-issues.md`** (new file, +190 lines) — onboarding
   checklist for the next dev-stack entry. Mirrors the
   `varlock-known-issues.md` shape. Captures gaps #1-#4 from the
   2026-07-24 omniroute-coverage audit with who closed them and the
   step-by-step restore recipe. **Section E is the onboarding checklist**
   — 11 bullet points that the install path must hit so this gap
   pattern doesn't recur (every install subsumes the audit surface,
   backup surface, secret-pointer surface, and the known-issues doc
   atomically; partial installs are explicitly flagged as the failure
   mode).

## Verification (captured in PR #105 body, all run on this host)

| Gate | Result |
|---|---|
| `yamllint -c .yamllint.yml --strict .` | rc=0 |
| `shellcheck scripts/*.sh` | rc=0 (SC2088 warnings on `~/` in quoted strings fixed by using `$OR_ENV_FILE` / `$OR_SQLITE_FILE` instead — matches the `hermes_profile_state` pattern) |
| `gitleaks detect --no-git --redact --exit-code 1 .` | 0 leaks |
| `bash -n` parse of all modified scripts | ok |
| `bash scripts/audit.sh` dry-run | same 2 pre-existing drifts (hermes-dashboard inactive + Jul 22 backup gap), **no regressions**, `[omniroute-state]` reports 3/3 green on this host |
| Regex scope check | `omniroute_state.max_age_hours: 48` is read correctly (not 36 from `state_backup.max_age_hours`) — proves the anchor regex works |

The repo's full CI gate is `yamllint → shellcheck → gitleaks → bash scripts/audit.sh || true`
(matches `.github/workflows/validate.yml`). No additional test surface required — this
PR touches scripts that the lint + gitleaks + audit gates already cover.

## Live audit output (from this host, after PR #105 merged)

```
[systemd-user]
  ✓ omniroute enabled (user)
[active-services]
  ✓ omniroute active (user)
[nginx]
  ✓ omniroute.mercury.garden enabled (symlink)
[project_env]
  ✓ omniroute: present, mode 0600
[omniroute-state]
  ✓ /home/ubuntu/.omniroute/.env: present, mode 0600
  ✓ /home/ubuntu/.omniroute/storage.sqlite: fresh (0h old, max 48h)
    /home/ubuntu/.omniroute/: 1 storage.sqlite.corrupt-* file(s) in last 7 days — sqlite has crashed at least once; investigate /var/log or omniroute logs
```

The corrupt-file advisory is informational — sqlite has crashed at least once today
(visible in the file count above). PR does NOT auto-fix the corruption; per the doc,
that's an operator decision (corruption logs need investigation).

## What this does NOT cover (intentional)

- **DR tarball coverage** (gap #1) — closed by PR #103, not re-bundled here.
- **`STORAGE_ENCRYPTION_KEY` secret pointer** (gap #4) — closed by PR #103.
- **Binary at `~/.local/share/pnpm/bin/omniroute`** (gap #3) — by design,
  rebuildable via `pnpm add -g omniroute@<pin>`. Documented in section C
  of the new doc.
- **SQLite corruption auto-recovery** — the corrupt-file advisory is
  informational. A real fix would require a sqlite-side recovery action
  + a `[backup-audit]` post-rotate hook; deferred to a separate arc
  because it's a behavior change, not a coverage change.

## Arc-shape note (important)

**This stage did not follow the standard spec → feat → sync-and-archive template.**
The standard template is:
1. `openspec/changes/<name>/proposal.md` + `tasks.md` + `spec.md`
2. `feat/<name>` PR with implementation
3. `spec/sync-and-archive-<name>` PR after `pnpm openspec archive`

This change followed the **shortcut shape** (same as PR #92 / varlock-stage8-consolidate,
PR #97 / omniroute-first-dev-stack, PR #101 / openviking-migrate-to-openrouter,
and PR #103 / backup-omniroute-runtime):
1. Open `feat/audit-omniroute-coverage` directly with the implementation
2. Squash-merge on approval
3. Sync-and-archive PR contains a real-record archive README documenting the
   deviation (this file), not a fabricated `pnpm openspec archive` output

The shortcut shape is appropriate here because:
- The change is a **coverage fix** (3 files, +305 lines, fully reversible by
  reverting the 3 additions), not a new capability — a full spec/feat/archive
  cycle would be ceremony disproportionate to the change.
- The spec artifacts (the 2026-07-24 omniroute-coverage audit listing gap #2 +
  gap #4-knowledge) live in `docs/omniroute-known-issues.md` (this PR creates it)
  and in the gap closure list at `openspec/changes/archive/2026-07-24-backup-omniroute-runtime/README.md`
  (the prior archive). The audit doc is the source of truth for what the gap was;
  this PR is the closure.
- The PR body itself is structurally a spec: explicit "Why" (the gap), explicit
  "What changes" (3 files, line counts), explicit "Verification" (5 gates with
  results), explicit "What this does NOT cover" (out-of-scope follow-ups), and
  a live audit-output block proving the change works. Reviewers can audit the
  change surface from the PR body alone.

If the next change of this shape needs a fuller spec phase, open one — the arc
driver is happy to handle either template. The trigger for opening a spec PR is
"the change introduces new state that an on-call reader needs explained before
they can triage it"; this PR did not.

## Cross-references

- PR #96 (`feat(omniroute): first dev-stack entry`) — the install that
  this audit now covers.
- PR #97 (`spec(sync-and-archive): archive omniroute first dev-stack entry`).
- PR #103 (`feat(backup): capture omniroute runtime state + declare
  STORAGE_ENCRYPTION_KEY`) — closes gap #1 + gap #3 from the same audit.
- PR #104 (`spec(sync-and-archive): archive backup-omniroute-runtime`).
- `docs/varlock-known-issues.md` — format mirror for
  `docs/omniroute-known-issues.md`.