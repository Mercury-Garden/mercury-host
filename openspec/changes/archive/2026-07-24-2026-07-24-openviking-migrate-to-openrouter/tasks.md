# Tasks — openviking-migrate-to-openrouter

## 0. Pre-flight (no writes, no commits)

- [ ] Verify the live host has `OPENROUTER_API_KEY` in `~/.hermes/.env`
  and that the value starts with `sk-or-v1-` (OpenRouter key prefix).
- [ ] Run `bash scripts/audit.sh` and capture the current drift report
  (baseline before any edits).
- [ ] Verify `~/.openviking/ov.conf` currently uses the OpenRouter
  `qwen/qwen3-embedding-8b` + `qwen/qwen3.5-flash-02-23` block (it does
  at the start of this arc — this task is just to confirm the live
  state matches what we expect to commit).
- [ ] Verify `systemctl --user is-active openviking-server.service` is
  `active`.
- [ ] Verify port `127.0.0.1:1933` is the only listener.

## 1. Spec — openspec/changes/2026-07-24-openviking-migrate-to-openrouter/

- [ ] Create `openspec/changes/2026-07-24-openviking-migrate-to-openrouter/proposal.md`
      with the Task Signature / Input / Rubric / Approach / Reflect /
      Evidence / Linked Experiences sections.
- [ ] Create this `tasks.md` checklist.
- [ ] `git add openspec/changes/2026-07-24-openviking-migrate-to-openrouter/`

## 2. Code — declarative files

- [ ] Edit `inventory.yaml` service `openviking-server`:
  - [ ] Add a `model_providers:` sub-block summarising OpenRouter +
        `qwen/qwen3-embedding-8b` (4096-dim) + `qwen/qwen3.5-flash-02-23` VLM.
  - [ ] Remove the obsolete MiniMax reference from the service note.
- [ ] Edit `secrets/inventory.yaml`:
  - [ ] Mark `openviking-minimax-api-key` as `deprecated: true` in a new
        field; update its `note:` to say OpenViking no longer reads it.
  - [ ] Add `openviking-openrouter-api-key` entry pointing at
        `OPENROUTER_API_KEY` in `~/.hermes/.env`, with
        `location_mode: "0600 ubuntu:ubuntu"`, rotation pointing at
        `https://openrouter.ai/settings/keys`.
  - [ ] Update `openviking-ov-conf` `note:` to reflect env-var
        substitution; remove the obsolete
        "schema does not support env-var substitution" claim.
- [ ] Edit `secrets/secrets.yaml.template` header comment to mention
      `openviking-openrouter-api-key` alongside the other keys.
- [ ] Edit `scripts/backup-secrets.sh`:
  - [ ] Add `openviking_openrouter_api_key` capture: read
        `${OPENROUTER_API_KEY}` from `~/.hermes/.env`, emit as b64
        block. Place it near the existing openviking blocks.
  - [ ] Update the openviking section's doc comment to reflect that
        the live provider is OpenRouter and the key comes from
        `OPENROUTER_API_KEY`.
- [ ] Edit `scripts/restore-secrets.sh`:
  - [ ] Add a decoder for `openviking_openrouter_api_key` that writes
        `OPENROUTER_API_KEY=<value>` to `~/.hermes/.env`, appending
        if the line is missing (preserve other entries).
  - [ ] Update the openviking section's `note:` to mention the new
        env-var source.
- [ ] Edit `scripts/openviking-set-concurrency.sh`:
  - [ ] Update the doc header to reflect that model selection now
        lives in `ov.conf` and is OpenRouter-anchored.
- [ ] `git add inventory.yaml secrets/inventory.yaml secrets/secrets.yaml.template scripts/backup-secrets.sh scripts/restore-secrets.sh scripts/openviking-set-concurrency.sh`

## 3. Verification (mandatory before push)

- [ ] `yamllint -c .yamllint.yml --strict inventory.yaml secrets/inventory.yaml secrets/secrets.yaml.template` — clean.
- [ ] `shellcheck scripts/backup-secrets.sh scripts/restore-secrets.sh scripts/openviking-set-concurrency.sh` — clean.
- [ ] `bash scripts/audit.sh` — no new drift; capture the
      `[openviking]` section and confirm the section reads
      "PASS: ov.conf present, mode 0600, key=env-substituted,
      OpenRouter Qwen".
- [ ] (manual, on host) Confirm `~/.openviking/ov.conf` still
      `mode 0600` and still has the OpenRouter provider block.
- [ ] (manual, on host) Confirm `~/.hermes/.env` contains
      `OPENROUTER_API_KEY=sk-or-v1-...` (do not echo the value).
- [ ] (manual, on host) `bash scripts/backup-secrets.sh --force` and
      confirm the resulting `~/.secrets/secrets.yaml` contains both
      `openviking_openrouter_api_key` and the legacy
      `openviking_minimax_api_key` blocks.
- [ ] (manual, on host) `bash scripts/restore-secrets.sh --include openviking --dry-run` reports
      "would write OPENROUTER_API_KEY to ~/.hermes/.env" without
      actually writing.

## 4. Commit + PR

- [ ] `git add` the openspec folder + the modified declarative files.
- [ ] `git commit -m "feat(openviking): migrate embedding + VLM to OpenRouter"`.
- [ ] Push branch: `git push origin feat/openviking-openrouter`.
- [ ] `gh pr create --base main --head feat/openviking-openrouter
        --title "feat(openviking): migrate embedding + VLM to OpenRouter (Qwen3-Embedding 8B + Qwen3.5-Flash)" --body "..."`.
- [ ] `gh pr edit --add-assignee edsadr --add-reviewer edsadr`.
- [ ] Wait for CI green (yamllint / shellcheck / gitleaks / audit).

## 5. Merge + post-merge

- [ ] Squash-merge on GitHub.
- [ ] `git checkout main && git pull --rebase --autostash` to absorb.
- [ ] Delete the work branch: `git push origin --delete feat/openviking-openrouter`.
- [ ] Confirm on host: `cat ~/.openviking/ov.conf | head -20` shows
      the OpenRouter block still (hot-reload picked up earlier changes;
      post-merge there is no config to change).

## 6. Rollback (only if Step 3 verification fails post-merge)

- [ ] `git revert <merge-commit>` and merge the revert.
- [ ] On host: `cp ~/.openviking/ov.conf.bak-stage1 ~/.openviking/ov.conf`
      and `systemctl --user restart openviking-server`. This restores
      the MiniMax provider.
