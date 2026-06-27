# mercury-host

> Declarative state of `mercury` — the Oracle Cloud Ubuntu host that runs Mercury Garden.

This repo describes **what this host is**: every systemd unit it owns, every nginx vhost it serves, the AI/agent tools it has installed, its shell/editor setup, the Node.js toolchain (Volta), the projects under `~/data/code/`, and where its secrets live (pointers only, never values).

The companion scripts — `scripts/capture.sh` and `scripts/audit.sh` — let you (a) regenerate the declarative files from the live host, and (b) check a live host against this repo and report drift.

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
```

## Conventions

- **YAML over JSON** for human-edited files; JSON only when an upstream tool requires it.
- **Comments in `.example` files**, real values in `.local` files that are gitignored.
- **Lockfile SHAs tracked** in `projects/*/lockfile.sha256` so the audit can detect uncommitted dependency changes.
- **One PR per concern.** First PR is bootstrap (this one). Subsequent PRs add specific subsystems (systemd units, nginx vhosts, etc.).