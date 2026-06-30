# mercury-host

> Declarative state of `mercury` — the Oracle Cloud Ubuntu host that runs Mercury Garden.

This repo describes **what this host is**: every systemd unit it owns, every nginx vhost it serves, the AI/agent tools it has installed, its shell/editor setup, the Node.js toolchain (Volta), the projects under `~/data/code/`, and where its secrets live (pointers only, never values).

The companion scripts — `scripts/capture.sh` and `scripts/audit.sh` — let you (a) regenerate the declarative files from the live host, and (b) check a live host against this repo and report drift.

For secrets, `scripts/backup-secrets.sh` snapshots every host secret to `~/.secrets/secrets.yaml` (mode 0600), and `scripts/restore-secrets.sh` is the inverse. The matching `secrets/secrets.yaml.template` is the sanitized version that's safe to commit.

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
host.yaml                      # machine identity
inventory.yaml                 # single source of truth — every owned piece of state
systemd/                       # unit files this host owns
  system/                      # /etc/systemd/system/*
  user/                        # ~/.config/systemd/user/*
nginx/                         # vhosts + conf.d + snippets this host owns
letsencrypt/                   # README on cert renewal (no private keys)
tooling/                       # AI/agent tool configs (declarative only)
  hermes/                      # ~/.hermes (config.yaml, SOUL.md, cron/jobs.json)
  goose/                       # ~/.config/goose (config.yaml, NOT secrets.yaml)
  opencode/                    # ~/.config/opencode (jsonc + plugin pointers)
  claude/                      # skills as pointers, not contents
  agents/
shell/                         # zsh + oh-my-zsh + starship
git/                           # .gitconfig minus creds
gh/                            # hosts.yml minus tokens
ssh/                           # ~/.ssh/config minus private keys
secrets/                       # secrets/inventory.yaml — name → location → rotation procedure
packages/                      # apt.list, snap.yaml, cargo.yaml, node.yaml
network/                       # hostname, hosts, vcn notes
projects/                      # tracked projects under ~/data/code/
scripts/                       # capture.sh, audit.sh, restore.sh
.github/workflows/             # CI gate (lint-yaml, shellcheck, secrets-scan)
```

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
```

## Secrets backup & restore

`scripts/backup-secrets.sh` reads every secret this host depends on and writes them to `~/.secrets/secrets.yaml` (mode 0600, dir mode 0700). The structure mirrors `secrets/inventory.yaml` one-for-one: each top-level key in the YAML corresponds to a `secrets:` entry, and each value is either a base64 literal block (for binary-ish files like SSH keys and certs) or a quoted scalar (for tokens).

The matching `secrets/secrets.yaml.template` is the sanitized version with every value replaced by a `<set from ...>` placeholder. The real file is gitignored.

**What the dump covers:**

| Key | Source on host |
|---|---|
| `ssh_ed25519_private`, `ssh_ed25519_public` | `~/.ssh/id_ed25519{,pub}` |
| `gh_hosts_yml` | `~/.config/gh/hosts.yml` |
| `gh_token_env` | `~/.hermes/.env` `GITHUB_TOKEN=` line |
| `oauth2_client_secret`, `oauth2_cookie_secret` | `~/.config/oauth2-proxy/oauth2-proxy.cfg` |
| `hermes_env` | `~/.hermes/.env` (full file) |
| `goose_secrets` | `~/.config/goose/secrets.yaml` |
| `letsencrypt_account_key`, `letsencrypt_privkey` | `/etc/letsencrypt/{accounts,live}/...` |
| `mercury_tasks_tokens` | `/home/ubuntu/.config/mercury-tasks/tokens.json` |
| `x_digest_env` | `~/data/code/x-digest/.env` |
| `openchamber_startup_env` | `/home/ubuntu/.config/openchamber/startup.env` |

`scripts/restore-secrets.sh` is the inverse. It accepts `--include <kind>` to scope the restore to a subset (`ssh,github,oauth2,hermes,goose,letsencrypt,mercury-tasks,x-digest,openchamber`), and `--dry-run` to preview without writing. The script round-trips byte-identical for every file type (verified locally before commit).

**Bootstrap a fresh host:**

1. Clone this repo.
2. Copy a real backup into place: `scp mercury:.secrets/secrets.yaml ~/.secrets/`
3. Run `bash scripts/restore-secrets.sh` (or `--include <kind>` to stage one subsystem at a time).
4. Restart services: `systemctl --user restart hermes-gateway mercury-tasks oauth2-proxy webhook-server openchamber` and `sudo systemctl restart nginx`.

**Rotation:** re-run `scripts/backup-secrets.sh --force` after rotating any secret. The real file is overwritten in place. The matching inventory entry in `secrets/inventory.yaml` should also be updated with the new rotation date.

## Conventions

- **YAML over JSON** for human-edited files; JSON only when an upstream tool requires it.
- **Comments in `.example` files**, real values in `.local` files that are gitignored.
- **Lockfile SHAs tracked** in `projects/*/lockfile.sha256` so the audit can detect uncommitted dependency changes.
- **One PR per concern.** First PR is bootstrap (this one). Subsequent PRs add specific subsystems (systemd units, nginx vhosts, etc.).