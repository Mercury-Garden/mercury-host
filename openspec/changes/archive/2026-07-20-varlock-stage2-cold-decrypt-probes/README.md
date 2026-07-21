# Archive: varlock-stage2-cold-decrypt-probes

**Status:** arc stage 2 — agent-side evidence — complete (merged 2026-07-20).
**Source PR:** [#83](https://github.com/Mercury-Garden/mercury-host/pull/83) —
`feat(varlock): Stage 2 cold-decrypt probes + agent rules`.
**Merged as:** `ba7238f` on `main`.
**Follows:** Stage 1 archive
[`2026-07-20-varlock-stage1-install-pinned-tooling`](https://github.com/Mercury-Garden/mercury-host/pull/82)
(PR #81, `922349c`).

## Deliverable

Stage 2 of the varlock plan, **agent-side half only**. This PR proves the
cold-decrypt path works on this host BEFORE any real GPG identity is
created. Specifically:

- `scripts/probe-varlock-cold-decrypt.sh` (10 assertions, ~3s) — generates
  a throwaway unprotected GPG key in a synthetic `$HOME`, inits a `pass`
  store, inserts a canary entry via direct `gpg -e -r <FP>`, then asserts
  the cold-agent non-interactive decrypt path that cron will use. The
  probe proves decrypt works **without** the `pinentry-mode loopback`
  override — so a passphrase-protected production key will work under
  cron, provided `systemd --user gpg-agent.socket` stays enabled.
- `scripts/probe-varlock-pass-backup-restore.sh` (12 assertions, ~3s) —
  builds a throwaway synthetic store, tars it (same shape Stage 3 backup
  will use), restores into a separate synthetic `$HOME`, asserts
  byte-identical ciphertext + mode preservation + cold-agent decrypt of
  the restored canary.
- `AGENTS.md` — 2 new commands-table rows (probe invocations) and 2 new
  quirks entries: one stating Stage 2's critical gate is PROVEN green on
  this host (cites the probes + the recipe file), one documenting the
  `pass 1.7.4-6` stdin-pipe bug the probes work around.

## Pitfall found and documented

**Ubuntu Noble's `pass 1.7.4-6` has a stdin-pipe bug in `pass insert -f`**
(captured in `AGENTS.md`): when input is piped via stdin/heredoc/herestring,
it falls into the interactive `read -p "Enter password..."` branch and
silently exits 1, creating empty subdirectories but writing no ciphertext.
Interactive `pass insert` in a real TTY works correctly because `read -p`
reads from the terminal as intended.

The probes work around this by encrypting via direct
`gpg --batch --pinentry-mode loopback -e -r <FP> --output …` — same shape
`pass insert` uses internally on a working install. Stage 3 backup scripts
must NOT pipe to `pass insert`; use the direct-gpg path instead.

## Verification (captured in PR #83 body, all run on this host)

- `bash scripts/probe-varlock-cold-decrypt.sh` → **PASS: 10  FAIL: 0**
- `bash scripts/probe-varlock-pass-backup-restore.sh` → **PASS: 12  FAIL: 0**
- `yamllint -c .yamllint.yml --strict .` → clean (rc=0)
- `shellcheck scripts/*.sh` → rc=0 (info-level SC2015/SC2016 in probes
  only; no warnings/errors)
- `gitleaks detect --no-git --redact --exit-code 1 .` → `no leaks found`
- `bash -n` on every touched script → clean

The cold-agent decrypt is asserted twice — once with the loopback pinentry
override enabled (probe section 4), once with it removed (section 5).
Both pass. This is the proof that a passphrase-protected production key
will work under cron without operator intervention, provided
`systemd --user gpg-agent.socket` stays enabled (it is).

## Files changed in #83

```
 AGENTS.md                                    | 20 ++++++++++++++++++++
 scripts/probe-varlock-cold-decrypt.sh        | 198 +++++++++++++++++++++++++++++ (new)
 scripts/probe-varlock-pass-backup-restore.sh | 135 ++++++++++++++++++++++++ (new)
 3 files changed, 353 insertions(+)
```

## Why this is a doc-only sync-and-archive PR

`mercury-host` is a single-host declarative inventory + bootstrap repo,
not an application. It does not track live specs under `openspec/specs/`
and there is no `openspec/changes/varlock-stage2-cold-decrypt-probes/`
proposal/tasks/spec to move into the archive. The arc narrative lives
in the upstream OpenSpec change driving the varlock plan (managed in the
opencode/coordination layer, not committed to this repo).

Per the same convention used by
`openspec/changes/archive/2026-07-20-varlock-stage1-install-pinned-tooling/`
(PR #82) and `openspec/changes/archive/2026-07-19-audit-openviking/`
(PR #79), this PR records the arc closure truthfully: what was delivered,
where it was verified, and which follow-ups remain. No spec deltas are
fabricated; the archive is a single README + a directory marker.

## Out of scope (later stages, not affected by this archive)

- **Stage 2 human TTY half** — operator runs `gpg --full-generate-key` +
  `pass init <FINGERPRINT>` + canary plant + recovery-bundle export in
  a real terminal, then pastes back the fingerprint so the agent can
  re-run the probes against the production store. Agent MUST NOT see the
  GPG passphrase or the symmetric recovery passphrase at any point. The
  ready-to-paste recipe lives at
  `~/.hermes/plans/2026-07-20_225129-varlock-stage2-human-recipe.md`.
- **Stage 3** — `mercury-host` backup/audit/restore integration for the
  new store (uses the `pass-backup-restore` probe as the round-trip
  proof).
- **Stages 4–7** — project migrations (x-digest pilot → better-bet →
  scriptcaster). Stage 4 is gated on Stage 2 human-T completion.

## Rollback

Trivial and complete (the probes are run-only; no installed state):

```sh
rm /home/ubuntu/data/code/mercury-host/scripts/probe-varlock-cold-decrypt.sh
rm /home/ubuntu/data/code/mercury-host/scripts/probe-varlock-pass-backup-restore.sh
# Then revert the AGENTS.md additions (2 commands-table rows, 2 quirks entries).
```

## Cross-references

- PR #83 body — full Stage 2 verification output, recipe file pointer,
  and the human/agent boundary contract.
- PR #82 body + `2026-07-20-varlock-stage1-install-pinned-tooling/README.md`
  — prior arc step, exact mirror of this archive's structure.
- `~/.hermes/plans/2026-07-20_225129-varlock-stage2-human-recipe.md` —
  the Stage 2 human TTY recipe (paste-only; agent does not edit).