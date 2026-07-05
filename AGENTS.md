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
| Snapshot irreplaceable state to a daily tarball | `bash scripts/backup-mercury-state.sh` |
| Lint all YAML | `yamllint -c .yamllint.yml --strict .` |
| Lint all bash | `shellcheck scripts/*.sh` |
| Scan for leaked secrets | `gitleaks detect --no-git --redact --exit-code 1 .` |
| Run full CI gate locally (matches `.github/workflows/validate.yml`) | yamllint → shellcheck → gitleaks → `bash scripts/audit.sh || true` |

Order matters: **lint → shellcheck → secrets-scan → audit dry-run**.
That is the order CI runs them in; doing it locally in the same order
catches most issues before push.

## Scripts: behavioral quirks worth knowing

- **`audit.sh` reconstructs the user's PATH before checking volta.**
  Hermes-agent runs under a venv-isolated PATH that hides volta; without
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
  pins Volta, restores systemd user units, but nginx vhost deploy is
  manual (copy to `/etc/nginx/sites-available/`, symlink to
  `sites-enabled/`, `nginx -t && systemctl reload nginx`). The final
  echo lists every manual step.
- **`backup-mercury-state.sh` writes to `/home/ubuntu/data/backups/`
  (NOT `/tmp`).** The boot volume's `/tmp` is small and the script uses
  a temp dir on the data volume. Output is `mercury-state-<UTC>.tar.zst`
  with sibling `manifest.json` and `verify.json`. Exit codes: 0 ok,
  1 tar failed, 2 manifest failed, 3 verify warning (non-fatal),
  4 prune warning (non-fatal).
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
- **Two parallel node toolchains exist.** `volta` (user-facing, pinned
  via `packages/node.yaml`) and `~/.hermes/node` (Hermes gateway's
  bundled runtime, not user-managed — capture.sh refreshes both). PATH
  order is `packages/node.yaml → path_order_required` (pnpm first, then
  volta, then hermes later). Audit checks PATH starts with
  `~/.local/share/pnpm/bin`.
- **Every tracked project must have `volta.node` pinned in
  `package.json`** AND a `lockfile_sha256` in `inventory.yaml`. The
  audit checks both — drift in either is reported as
  `REPRODUCIBILITY`. `capture.sh` regenerates the lockfile SHA but the
  volta pin is the project's responsibility.
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