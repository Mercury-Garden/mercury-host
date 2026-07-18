# openwiki — repository-documentation agent

Declarative record of the OpenWiki install on mercury. OpenWiki is a CLI
that generates and maintains a Markdown wiki for a codebase and patches
`AGENTS.md` / `CLAUDE.md` to point at that wiki — primarily for coding
agents that need durable, low-context-load repo reference docs.

- **Source:** https://github.com/langchain-ai/openwiki
- **npm package:** [`openwiki`](https://www.npmjs.com/package/openwiki)
- **Version pinned on mercury:** `0.0.3` (npm registry; refreshed by `capture.sh` from the mise-managed npm prefix)
- **Node pin:** `24.x` (the global mise toolchain pin; resolves to the latest 24.x.x at install time — was 24.18.0 on 2026-07-18)
- **Install method:** `npm install -g openwiki` against the mise-managed Node 24.x prefix (was a volta global package pre-2026-07-18; volta was retired)
- **Binary path:** `/home/ubuntu/data/.local/share/mise/installs/node/24/bin/openwiki` (the mise-managed node bin dir)
- **Config dir:** `~/.openwiki/` (created on first run; stores `.env` with provider credentials)

## What mercury uses this for

The Mercury-Garden agent fleet (`mercutio`, `hermes-gateway`, etc.) reads
`AGENTS.md` from every repo at the start of a session. That file is the
wrong place for hundreds of pages of repo documentation — it would blow
the per-call token budget. OpenWiki instead generates a `openwiki/`
directory of per-file docs and patches `AGENTS.md` with a one-line
reference instructing the agent to consult `openwiki/` when it needs
repo context.

This is useful in particular for `mercury-host` itself: the IaC docs
(9-area taxonomy, capture.sh pitfalls, audit.sh patterns) are spread
across `README.md`, `AGENTS.md`, and dozens of `references/*.md` files.
OpenWiki would condense them into a navigable `openwiki/` tree and keep
it current as the repo evolves (via the GitHub Action cron).

## Install (recovery)

```bash
# mise + npm provision the package against the Node 24.x install at
# /home/ubuntu/data/.local/share/mise/installs/node/24/. mise manages
# node itself but delegates npm globals to the npm registry directly.
# This is the canonical, idempotent reinstall on a fresh mercury host:
PATH=/home/ubuntu/data/.local/share/mise/installs/node/24/bin:$PATH npm install -g openwiki
```

The binary lands at `/home/ubuntu/data/.local/share/mise/installs/node/24/bin/openwiki`
(already on PATH via `packages/node.yaml → path_order_required` once
`~/.zshrc` has been re-sourced post-migration). The package itself lives
under `.../mise/installs/node/24/lib/node_modules/openwiki/`.

`scripts/capture.sh` does NOT currently refresh a globally-pinned-packages
list (that was a volta-era construct removed in PR #67). The openwiki
version is reflected in `inventory.yaml → openwiki.binary.installed_via`
and verified by `scripts/audit.sh`'s `[openwiki]` section. No inventory
edit needed for version bumps — `devtools-upgrade.ts` (cron) handles
upgrades.

## Verify

```bash
command -v openwiki        # → /home/ubuntu/data/.local/share/mise/installs/node/24/bin/openwiki
npm ls -g --depth=0 | grep openwiki   # → openwiki@0.0.3 ...
bash -c 'audit.sh [openwiki]' 2>&1 || true   # see audit section below
```

## First-run setup (provider + key)

OpenWiki's `openwiki --init` prompts interactively for provider + API key
and writes both to `~/.openwiki/.env` (~/.openwiki/.env). **For mercury we
are intentionally NOT running `--init` in this install** — the audit's
`[openwiki]` section only checks that the binary is present and that the
expected `~/.openwiki/.env` shape exists. The user runs `--init` by hand
once a Minimax coding-plan API key is available, and the inventory's
`openwiki:` block (with `provider: anthropic`, `base_url:
https://api.minimax.io/anthropic`, `model: MiniMax-M3`, `key_present:
true` once set) keeps the audit honest.

Reference: minimax coding-plan = Anthropic-compatible surface
(`https://platform.minimax.io/` per openwiki README; `api.minimax.io` is
the documented OpenAI-compatible mirror used by Hermes for fallback).

To run `--init`:

```bash
openwiki --init
# Provider:     anthropic
# Model:        MiniMax-M3
# Base URL:     https://platform.minimax.io  (NOT api.minimax.io; that
#                                          one is the OpenAI-compatible
#                                          mirror that lives at /v1,
#                                          not /anthropic)
# API key:      <your minimax coding-plan key — see secrets/inventory.yaml>
```

## Trigger docs updates on a repo

After `openwiki --init` against a target repo (e.g. `cd ~/data/code/mercury-host && openwiki --init`),
the repo gets:

1. An `openwiki/` directory with the generated wiki.
2. A reference appended to `AGENTS.md` (or `CLAUDE.md` if that exists)
   instructing any agent reading the file to consult `openwiki/`.

For ongoing updates, copy
[examples/openwiki-update.yml](https://github.com/langchain-ai/openwiki/blob/main/examples/openwiki-update.yml)
into the target repo's `.github/workflows/`. That workflow uses git diffs
from the last openwiki run to figure out what to refresh.

## Audit

`scripts/audit.sh` runs an `[openwiki]` section (added in the PR that
installed this package) checking:

1. `openwiki` binary is on PATH.
2. `~/.openwiki/.env` exists with `OPENWIKI_PROVIDER`, `ANTHROPIC_API_KEY`
   (presence only — never the value), and `ANTHROPIC_BASE_URL` set to
   `https://platform.minimax.io`.
3. `OPENWIKI_MODEL_ID` matches the inventory's `model:` value.

A working key is **not** required for the audit to be green — the
`keys_present` field is a presence check, not a validity check. To
verify the key actually works, run `cd ~/data/code/<repo> && openwiki
"please summarize"` interactively (separate from the audit).

## Recoverability

**Recoverable.** Nothing here is irreplaceable:

- The npm package is reinstalled via `npm install -g openwiki` (with the mise-managed node bin on PATH).
- The config file `~/.openwiki/.env` regenerates on next `openwiki --init`
  (the API key is the only loss — and the key lives in
  `secrets/inventory.yaml → openwiki-api-key` as a pointer).
- Per-repo `openwiki/` trees regenerate on next `openwiki --init` against
  the repo; the bot's `AGENTS.md` patch is also regenerated.

If mercury is wiped: re-install mise + node, run `npm install -g openwiki`,
restore the key, run `openwiki --init` against the repos you want
documented. Done.

## Companion deps

- **Node 24.x** — pinned via mise (`node = "24"` floating in
  `~/.config/mise/config.toml`; resolved to 24.18.0 on 2026-07-18).
- **`@anthropic-ai/sdk`** + `better-sqlite3` — pulled in transitively by
  `openwiki`. Both land under
  `.../mise/installs/node/24/lib/node_modules/`.
- No system-level deps; no apt packages.

## Companion config (in this repo)

- `inventory.yaml → openwiki:` — provider pin, model pin, key-presence check.
- `secrets/inventory.yaml → openwiki-api-key` — pointer to `~/.openwiki/.env`.
- `packages/node.yaml` — Node 24.x pin (toolchain); openwiki is not pinned there (volta-era `globally_pinned_packages` block was removed in PR #67).
- `scripts/audit.sh → [openwiki]` — drift section added in the install PR.
