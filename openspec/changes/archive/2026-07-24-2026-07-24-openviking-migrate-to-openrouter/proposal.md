# OpenViking — migrate to OpenRouter (Qwen3-Embedding 8B + Qwen3.5-Flash VLM)

## Task Signature

The OpenViking context database (`openviking-server` on `127.0.0.1:1933`,
backed by `memory.mercury.garden`) currently embeds via the MiniMax
`embo-01` API and extracts memory via `MiniMax-M3` — both called
directly through `~/.openviking/ov.conf` with the MiniMax key inlined.

The MiniMax embedding API has been intermittently rate-limited
(observed `rate limit exceeded(RPM)` errors in the OpenViking server log
on 2026-07-24, and `openviking-server doctor` reports the embedding
probe as **FAIL** for the same reason). The user has approved migrating
the OpenViking subsystem to OpenRouter so the embedding/VLM providers
have provider-pool redundancy and we can also drop a per-provider key
into the standard `~/.hermes/.env` rather than carrying a parallel key
file at `~/.openviking/.minimax-key`.

Scope of this change is **OpenViking only**. The Hermes gateway's
primary LLM continues to use MiniMax direct (the gateway is configured
in `~/.hermes/.env` and `~/.hermes/config.yaml`, not in this repo).
Other tool stacks that use MiniMax direct — `tooling/openwiki/`,
`tooling/opencode/`, `tooling/faster-whisper/`, `tooling/goose/` — are
out of scope.

## Input

- The current `~/.openviking/ov.conf` has the MiniMax provider pinned
  for both `embedding.dense` and `vlm`. The MiniMax key is inlined in
  the config file, with a parallel copy at `~/.openviking/.minimax-key`
  (mode 0600).
- The OpenViking 0.4.10 server has been observed hot-reloading config
  changes without a service restart (`openviking-server doctor` ran
  immediately after `ov.conf` writes and reported the new provider).
  No service restart is required for the config swap.
- The OpenViking 0.4.10 server's `embedding.dense.api_key` field
  **does** support env-var substitution (`${OPENROUTER_API_KEY}`),
  contrary to the previous note in `secrets/inventory.yaml`. The
  current `ov.conf` on the host uses this substitution and the server
  is live with it.
- A reindex of the 4096-dim vector store was performed on 2026-07-24
  via `POST /api/v1/content/reindex` with `mode=vectors_only` after
  wiping the old 1536-dim store. All 10 memory entries in
  `viking://user/default/peers/hermes/memories/**` are now embedded at
  4096 dims and a known-good semantic search returns the expected
  results.

## Rubric

```
{
  "name": "openviking_openrouter_migration",
  "description": "OpenViking subsystem uses OpenRouter for both embedding and VLM, with secrets scoped to ~/.hermes/.env. Single-mercury-host target.",
  "criteria": [
    {
      "name": "ov.conf uses OpenRouter for both embedding and VLM",
      "description": "~/.openviking/ov.conf has provider=openai, api_base=https://openrouter.ai/api/v1, and uses ${OPENROUTER_API_KEY} substitution for both blocks. No MiniMax reference remains in the file.",
      "required": true,
      "weight": 2.0
    },
    {
      "name": "Secrets inventory updated",
      "description": "secrets/inventory.yaml reflects the new key pointer (openviking-openrouter-api-key → OPENROUTER_API_KEY in ~/.hermes/.env) and marks the legacy openviking-minimax-api-key as deprecated-but-kept for rollback. The obsolete note claiming OpenViking's ov.conf doesn't support env-var substitution is removed.",
      "required": true,
      "weight": 1.5
    },
    {
      "name": "Backup and restore capture the new key",
      "description": "scripts/backup-secrets.sh emits an openviking_openrouter_api_key b64 block sourced from OPENROUTER_API_KEY in ~/.hermes/.env. scripts/restore-secrets.sh writes it back to ~/.hermes/.env (appending if the line is missing, preserving other entries).",
      "required": true,
      "weight": 1.5
    },
    {
      "name": "OpenSpec change folder is present and well-formed",
      "description": "openspec/changes/2026-07-24-openviking-migrate-to-openrouter/ contains proposal.md (this file) and tasks.md. Spec/feat PR arc is recorded in this repo's history.",
      "required": true,
      "weight": 1.0
    },
    {
      "name": "Drift audit runs clean",
      "description": "bash scripts/audit.sh reports no new drift caused by this change. The openviking-minimax-api-key entry is now an expected legacy item (not flagged).",
      "required": true,
      "weight": 1.0
    },
    {
      "name": "Gateway stays on MiniMax direct",
      "description": "Hermes gateway primary LLM continues to use the MiniMax endpoint configured in ~/.hermes/.env + ~/.hermes/config.yaml. This PR does NOT touch the gateway or any other MiniMax-direct subsystem (openwiki, opencode, faster-whisper, goose).",
      "required": true,
      "weight": 2.0
    }
  ]
}
```

## Approach

1. **Track the change in OpenSpec.** New change folder at
   `openspec/changes/2026-07-24-openviking-migrate-to-openrouter/` with
   this `proposal.md` and a `tasks.md` checklist.
2. **Update `inventory.yaml`** for the `openviking-server` service to
   reflect the new model_providers block and remove the MiniMax
   reference.
3. **Update `secrets/inventory.yaml`**:
   - Add `openviking-openrouter-api-key` entry pointing at
     `OPENROUTER_API_KEY` in `~/.hermes/.env`.
   - Mark `openviking-minimax-api-key` as deprecated (still in
     `~/.openviking/.minimax-key` for rollback).
   - Update `openviking-ov-conf` note to reflect env-var substitution
     and remove the obsolete "schema does not support env-var
     substitution" claim.
4. **Update `secrets/secrets.yaml.template`** header comment to mention
   the openviking-sourced key.
5. **Update `scripts/backup-secrets.sh`** to emit
   `openviking_openrouter_api_key` from `OPENROUTER_API_KEY` in
   `~/.hermes/.env`.
6. **Update `scripts/restore-secrets.sh`** to decode
   `openviking_openrouter_api_key` back into `~/.hermes/.env` (append
   if missing).
7. **Update `scripts/openviking-set-concurrency.sh`** doc header to
   reflect that the model selection lives in `ov.conf` and points at
   OpenRouter.

## Reflect

- DO NOT remove the `~/.openviking/.minimax-key` file or the
  `openviking-minimax-api-key` entry from `~/.secrets/secrets.yaml`
  until at least 7 days of stable OpenRouter operation have passed.
  A one-line `ov.conf` flip back to the MiniMax provider block remains
  the rollback path.
- DO NOT touch the Hermes gateway or any of `tooling/openwiki/`,
  `tooling/opencode/`, `tooling/faster-whisper/`, `tooling/goose/` —
  they all continue to use MiniMax direct and are out of scope.
- DO NOT change the systemd unit. `openviking-server.service` is
  provider-agnostic.
- DO NOT add a backup of `${OPENROUTER_API_KEY}` to `ov.conf.bak-*`
  files; those backups live at `~/.openviking/ov.conf.bak-stage{1,2}`
  and contain the env-var name only.
- DO NOT execute any step without explicit per-stage approval. The
  OpenSpec spec→feat→sync-and-archive arc is the contract.

## Evidence

User observed:
- `openviking-server doctor` reported embedding as `FAIL` with
  `rate limit exceeded(RPM)` on 2026-07-24 02:01 UTC and several
  times before.
- Direct retry of `curl https://api.minimax.io/v1/embeddings` with the
  existing `embo-01` model returned `rate limit exceeded(RPM)` errors
  in the same window.
- After swapping the `ov.conf` embedding block to OpenRouter
  `qwen/qwen3-embedding-8b` and reindexing via
  `POST /api/v1/content/reindex`, `openviking-server doctor` reported
  `All checks passed` and a known semantic search for
  "infra_change_workflow stage-gated research plan Notion approval"
  returned the expected top hit at score 0.81.

## Linked Experiences

- `cases/infra_change_research_plan.md` (OpenViking memory) — the
  workflow this change follows.
- `experiences/mercury_infra_research_publish.md` — the publish-then-approve pattern.
- `trajectories/notion_research_page_publish_20260719141831.md` — Notion publish mechanics (NOT used here; the user opted out of a Notion page).
