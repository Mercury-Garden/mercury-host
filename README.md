# mercury-host

> Declarative state of `mercury` — the Oracle Cloud Ubuntu host that runs Mercury Garden.

This repo describes **what this host is**: every systemd unit it owns, every nginx vhost it serves, the AI/agent tools it has installed, its shell/editor setup, the Node.js toolchain (mise — Volta was retired 2026-07-18), the projects under `~/data/code/`, and where its secrets live (pointers only, never values).

The companion scripts — `scripts/capture.sh` and `scripts/audit.sh` — let you (a) regenerate the declarative files from the live host, and (b) check a live host against this repo and report drift.

For secrets, `scripts/backup-secrets.sh` snapshots every host secret to `~/.secrets/secrets.yaml` (mode 0600), and `scripts/restore-secrets.sh` is the inverse. The matching `secrets/secrets.yaml.template` is the sanitized version that's safe to commit.

For full host state, `scripts/backup-mercury-state.sh` runs daily via systemd timer and produces a `zstd`-compressed tarball of every irreplaceable config dir on the host (see [State backup](#state-backup--oracle-cloud-block-volume)). Oracle Cloud also takes monthly snapshots of the data block volume `/dev/sdb` automatically — see [Oracle Cloud Block Volume backup](#oracle-cloud-block-volume-backup).

## Why this exists

Two operational pressures:

1. **Rebuild in 30 minutes, not 3 days.** If `mercury` dies tomorrow, `scripts/restore.sh` on a fresh Ubuntu 24.04 image should get back to a working Mercury Garden without relying on tribal memory.
2. **Drift visibility.** When something on the host silently changes (a service restarts with new config, a package gets upgraded, a tool version moves), `scripts/audit.sh` should notice.

## What this is NOT

- Not Terraform / Pulumi / Ansible. There is no remote apply — this is documentation + scripts.
- Not a secrets vault. **No secrets live here.** SSH private keys, GitHub tokens, OAuth client secrets, Letsencrypt private keys, `~/.hermes/.env`, `~/.config/goose/secrets.yaml` — all referenced from `secrets/inventory.yaml` as pointers only.
- Not a mirror of upstream defaults. Only state that this host *owns* is tracked.

## Layout

```
host.yaml                      # machine identity + Oracle Cloud metadata
inventory.yaml                 # single source of truth — every owned piece of state
                               #   (sections: services, nginx, packages, projects,
                               #    cron, state_backup, oci_block_volume, etc.)
network/                       # hostname, hosts, vcn notes
  README.md                    # what network/ tracks + how
  vcn-topology.md              # Oracle VCN CIDR + peering notes
nginx/                         # vhosts + conf.d + snippets this host owns
packages/                      # apt.list, snap.yaml, cargo.yaml, node.yaml
secrets/                       # inventory.yaml (pointers only) + secrets.yaml.template
                               # (sanitized example; real secrets.yaml is gitignored)
scripts/                       # capture.sh, audit.sh, restore.sh, backup-secrets.sh,
                               # restore-secrets.sh, backup-mercury-state.sh
shell/                         # zsh + oh-my-zsh + starship
systemd/                       # unit files this host owns
  system/                      # /etc/systemd/system/*
  user/                        # ~/.config/systemd/user/*
tooling/                       # AI/agent tool configs (declarative only)
  goose/                       # ~/.config/goose (config.yaml, NOT secrets.yaml)
  oauth2-proxy/                # oauth2-proxy.cfg.example (template only; real cfg has secrets)
  opencode/                    # ~/.config/opencode (jsonc + plugin pointers)
  skills-manifest.yaml         # list of installed agent skills (paths only, not contents)
.github/workflows/             # CI gate (lint-yaml, shellcheck, secrets-scan)
```

**Not in the repo** (intentional — captured by `scripts/backup-mercury-state.sh` instead):
- `~/.hermes`, `~/.config/*`, `~/.local/share/opencode`, `~/.plannotator`, `~/.codegraph`,
  `~/.ssh`, `~/.gnupg`, `~/.oh-my-zsh/custom`, `~/.zshrc` and other shell configs,
  `~/bin/`, `~/update.sh`, `~/certbot-dns-hook.sh`, `~/wildcard-cert-instructions.md`,
  `/etc/systemd/{system,user}`, `/etc/nginx`, `/etc/letsencrypt`. See §"State backup" below.

## Quick start

```bash
# Audit this host against this repo
bash scripts/audit.sh

# Regenerate the declarative files from the live host
bash scripts/capture.sh

# Rebuild a fresh Ubuntu 24.04 host to match this repo
bash scripts/restore.sh

# Snapshot every host secret to ~/.secrets/secrets.yaml (mode 0600)
bash scripts/backup-secrets.sh

# Restore host secrets from a backup file
bash scripts/restore-secrets.sh --dry-run             # preview
bash scripts/restore-secrets.sh /path/to/secrets.yaml # apply
bash scripts/restore-secrets.sh --env x-digest/.env   # restore ONE .env under ~/data/code/
bash scripts/restore-secrets.sh --include code-env    # restore ALL auto-discovered .env* files

# Snapshot full host state (irreplaceable configs) to a daily tarball
bash scripts/backup-mercury-state.sh                  # one-off
sudo systemctl status mercury-state-backup.timer     # daily at 03:00 America/Bogota
```

## Secrets backup & restore

`scripts/backup-secrets.sh` reads every secret this host depends on and writes them to `~/.secrets/secrets.yaml` (mode 0600, dir mode 0700). The top-level keys in the dump are the **output names from `backup-secrets.sh`** (snake_case, e.g. `ssh_ed25519_private`, `letsencrypt_privkey`). The authoritative **pointer list** (kebab-case ids + locations + rotation procedures) lives in `secrets/inventory.yaml`; see the table there for which keys have entries.

The matching `secrets/secrets.yaml.template` is the sanitized version with every value replaced by a `<set from ...>` placeholder. The real file is gitignored.

**What the dump covers** (output keys from `~/.secrets/secrets.yaml`, mirroring `scripts/backup-secrets.sh`):

| Output key | Source on host | Inventory id |
|---|---|---|
| `ssh_ed25519_private`, `ssh_ed25519_public` | `~/.ssh/id_ed25519{,pub}` | `ssh-ed25519-private`, `ssh-ed25519-public` |
| `gh_hosts_yml` | `~/.config/gh/hosts.yml` | `gh-hosts-yml` |
| `gh_token_env` | `~/.hermes/.env` GITHUB_TOKEN value | `gh-token-env` |
| `oauth2_client_secret`, `oauth2_cookie_secret` | `~/.config/oauth2-proxy/oauth2-proxy.cfg` | `oauth2-client-secret`, `oauth2-cookie-secret` |
| `hermes_env` | `~/.hermes/.env` (full file) | `hermes-env` |
| `goose_secrets` | `~/.config/goose/secrets.yaml` | `goose-secrets` |
| `letsencrypt_account_key`, `letsencrypt_privkey` | `/etc/letsencrypt/{accounts,live}/...` | `letsencrypt-account-key`, `letsencrypt-privkey` |
|| `mercury_tasks_tokens` | `/home/ubuntu/.config/mercury-tasks/tokens.json` | `mercury-tasks-tokens` |
|| `x_digest_env` | `~/data/code/x-digest/.env` | `x-digest-env` (deprecated → `code-env-files`) |
|| `scriptcaster_env` | `~/data/code/scriptcaster/.env` | `scriptcaster-env` (deprecated → `code-env-files`) |
|| `code_env_<sanitized-path>` | every `.env*` under `~/data/code/` (auto-discovered, excludes `*.example`) | `code-env-files` |
|| `openchamber_startup_env` | `~/.config/openchamber/startup.env` | `openchamber-startup-env` |
| `opencode_auth` | `~/.local/share/opencode/auth.json` (3 provider API keys) | `opencode-auth` |
| `discord_notify_config` | `~/.config/discord-notify/config.yaml` (4 per-project HMAC + chat IDs) | `discord-notify-config` |
| `gogcli_credentials`, `gogcli_keyring_tar_gz` | `~/.config/gogcli/credentials.json` + `keyring/` packed as tar.gz | `gogcli-credentials` |
| `webhook_server_secret`, `webhook_server_projects` | `~/.config/webhook-server/secret.txt` + `projects.yaml` | `webhook-server-secret`, `webhook-server-projects` |

`scripts/restore-secrets.sh` is the inverse. It accepts `--include <kind>` to scope the restore to a subset (`ssh,github,oauth2,hermes,goose,letsencrypt,mercury-tasks,x-digest,scriptcaster,code-env,openchamber,opencode,gogcli`), `--dry-run` to preview without writing, and `--env <path-or-kind>` to restore ONE auto-discovered `.env` under `~/data/code/` and exit (accepts bare repo-relative path, absolute path, or sanitized YAML kind). The script round-trips byte-identical for every file type (verified locally before commit).

**Bootstrap a fresh host:**

1. Clone this repo.
2. Copy a real backup into place: `scp mercury:.secrets/secrets.yaml ~/.secrets/`
3. Run `bash scripts/restore-secrets.sh` (or `--include <kind>` to stage one subsystem at a time).
4. Restart services: `systemctl --user restart hermes-gateway mercury-tasks oauth2-proxy webhook-server openchamber` and `sudo systemctl restart nginx`.

**Rotation:** re-run `scripts/backup-secrets.sh --force` after rotating any secret. The real file is overwritten in place. The matching inventory entry in `secrets/inventory.yaml` should also be updated with the new rotation date.

## State backup & Oracle Cloud Block Volume

This host has two layers of backup:

1. **Local tarball** (daily, 03:00 America/Bogota): `scripts/backup-mercury-state.sh` creates a `zstd -9` tarball of every irreplaceable config dir on the host and writes it to `/home/ubuntu/data/backups/mercury-state-<UTC>.tar.zst` with a sibling manifest JSON and verify JSON.
2. **Oracle Cloud Block Volume snapshot** (monthly, automatic): Oracle's `oracle-cloud-agent` snap takes an incremental snapshot of `/dev/sdb` (the data block volume that holds the backups) on the 1st of each month, retained 90 days.

Together they survive both host-loss (Oracle snapshot → new instance) and accidental-config-loss (yesterday's tarball).

### What the local tarball captures

The exact list is `BACKUP_PATHS` at the top of `scripts/backup-mercury-state.sh` (the
authoritative source — this README mirrors it). At the time of writing:

- **AI/agent tools**: `/home/ubuntu/.hermes`, `/home/ubuntu/.config` (whole tree, including
  `goose/`, `opencode/`, `discord-notify/`, `oauth2-proxy/`, `mercury-tasks/`, `openchamber/`,
  `webhook-server/`, `gogcli/`, `gh/`, `htop/`, `openspec/`, `pnpm/`, `uv/`, etc.),
  `/home/ubuntu/.local/share/opencode`, `/home/ubuntu/.oh-my-zsh/custom`
- **Code graph + plans**: `/home/ubuntu/.plannotator`, `/home/ubuntu/.codegraph`
- **Security**: `/home/ubuntu/.ssh` (config + public keys; private key captured by
  `backup-secrets.sh`, not here), `/home/ubuntu/.gnupg`
- **Repos**: `/home/ubuntu/data/code/mercury-host` (this repo)
- **Scripts**: `/home/ubuntu/bin`, `/home/ubuntu/update.sh`,
  `/home/ubuntu/certbot-dns-hook.sh`, `/home/ubuntu/wildcard-cert-instructions.md`
- **Shell**: `/home/ubuntu/.zshrc`, `/home/ubuntu/.zshenv`, `/home/ubuntu/.profile`,
  `/home/ubuntu/.gitconfig` (`.bashrc` and `.gitignore_global` are not captured —
  the host only uses zsh, not bash, and there is no global gitignore)
- **System config**: `/etc/systemd/system`, `/etc/systemd/user`, `/etc/nginx`,
  `/etc/letsencrypt`

**Excluded** (`EXCLUDES` in `scripts/backup-mercury-state.sh`, authoritative): `*.log`,
`*.log.*`, `__pycache__`, `*.pyc`, `*.wasm`, `*.map`, `node_modules`, `.pnpm-store`,
`coverage`, `test-results`, `playwright-report`, `web/dist`, `.git`, `.cache`,
`.cargo/registry`, `.rustup/toolchains`, `.npm`, `.bun`, `.local/share/uv`,
`.local/share/pnpm/store`, `.local/share/Trash`, `.local/share/mise`, `.volta`
(legacy — to be removed post-Phase-5; tar skips non-existent paths), `.secrets/secrets.yaml`.

### Restore from the local tarball

Tarballs live in `/home/ubuntu/data/backups/`. To find them:

```bash
ls -lh /home/ubuntu/data/backups/mercury-state-*.tar.zst
```

**Single file** (fastest, no full restore needed):

```bash
tar -I zstd -xf /home/ubuntu/data/backups/mercury-state-2026-06-30T19-50-28Z.tar.zst \
  home/ubuntu/.zshrc \
  -C /tmp/restore/
sudo cp /tmp/restore/home/ubuntu/.zshrc /home/ubuntu/.zshrc
```

**Whole tarball** (review first with `--diff`):

```bash
sudo tar -I zstd -xf /home/ubuntu/data/backups/mercury-state-2026-06-30T19-50-28Z.tar.zst \
  -C / --ignore-failed-read
```

Note: paths in the tarball are stored **without leading `/`** (so you can't accidentally clobber by extracting at the wrong cwd). After extraction, files in `/etc/*` will be owned by root regardless of which user extracted (because tar preserves ownership metadata).

### Verify the latest tarball

```bash
# 1. Read the verify JSON (integrity check ran at backup time)
cat /home/ubuntu/data/backups/mercury-state-*.verify.json | jq .

# 2. Read the manifest (file list, sizes, mtimes)
jq -r '.files[] | "\(.size)\t.path"' /home/ubuntu/data/backups/mercury-state-*.manifest.json

# 3. Re-run the backup to refresh verification
bash scripts/backup-mercury-state.sh
```

A green verify JSON means 5 files were extracted and diff'd against the live source with byte-identical results: 1 pinned to a privileged-path list (`.ssh`, `/etc/nginx`, `.env`, ollama cloud auth, mercury-host inventory.yaml) and 4 random picks from the rest. The pinning exists because random-only sampling is dominated by `~/.hermes/hermes-agent/` (~97% of archive entries), so without the pin all 5 samples tend to land there and the verify result tells us nothing about the 3% that's actually irreplaceable.

### Schedule, retention, logs

- **Schedule**: `mercury-state-backup.timer` fires daily at 03:00 `America/Bogota` (= 08:00 UTC), `Persistent=true` so missed runs catch up after reboot.
- **Retention**: `find -mtime +7` keeps the 7 most recent tarballs. At ~500 MB per day, that's ~3.5 GB on `/dev/sdb` (which has 45 GB free).
- **Logs**: `~/.local/state/mercury-state-backup/backup.log` (the XDG state dir; always user-writable), plus the systemd journal (`journalctl -u mercury-state-backup.service`).
- **Capture**: `scripts/capture.sh` refreshes the `state_backup:` block in `inventory.yaml` with the latest tarball's timestamp, size, and compression ratio.
- **Audit**: `scripts/audit.sh` warns if no fresh backup exists (default 36 h threshold).

## Oracle Cloud Block Volume backup

In addition to the local tarball, Oracle Cloud takes **monthly incremental snapshots** of the data block volume `/dev/sdb`. This is the volume that holds `/home/ubuntu/data` (projects, backups, codegraph data) — a separate physical disk from the boot volume.

### What is backed up

Everything on `/dev/sdb` — including the latest 7 days of `mercury-state-*.tar.zst`. So in a full host-loss scenario, restoring from the Block Volume snapshot gives you the tarball set used to recreate everything else.

### Restore from a Block Volume snapshot

The restore workflow is **detach → attach**:

```bash
# 1. From your laptop with OCI CLI configured, list backups:
oci bv volume-backup list \
  --volume-id ocid1.volume.oc1.us-chicago-1.abxxeljthy26gscgtw3evixaosbfvofmkh52y364u2kz5zmbvxyzvriobulq \
  --region us-chicago-1

# 2. Restore a backup into a new volume:
oci bv volume create --availability-domain gKwy:US-CHICAGO-1-AD-1 \
  --region us-chicago-1 \
  --compartment-id ocid1.tenancy.oc1..aaaaaaaamwf47b2mqs2uqs3mina7kqvexqhxzzov6ocgmgbm5pxyi5mn65pq \
  --source-volume-backup-id <backup-ocid>

# 3. Attach to a fresh instance (or the rebuilt one):
oci compute volume-attachment create \
  --instance-id <instance-ocid> \
  --volume-id <new-volume-ocid> \
  --attachment-type paravirtualized
```

### What you still need to set up after a Block Volume restore

The Block Volume snapshot is raw filesystem state — to make it a working host you also need:

1. A fresh Ubuntu 24.04 instance (Oracle Always Free, same region/AD).
2. SSH + secrets restored via `scripts/restore-secrets.sh` from a tarball inside the restored volume.
3. `scripts/restore.sh` from this repo to lay down the systemd units + nginx vhosts + tool configs.
4. The mercury-state tarball from inside the restored volume to recreate `~/*` (see above).

### Free tier note

Oracle Always Free includes **5 Block Volume backups total** (boot volume + data volume combined). The monthly policy on `/dev/sdb` retains 90 days = up to 3 backups. The boot volume is **not** snapshotted — it changes rarely and re-imaging Ubuntu is fast; one less slot burned.

### Disaster recovery summary

| Failure | Recovery |
|---|---|
| Lost a config file | `tar -I zstd -xf /home/ubuntu/data/backups/mercury-state-*.tar.zst home/ubuntu/path/to/file` |
| Lost `/dev/sdb` (data disk) | Restore last Block Volume snapshot → new volume → reattach |
| Lost `/dev/sda` (boot disk) | Reimage Ubuntu + restore-secrets + restore.sh + restore tarball from `/dev/sdb` |
| Lost the host entirely | Same as boot disk — Block Volume persists independently |
| Region-wide outage | Out of scope for Always Free; backups would need cross-region replication |

## Conventions

- **YAML over JSON** for human-edited files; JSON only when an upstream tool requires it.
- **Comments in `.example` files**, real values in `.local` files that are gitignored.
- **Lockfile SHAs tracked** in `projects/*/lockfile.sha256` so the audit can detect uncommitted dependency changes.
- **One PR per concern.** First PR is bootstrap (this one). Subsequent PRs add specific subsystems (systemd units, nginx vhosts, etc.).