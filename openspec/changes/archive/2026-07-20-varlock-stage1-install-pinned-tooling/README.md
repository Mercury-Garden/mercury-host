# Archive: varlock-stage1-install-pinned-tooling

**Status:** arc stage 1 complete (merged 2026-07-20).
**Source PR:** [#81](https://github.com/Mercury-Garden/mercury-host/pull/81) —
`feat(varlock): install pinned varlock 1.11.0 + pass 1.7.4 (Stage 1)`.
**Merged as:** `922349c` on `main`.

## Deliverable

Stage 1 of the varlock plan. Install pinned tooling only — no GPG
identity, no `~/.password-store` init, no project edits, no service
restart. Specifically:

- `varlock 1.11.0` (Linux arm64) downloaded from the official
  `github.com/dmno-dev/varlock/releases/tag/varlock@1.11.0` tarball,
  upstream `checksums.txt` SHA-256 verified
  (`5b74a89f07ac27ee21e819e5b2aa327792bb3e5676338e62b8ef2f9a120b45bd`),
  extracted to `~/.local/bin/{varlock,varlock-local-encrypt}` (mode 0755).
- `pass 1.7.4-6` installed via `apt-get install -y pass` and pinned
  in `apt-mark showmanual` so `capture.sh` will preserve it on every
  subsequent run.
- Both installs declared as declarative state:
  - `packages/cargo.yaml` — new `release_tarball_bins` entry for
    varlock with pinned upstream SHA, on-disk binary SHA, and a
    self-verifying install command (any future reinstall re-verifies
    upstream before extracting).
  - `packages/apt.list` — header note marking `pass` as the apt half
    of the plan.
- `AGENTS.md` and `README.md` updated to document what is installed,
  the commands an agent should use (`varlock load --agent`, `audit .`,
  `scan --staged`), and the hard rule that agents must use **only**
  `varlock load --agent` for schema inspection — never raw
  `--format json-full` / `env` / `shell` / `reveal`.

## Verification (captured in PR #81 body, all run on this host)

- Upstream archive SHA-256 verified against published `checksums.txt`:
  **OK**
- `varlock --version` → `1.11.0`
- `pass --version` → `1.7.4-6`
- `apt-mark showmanual` includes `pass` ✓
- `yamllint -c .yamllint.yml --strict .` — clean
- `shellcheck scripts/*.sh` — clean (no script changes; `bash -n` on
  touched and adjacent scripts also clean)
- `gitleaks detect --no-git --redact --exit-code 1 .` — `no leaks found`
- `bash scripts/audit.sh` — same 1 pre-existing mirror-stale drift as
  Stage 0 baseline (`state_backup.last_run_at`); 0 new drift items
  introduced by this PR

## Files changed in #81

```
 AGENTS.md           | 15 +++++++++++++++
 README.md           |  5 +++++
 packages/apt.list   |  8 ++++++++
 packages/cargo.yaml | 32 ++++++++++++++++++++++++++++++++
 4 files changed, 60 insertions(+)
```

## Why this is a doc-only sync-and-archive PR

`mercury-host` is a single-host declarative inventory + bootstrap
repo, not an application. It does not track live specs under
`openspec/specs/` and there is no `openspec/changes/varlock-stage1-install-pinned-tooling/`
proposal/tasks/spec to move into the archive. The arc narrative lives
in the upstream OpenSpec change driving the varlock plan (managed in
the opencode/coordination layer, not committed to this repo).

Per the same convention used by
`openspec/changes/archive/2026-07-19-audit-openviking/`, this PR
records the arc closure truthfully: what was delivered, where it was
verified, and which follow-ups (if any) remain. No spec deltas are
fabricated; the archive is a single README + a directory marker.

## Out of scope (later stages, not affected by this archive)

- Stage 2 — GPG identity + `~/.password-store` init + canary entry.
  **Human TTY** work; agent MUST NOT create the GPG key or init the
  store.
- Stage 3 — `mercury-host` backup/audit/restore integration for the
  new store.
- Stages 4–7 — project migrations (x-digest pilot → better-bet →
  scriptcaster).

## Rollback

Trivial and complete (declarative files just stop listing the
binaries until the next reinstall):

```sh
apt-get remove -y pass
rm /home/ubuntu/.local/bin/varlock /home/ubuntu/.local/bin/varlock-local-encrypt
```
