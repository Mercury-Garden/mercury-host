# Archive: varlock-stage3-backup-audit-integration

**Status:** arc stage 3 — host-wide backup/audit/restore integration — complete (merged 2026-07-21).
**Source PR:** [#86](https://github.com/Mercury-Garden/mercury-host/pull/86) —
`feat(varlock): Stage 3 backup/audit/restore integration (host-wide)`.
**Merged as:** `64a093f` on `main`.
**Follows:** Stage 2 archive
[`2026-07-20-varlock-stage2-cold-decrypt-probes`](https://github.com/Mercury-Garden/mercury-host/pull/84)
(PR #83, `ba7238f`).

## Deliverable

Stage 3 of the varlock plan, **host-wide integration**: wires the encrypted
`pass` store + GPG private key that Stage 2 produced into the existing
secret-capture pipeline so they ride through the same machinery that
backs up `ssh-ed25519`, `oauth2-cookie-secret`, `gogcli-keyring`, etc.

Specifically:

- **`secrets/inventory.yaml`** — 2 new entries (`varlock-pass-store` +
  `varlock-gpg-private`). The `varlock-gpg-private` entry documents that
  the **durable** copy is the armored export (single file, deterministic),
  while the `.key` file tar.gz is opportunistic (depends on a prior
  `pass show` / `pass insert` having materialized the `.key` files).
- **`scripts/backup-secrets.sh`** — emits 3 new base64 blocks:
  `varlock_pass_store_tar_gz` (encrypted store + `.gpg-id`),
  `varlock_gpg_private_tar_gz` (`.key` files, opportunistic),
  `varlock_gpg_armored_private` (armored export, durable path — always
  emitted when Stage 2 has run). The temp file holding the plaintext
  private key is `shred -u`'d immediately after capture.
- **`scripts/restore-secrets.sh`** — adds `--include varlock-pass` covering
  all three blocks. Restore order:
  1. **Import the armored key** via `gpg --import` (durable path; works on
     any host state — fresh VM, degraded gpg-agent, etc.)
  2. Merge-extract the `.key` tar (opportunistic; supplements the armored
     import — gives the agent pre-materialized keys if the operator ever
     used them in this `$HOME`)
  3. Merge-extract the pass store tar (**never clobbers pre-existing
     entries** — a Monday backup doesn't destroy Wednesday entries)

  New `extract_tar_gz_b64_block_preserve` helper does the merge
  semantics; the existing `extract_tar_gz_b64_block` `rmtree`'s the
  target (correct for `gogcli-keyring`, wrong for the pass store).
- **`scripts/backup-mercury-state.sh`** — adds `~/.password-store` to
  `BACKUP_PATHS` (second-layer capture). The encrypted store is already
  in `backup-secrets.sh`, but having it in the daily state tarball means
  a fresh-restore-only-from-state-tarball flow still produces a working
  store.
- **`scripts/audit.sh`** — new `[varlock]` section checks (1) `varlock` +
  `pass` binaries on PATH, (2) `~/.password-store` modes (700/600),
  (3) `gpg-agent.socket` enabled (cron decrypt precondition), (4) `.key`
  files dir present, (5) **canary decrypts from a cold gpg-agent** — the
  Stage 2 critical gate in production form. This is the audit check that
  will fire if any drift breaks the cron path.
- **`scripts/test-varlock-backup-restore.sh`** — 17-assertion synthetic-HOME
  round-trip test (new). Verifies backup emits all 3 blocks, restore
  imports the armored key (fingerprint match), the canary round-trips
  byte-identical, and the canary decrypts from a cold gpg-agent in the
  restored `$HOME`.

## Pitfall documented in the test

In `--batch + --pinentry-mode loopback` synthetic `$HOME`, GnuPG 2.4.4 does
**not** materialize the `.key` files in `private-keys-v1.d/` — even after
a sign-then-verify cycle. On a real host, prior `pass show` / `pass
insert` calls do materialize them (verified — this host has 28 `.key`
files). The test reports this as informational
(`· 1.4 GPG .key file count: 0`) rather than failing, because the
**armored block** (`2.5 varlock_gpg_armored_private block present`) is
the durable path that always works —
`4.1 GPG identity fingerprint matches after armored import` proves the
restore-side import succeeds end-to-end.

This is the same shape as the Stage 2 cold-decrypt pitfall: synthetic
HOME doesn't perfectly model real `gpg-agent` state, so the probe is
written to be honest about what it proves (mechanism + import path)
rather than overclaiming (every `.key` file materialized).

## Verification (captured in PR #86 body, all run on this host)

- `bash scripts/test-varlock-backup-restore.sh` → **PASS: 17  FAIL: 0** (~5s, new)
- `bash scripts/test-secrets-backup-restore.sh` → **PASS: 34  FAIL: 0** (~1.5s, regression)
- `bash scripts/probe-varlock-cold-decrypt.sh` → **PASS: 10  FAIL: 0** (~3s, Stage 2)
- `bash scripts/probe-varlock-pass-backup-restore.sh` → **PASS: 12  FAIL: 0** (~3s, Stage 2)
- `yamllint -c .yamllint.yml --strict .` → clean (rc=0)
- `shellcheck -S warning scripts/*.sh` → rc=0 (info-level SC2015/SC2016/SC2097/SC2098 in probe scripts only, with file-level disables + comments)
- `gitleaks detect --no-git --redact --exit-code 1 .` → `no leaks found`
- `bash scripts/audit.sh` against live host — `[varlock]` section → **8/8 ✓** (varlock + pass on PATH, store modes 700/600, gpg-agent enabled, 28 key files, canary decrypts from cold agent with rc=0 + value matches)

The cold-agent canary decrypt is the audit check that ties Stage 2's
mechanism proof to Stage 3's production cron path. If anyone disables
`systemd --user gpg-agent.socket`, removes the canary from
`~/.password-store/canary.gpg`, or downgrades `varlock` / `pass` below
the Stage 1 pinned versions, this audit row will turn red and the next
cron run will fail loudly rather than silently.

## Files changed in #86

```
 scripts/audit.sh                       | 161 ++++++
 scripts/backup-mercury-state.sh       |   6 +
 scripts/backup-secrets.sh             |  45 ++
 scripts/restore-secrets.sh            | 150 ++++++
 scripts/test-varlock-backup-restore.sh| 277 +++++++++ (new)
 secrets/inventory.yaml                |  67 ++
 secrets/secrets.yaml.template         |  28 +
 7 files changed, 736 insertions(+)
```

## Why this is a doc-only sync-and-archive PR

`mercury-host` is a single-host declarative inventory + bootstrap repo,
not an application. It does not track live specs under `openspec/specs/`
and there is no `openspec/changes/varlock-stage3-backup-audit-integration/`
proposal/tasks/spec to move into the archive. The arc narrative lives
in the upstream OpenSpec change driving the varlock plan (managed in the
opencode/coordination layer, not committed to this repo).

Per the same convention used by
[`2026-07-20-varlock-stage2-cold-decrypt-probes`](https://github.com/Mercury-Garden/mercury-host/pull/84),
[`2026-07-20-varlock-stage1-install-pinned-tooling`](https://github.com/Mercury-Garden/mercury-host/pull/82),
and [`2026-07-19-audit-openviking`](https://github.com/Mercury-Garden/mercury-host/pull/79),
this PR records the arc closure truthfully: what was delivered, where
it was verified, and which follow-ups remain. No spec deltas are
fabricated; the archive is a single README + a directory marker.

## Out of scope (later stages, separate PRs)

- **Stage 4** — Migrate the first project (`x-digest`) to varlock:
  author `.env.schema`, wire `varlock run --inject vars -- <existing
  command>`, cut over `x-digest-daily` cron recipe, observe 3 scheduled
  runs.
- **Stage 5** — Migrate `better-bet`.
- **Stage 6** — Migrate `scriptcaster`.
- **Stage 7** — Drill a full restore-from-cold-state-tarball against a
  fresh VM (proves Stage 3's BACKUP_PATHS addition round-trips).
- **Stage 8** — Consolidate + retire legacy runtime dependencies after
  the observation windows + the restore drill.