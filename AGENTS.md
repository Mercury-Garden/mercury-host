# AGENTS.md

> Declarative host-state repo for the Oracle Cloud VM `mercury`. Read
> `README.md` first for the full system narrative. This file captures
> only the things an agent would otherwise miss or guess wrong.

## What this repo is

A **single-host inventory + bootstrap repo**, not an application. It
holds YAML files describing services, nginx vhosts, packages, systemd
units, secrets pointers, and the scripts that keep them in sync with
the live host. There is no application code, no test suite, and no
build step here. CI runs yamllint + shellcheck + gitleaks + an audit
dry-run — that is the verification surface.

Canonical files:

- `host.yaml` — machine identity, Oracle Cloud metadata
- `inventory.yaml` — single source of truth (services, nginx, projects,
  cron, state_backup, OCI block volume)
- `network/` — `hostname`, `hosts`, `vcn-topology.md`
- `nginx/` — vhosts + snippets this host owns
- `packages/` — `apt.list`, `snap.yaml`, `cargo.yaml`, `node.yaml`
- `secrets/` — `inventory.yaml` (pointers only) + `secrets.yaml.template`
  (sanitized; the real file is gitignored and lives at `~/.secrets/`)
- `scripts/` — `capture.sh`, `audit.sh`, `restore.sh`,
  `backup-secrets.sh`, `restore-secrets.sh`, `backup-mercury-state.sh`
- `shell/` — `.zshrc.template`, `.zshenv`, `.profile`,
  `oh-my-zsh-custom/`
- `systemd/system/`, `systemd/user/` — units this host owns
- `tooling/` — agent/AI tool configs (declarative only)

## Hard rules

- **No secrets ever.** `.gitignore` blocks SSH keys, `.env`, gh
  hosts.yml, oauth2-proxy cfg, Letsencrypt privkeys, etc. — and CI
  runs `gitleaks detect --no-git --redact --exit-code 1 .` on every
  PR. If a value is sensitive, reference it via `secrets/inventory.yaml`
  as a pointer, never inline it.
- **Real values live in `.local` / `.template` sibling files.** `*.example`
  and `*.template` are committed with placeholders; real configs are
  `.local` (or no extension) and are gitignored. See
  `tooling/oauth2-proxy/oauth2-proxy.cfg.example` + `secrets/secrets.yaml.template`.
- **YAML over JSON** for human-edited files. JSON only when an upstream
  tool requires it (e.g., `opencode.jsonc`).
- **One PR per concern.** The repo's history (see `git log`) is a series
  of single-subsystem PRs (`feat(systemd)`, `feat(nginx)`, `feat(shell)`,
  etc.). Keep new changes narrow.

## Commands an agent needs

All paths are relative to repo root unless noted.

| Task | Command |
|---|---|
| Audit live host against this repo (drift check, exits 1 on drift) | `bash scripts/audit.sh` |
| Refresh declarative files from the live host | `bash scripts/capture.sh` |
| Bootstrap a fresh Ubuntu 24.04 host to match this repo | `bash scripts/restore.sh` |
| Snapshot every host secret → `~/.secrets/secrets.yaml` (mode 0600) | `bash scripts/backup-secrets.sh` |
| Overwrite an existing secrets dump | `bash scripts/backup-secrets.sh --force` |
| Preview a secrets restore | `bash scripts/restore-secrets.sh --dry-run` |
| Restore secrets from a specific file (no service restarts) | `bash scripts/restore-secrets.sh /path/to/secrets.yaml` |
| Restore only one subsystem | `bash scripts/restore-secrets.sh --include oauth2` |
| Restore one specific `.env` under `~/data/code/` (per-file granularity) | `bash scripts/restore-secrets.sh --env x-digest/.env` |
| Restore all auto-discovered `.env*` files under `~/data/code/` | `bash scripts/restore-secrets.sh --include code-env` |
| Restore only the openwiki config (`~/.openwiki/.env`) | `bash scripts/restore-secrets.sh --include openwiki` |
| Run the secrets backup/restore round-trip test (synthetic $HOME, 34 assertions) | `bash scripts/test-secrets-backup-restore.sh` |
| Register the weekly secrets-test smoke cron (no_agent, Sun 04:00 Bogota) | `bash scripts/register-secrets-test-cron.sh` |
| Validate a project's Varlock schema (no secrets leave the machine) | `varlock load --agent` |
| Audit a project for schema/code drift | `varlock audit .` |
| Scan for leaked values after a schema change | `varlock scan --staged` |
| Validate varlock schema + gpg-agent pre-flight (cron use, exit 1-5 on failure) | `bash scripts/varlock-preflight.sh <project-path>` |
| Reference doc for `~/.hermes/cron/jobs.json#x-digest-daily` (Varlock plan Stage 5) | `cron-recipes/x-digest-daily.md` |
| Prove a `pass` entry decrypts non-interactively from a cold `gpg-agent` (synthetic HOME) | `bash scripts/probe-varlock-cold-decrypt.sh` (10 assertions, ~3s) |
| Prove a `pass` store round-trips through `tar` + restore (synthetic HOME) | `bash scripts/probe-varlock-pass-backup-restore.sh` (12 assertions, ~3s) |
| Snapshot irreplaceable state to a daily tarball | `bash scripts/backup-mercury-state.sh` |
| Lint all YAML | `yamllint -c .yamllint.yml --strict .` |
| Lint all bash | `shellcheck scripts/*.sh` |
| Scan for leaked secrets | `gitleaks detect --no-git --redact --exit-code 1 .` |
| Run full CI gate locally (matches `.github/workflows/validate.yml`) | yamllint → shellcheck → gitleaks → `bash scripts/audit.sh || true` |

Order matters: **lint → shellcheck → secrets-scan → audit dry-run**.
That is the order CI runs them in; doing it locally in the same order
catches most issues before push.

### Varlock + Pass — manual upgrade policy

`varlock` (pinned at 1.11.0) and `pass` (apt-managed; NOT pinned in this
repo because its source-of-truth is Ubuntu Noble's apt pool) are
**deliberately** excluded from `scripts/devtools-upgrade.ts`'s auto-upgrade
loop. Reasons (Stage 8.3 of the Varlock plan):

* **varlock**'s security policy supports only latest/main upstream, which
  means deliberate version pinning + manual review is mandatory. Auto-upgrade
  would silently move the production pinning; not appropriate.
* **pass** is an apt package; its upgrade cadence is Ubuntu's choice, not ours.
  The `[varlock]` section of `scripts/audit.sh` reports the live versions and
  flags drift against any pin recorded in `inventory.yaml`.

When a manual upgrade is desired, follow this recipe:

```bash
# 1. Audit current state and confirm the upgrade path
bash scripts/audit.sh | grep -A 8 '\[varlock\]'

# 2. Upgrade pass (apt; standard cron-managed)
sudo apt-get install -y pass
pass --version

# 3. Upgrade varlock (from official Linux arm64 tarball; verify checksum)
VER=1.12.0  # check varlock.dev/releases/latest for the current version
ARCH=arm64
wget -q "https://github.com/dmno-dev/varlock/releases/download/varlock%40${VER}/varlock-linux-${ARCH}.tar.gz" -O /tmp/vl.tar.gz
sha256sum /tmp/vl.tar.gz    # compare to published checksums.txt
tar -xzf /tmp/vl.tar.gz -C /tmp/
install -m 0755 /tmp/varlock "${HOME}/.local/bin/varlock"
rm -rf /tmp/varlock /tmp/vl.tar.gz
varlock --version
```

Then run the round-trip test (`scripts/test-varlock-backup-restore.sh`)
and `scripts/audit.sh` to confirm no drift before opening a PR that
updates the version pin in `inventory.yaml`.

## Scripts: behavioral quirks worth knowing

- **`audit.sh` reconstructs the user's PATH before checking mise.**
  Hermes-agent runs under a venv-isolated PATH that hides mise; without
  the `~/.zshrc` re-source the audit would falsely report drift. The
  script guards this with `USER_SHELL_LOADED`. Always run it from an
  interactive shell, not from a service account.
- **`audit.sh` exits non-zero on drift.** `validate.yml` runs it with
  `|| true` because the CI runner has no services — drift is expected,
  what we want is "did bash parse the script at all".
- **`capture.sh` is surgical, not idempotent-destructive.** It preserves
  the apt.list header, hand-written `purpose:` per snap app, and inline
  comments on `cached_runtimes`. Always review the diff (`git diff`)
  before committing.
- **`restore.sh` is NOT end-to-end idempotent.** It installs apt + snap,
  pins mise via `mise use --global node@<ver>` from
  `packages/node.yaml#default_node`, deploys shell startup files from
  `shell/.zshenv` + `shell/.profile` (full copy) and patches
  `~/.zshrc` in-place to swap the toolchain block (volta → mise) without
  touching per-host customizations (GITHUB_TOKEN, pnpm PATH block,
  plannotator env vars). Restores systemd user units. Nginx vhost deploy
  is manual (copy to `/etc/nginx/sites-available/`, symlink to
  `sites-enabled/`, `nginx -t && systemctl reload nginx`). The final
  echo lists every manual step.
- **Shell file deployment is split**: `shell/.zshenv` and `shell/.profile`
  are pure declarative (full copy on restore). `shell/.zshrc.template` is
  a reference template — the live `~/.zshrc` is a hand-maintained overlay
  on top of it, with per-host additions (GITHUB_TOKEN, pnpm PATH block,
  plannotator env vars, etc.). `restore.sh` patches `~/.zshrc` surgically
  to swap the toolchain block but never overwrites the full file. If
  you add new content to `shell/.zshrc.template`, you'll also need to
  manually add it to `~/.zshrc` and to the `restore.sh` patch logic.
- **`backup-mercury-state.sh` writes to `/home/ubuntu/data/backups/`
  (NOT `/tmp`).** The boot volume's `/tmp` is small and the script uses
  a temp dir on the data volume. Output is `mercury-state-<UTC>.tar.zst`
  with sibling `manifest.json` and `verify.json`. Exit codes: 0 ok,
  1 tar failed, 2 manifest failed, 3 verify warning (non-fatal),
  4 prune warning (non-fatal).
- **`backup-mercury-state.sh` does a two-pass tar, combined via
  `tar --concatenate`.** Pass 1 runs as $USER over BACKUP_PATHS; pass 2
  runs as root via `sudo -n tar` over ELEVATED_PATHS (currently
  `/etc/nginx` + `/etc/letsencrypt`) to capture mode-0600 vhost configs
  and letsencrypt cert keys. The two uncompressed tar files are merged
  with `tar --concatenate -f` (which rewrites the EOF marker), then
  zstd-compressed. Don't try to combine the two passes via subshell
  `;` piping — GNU tar's EOF marker (two 512-byte zero blocks) makes
  the second pass invisible to `tar -I zstd -tf` / `tar -I zstd -xf`.
  The ACME account `private_key.json` is explicitly excluded from pass 2
  (regenerable via `certbot register --replace`; no DR value).
- **`backup-mercury-state.sh` integrity check is 1-pinned + 4-random, not 5-random.** Random-only sampling was dominated by `~/.hermes/hermes-agent/` (~97% of archive entries are python venv + tests + skills) — verified 2026-07-14 that all 5 of one day's samples landed in `~/.hermes`, telling us nothing about the 3% that matters. The pinned-sample list (PRIVILEGED_PATHS in the script) covers SSH, GPG, nginx vhosts/snippets, project `.env` files, ollama cloud auth, openwiki key, and mercury-host's own inventory.yaml — the irreplaceable subset. If none of those exist in the archive (catastrophic drift), the sampler logs a WARN and falls back to all-random.
- **`audit.sh` checks two things for system services: enabled AND
  active (in separate sections).** The `[systemd-system]` section only
  checks `is-enabled`. A separate `[active-services]` section checks
  `is-active` for the small allowlist of services that should be
  running 24/7 (currently `nginx`, `cron`, `hermes-dashboard`). This
  is what would have caught the 2026-07-05 → 2026-07-09 dashboard
  silent outage: the unit had stopped cleanly (exit 0), `is-enabled`
  still said enabled, the old audit didn't notice. With this check,
  audit exits non-zero and prints an actionable `drift` line the moment
  the service goes down. **`ollama` is intentionally NOT in the active
  list** — it's enabled but commonly stopped when not in use. If you
  add a new 24/7 service, add it to BOTH lists in audit.sh.
- **`restore.sh` symlinks (not copies) every `systemd/user/*.service`
  AND `systemd/system/*.{service,timer}` into `~/.config/systemd/user/`.**
  The `systemd/system/` dir holds mercury-state-backup specifically —
  see the `state_backup:` block in `inventory.yaml` for why. Symlink
  means `git pull && systemctl --user daemon-reload` picks up unit
  edits without re-running restore.sh. The loop is idempotent: re-runs
  are no-ops, and `enable` on an already-enabled unit exits 0.
- **`backup-secrets.sh` auto-discovers every `.env*` file under
  `~/data/code/`** (excludes `*.example` / `*.sample` templates) and
  captures each as a `code_env_<sanitized-path>` b64 block in
  `~/.secrets/secrets.yaml`. Adding a new project with a `.env` needs no
  edit to this script, `inventory.yaml`, or the template. Use
  `bash scripts/restore-secrets.sh --env <path-or-kind>` to restore ONE
  file, or `--include code-env` for all. The legacy `x_digest_env` /
  `scriptcaster_env` blocks remain as ALIASES for back-compat with old
  `--include x-digest` / `--include scriptcaster` filters.
- **Varlock (`1.11.0`) + `pass` (`1.7.4`) are installed but not yet wired
  to any project.** They are the Stage 1 of the varlock implementation
  plan (notion: see 2026-07-19 research note; plan file at
  `~/.hermes/plans/2026-07-19_140710-varlock-local-secrets-store.md`).
  The pinned install paths are `~/.local/bin/varlock` (release-tarball
  binary, SHA-256 in `packages/cargo.yaml#release_tarball_bins`) and
  `/usr/bin/pass` (apt). `~/.password-store` and any GPG secret key
  are intentionally NOT yet created — that's Stage 2 (human TTY work).
  Agents MUST NOT create the pass store or a GPG identity, MUST NOT
  read or print project `.env` files, and MUST NOT pass `--format
  json-full` / `env` / `shell` / `reveal` to varlock. Use only
  `varlock load --agent` (redacted JSON) for any schema inspection.
- **Stage 2 critical gate (cold-agent non-interactive decrypt) is
  PROVEN green on this host with the production key.** Stage 2 closed
  2026-07-20. Production fingerprint: `1783B58858FD26D16D4BF58C490FE2DCACFEE578`
  (Curve 25519, 2-year expiry, unprotected — chosen for cron-compatible
  unattended decrypt on this single-user host). `~/.password-store/`
  is initialized, `.gpg-id` is the fingerprint, and one synthetic
  canary lives at `mercury/_canary/test.gpg`. Hermes verified cold-agent
  decrypt twice during Stage 2 (once via the throwaway probe in PR #83,
  once against the production key after bootstrap). Recovery bundle
  lives off-host; symmetric passphrase stored in a different place.
  Agents MUST NOT create the pass store or a GPG identity, MUST NOT
  read or print project `.env` files, and MUST NOT pass `--format
  json-full` / `env` / `shell` / `reveal` to varlock. Use only
  `varlock load --agent` (redacted JSON) for any schema inspection.
  The four Stage 2 pitfalls (empty-passphrase refusal, pass stdin-pipe
  bug, pass not accepting --pinentry-mode, zsh nomatch) are documented
  in skill `devops/gpg-pass-store-bootstrap-on-headless-terminal`.
- **Ubuntu Noble `pass 1.7.4-6` has a stdin-pipe bug in `pass insert -f`**:
  when input is piped via stdin/heredoc/herestring, it falls into the
  interactive `read -p "Enter password..."` branch and silently exits 1,
  creating empty subdirectories but no ciphertext. **Interactive
  `pass insert` in a real TTY works correctly** because `read -p` reads
  from the terminal as intended. Stage 3 backup scripts must NOT pipe
  to `pass insert`; encrypt via direct `gpg --batch --pinentry-mode
  loopback -e -r <FP>` instead (same shape the probes use).
- **`restore-secrets.sh --env` refuses to overwrite a non-empty target**
  unless `--force` is passed. This protects against a typo mapping the
  wrong kind to a working `.env` in another repo. Use `--force` only when
  you genuinely intend to replace a working file (e.g. rolling back to
  an older known-good backup).
- **`restore-secrets.sh` writes files but does NOT restart services.**
  After a restore you must restart manually:
  `systemctl --user restart hermes-gateway mercury-tasks oauth2-proxy webhook-server openchamber`
  and `sudo systemctl restart nginx`.

## Architecture facts that aren't obvious from filenames

- **`inventory.yaml` is the single source of truth for services.** New
  services get added to `services[]` by hand; `audit.sh` flags drift by
  checking `systemctl is-enabled` against the list. Don't try to derive
  this from systemd automatically — the file mixes owned units
  (`systemd/user/*.service`) with Ubuntu-package units (`nginx.service`,
  `cron.service`, `ollama.service`) and explicitly external ones
  (`/usr/lib/systemd/...` paths) with comments saying "do not own".
- **One user-facing node toolchain (`mise`) plus the hermes-bundled
  runtime.** `mise` (the active toolchain as of the 2026-07-18 migration
  from unmaintained volta) is pinned at `packages/node.yaml →
  default_node:` and `inventory.yaml → projects[].pinned_node:`. Both are
  currently the floating form `"24"` (within-major), which mise
  interprets as "latest installed 24.x" (currently 24.18.0). The audit
  uses semver-aware comparison: `expected` may be a prefix of `actual`.
  PATH order per `path_order_required` is
  `~/.local/share/mise/installs/pnpm/11.14.0` first (from
  `~/.zshrc → eval "$(mise activate zsh)"`), then
  `~/.local/share/mise/installs/node/24/bin`, then
  `~/.local/bin`, then `~/.cargo/bin` (from `~/.zshenv → .cargo/env`,
  which runs before `.zshrc` so cargo is added to the parent PATH that
  mise prepends ON TOP OF). In a fresh SSH/login shell where mise isn't
  yet on PATH, cargo is first and mise prepends above it. The
  `~/.hermes/node` runtime is hermes-internal (not user-managed) and
  capture.sh refreshes both.
- **The global mise config lives at `~/.config/mise/config.toml`** and
  is **not in this repo** (per-host artifact). It is written by
  `scripts/restore.sh` from `packages/node.yaml#default_node`. Do NOT
  edit it by hand — the next restore.sh invocation will overwrite it.
  Edit `packages/node.yaml#default_node` instead.
- **Every tracked project must have `node = "<ver>"` in `mise.toml`**
  (the repo-level file at `<repo>/mise.toml`) AND a `lockfile_sha256` in
  `inventory.yaml`. The audit checks both — drift in either is reported
  as `REPRODUCIBILITY`. `capture.sh` regenerates the lockfile SHA but
  the mise.toml pin is the project's responsibility.
- **The `state_backup:` block in `inventory.yaml` has a `max_age_hours:
  36` field.** Audit fails if no fresh tarball within 36h. Don't change
  this without understanding the backup timer schedule (daily 03:00
  America/Bogota via `mercury-state-backup.timer`, `Persistent=true`).
- **`expected_branch`** in `inventory.yaml → projects` is informational
  only — audit reports mismatches as `note`, not `drift`. Some entries
  are local working branches on purpose (e.g.,
  `fix/pollapp-api-contract-drift`).
- **`decommissioned_vhosts:` exists in `nginx`'s service entry** because
  `hermes.mercury.garden` is in `sites-available` but not symlinked
  into `sites-enabled`. Audit handles this — don't remove it from
  inventory until the file is gone from `sites-available/`.
- **`user_cache_paths:` in `inventory.yaml`** declares that
  `~/.cache` and `~/.local/share` are symlinks pointing at
  `/home/ubuntu/data/.cache` and `/home/ubuntu/data/.local/share`
  (added 2026-07-05 after the boot-disk fill-up intervention).
  These are RELOCATED, not aliased — every tool (pnpm, uv,
  playwright, opencode, hermes-gateway) resolves the same cache
  data transparently via the symlink. The audit's `[user_cache_paths]`
  section enforces four invariants (symlink, target correct, target
  exists, target on sdb — not sda). On a fresh host, `restore.sh`
  step 4.5 creates the target dirs on sdb before symlinking. Cache
  data is intentionally NOT backed up by `backup-mercury-state.sh`
  (rebuildable from registries); see the script's excludes list.
  Symlinks to other parts of `/home/ubuntu/data` should follow the
  same shape (declare in `user_cache_paths`, audit verifies).
- **Tooling skills live in three different roots** (claude / agents /
  opencode) — `tooling/skills-manifest.yaml` tracks name + sha256 only,
  not contents. To add a skill, install it under `~/.config/opencode/skills/`
  (or `~/.claude/skills/`, `~/.agents/skills/`) and re-run `capture.sh`.
  Audit flags when any sha256 in the manifest no longer matches live.

## Testing

There is no `npm test` / `pytest` here. Verification is the CI gate:
yamllint, shellcheck, gitleaks, audit dry-run. If you change a script,
run it locally and read its output before pushing.

## Conventions specific to this repo

- **Inventory `services[].unit` paths**: owned units point at repo
  paths (`systemd/user/foo.service`); external units point at
  `/lib/systemd/system/foo.service` with a `# Ubuntu package, do not
  own` comment. Preserve this distinction.
- **Cron `user_crontab: null` is meaningful.** It means "no user crontab
  is set" — capture.sh preserves `null` and switches to a quoted note
  if the host has one.
- **`secrets/inventory.yaml` keys are kebab-case** (`oauth2-cookie-secret`)
  but `secrets.yaml` output keys are snake_case (`oauth2_cookie_secret`).
  Don't conflate the two when grepping.
- **`path_order_required`** in `packages/node.yaml` is aspirational, not
  a snapshot — capture.sh does not regenerate it. Edit by hand.
- **The `secrets.yaml.template` is NOT a working file.** It has
  `<set from ...>` placeholders. Restoring from this template would
  litter the live filesystem with placeholders. Always restore from a
  real `~/.secrets/secrets.yaml` backup.

## Setup / dev server / gotchas

- The `~/.secrets/secrets.yaml` dump file is gitignored at every depth
  (`.secrets/`, `**/.secrets/`, `secrets/secrets.yaml`). If you
  accidentally created one in the repo, the `.gitignore` won't help —
  untrack it with `git rm --cached`.
- `backup-mercury-state.sh` captures `/etc/systemd/{system,user}` and
  `/etc/nginx` — paths in the tarball are stored **without leading
  `/`**, so extracting at the wrong cwd cannot clobber. After
  extraction, `/etc/*` files will be owned by root regardless of which
  user extracted (tar preserves ownership metadata).
- The boot volume `/dev/sda` is **not** snapshotted on purpose
  (Always Free = 5 block-volume-backup slots; the boot volume changes
  rarely and re-imaging Ubuntu is fast). DR for `/dev/sda` loss =
  reimage + restore-secrets + restore.sh + restore tarball from
  `/dev/sdb`.
- `audit.sh` reports `hermes.mercury.garden` as enabled even though it
  is decommissioned. This is intentional — see
  `inventory.yaml → services.nginx.decommissioned_vhosts`.
- `cron` is intentionally empty in the inventory's `user_crontab`
  field. All scheduling lives in hermes (`~/.hermes/cron/jobs.json`),
  captured by `capture.sh`, not via `crontab -e`.

## Repo-local OpenCode config

`tooling/opencode/opencode.jsonc.template` is the template for
`~/.config/opencode/opencode.jsonc` (the live config lives outside
the repo and contains the real `CONTEXT7_API_KEY` and `Authorization`
header). The template is wired into the secrets-restore path through
`secrets.yaml.template` placeholders. Don't edit the live file from
inside this repo — it isn't here.

`tooling/opencode/AGENTS.MD` is a generic behavioral guide (Think
before coding, Simplicity first, Surgical changes, Goal-driven
execution). Read it once for shared coding etiquette, then come back
here for repo-specific facts.

There is no `.codegraph/` for this repo (it is gitignored at depth),
so use Grep/Glob/Read directly when searching this codebase — the
codegraph MCP tools are for the other projects under `~/data/code/`.

## Out of scope for this repo

- Anything in `~/data/code/<project>/` lives in its own repo with its
  own AGENTS.md, tests, CI, etc. This repo only references them via
  `inventory.yaml → projects`.
- `/etc/letsencrypt`, `/etc/nginx`, `/etc/systemd/{system,user}` are
  tracked in `nginx/sites-available/`, `systemd/{system,user}/`, and
  the secrets inventory only — the live runtime state lives on the
  host and is captured by `backup-mercury-state.sh`.