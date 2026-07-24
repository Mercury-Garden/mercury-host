# Tasks — openviking-openrouter-env-fix (PR #107)

## 0. Pre-flight (no writes, no commits)

- [x] Verify the parent arc (#101) merged — `~/.openviking/ov.conf`
  uses `${OPENROUTER_API_KEY}` substitution.
- [x] Verify `OPENROUTER_API_KEY` is in `~/.hermes/.env` (mode 0600).
- [x] Verify the pre-fix state: `~/.openviking/.openrouter-env` does
  NOT exist; openviking-server is `active` but the env var is empty
  in its process namespace.

## 1. Spec — openspec/changes/archive/2026-07-24-openviking-openrouter-env-fix/

- [x] Create `openspec/changes/archive/2026-07-24-openviking-openrouter-env-fix/proposal.md`
  with the Task Signature / Input / Root cause / Rubric / Approach /
  Evidence / Linked Experiences sections.
- [x] Create this `tasks.md` checklist.
- [x] `git add openspec/changes/archive/2026-07-24-openviking-openrouter-env-fix/`

## 2. Code — declarative files

- [x] Create `systemd/user/openviking-prepare-openrouter-env.sh` (24 lines):
  - [x] `set -euo pipefail`
  - [x] `install -m 0600 /dev/null "$ENV_OUT"` to materialize the
    tempfile with the right mode (avoid TOCTOU race)
  - [x] `set -a; . "${HOME}/.hermes/.env"; set +a` to source all vars
  - [x] `if [ -z "${OPENROUTER_API_KEY:-}" ]; then FATAL+exit 1`
  - [x] `printf 'OPENROUTER_API_KEY=%s\n' "$OPENROUTER_API_KEY" > "$ENV_OUT"`
  - [x] `chmod 0600 "$ENV_OUT"` belt-and-suspenders (install already
    set 0600; the chmod is defensive in case the script is run by hand)
  - [x] SC1091 disable comment with rationale (non-resolvable source
    path under static analysis because HOME isn't known until runtime)
- [x] Modify `systemd/user/openviking-server.service`:
  - [x] Add `ExecStartPre=%h/.openviking/openviking-prepare-openrouter-env.sh`
  - [x] Add `EnvironmentFile=%h/.openviking/.openrouter-env`
  - [x] Keep `ExecStart=` and `WorkingDirectory=` as before
  - [x] Add inline comment explaining why the materialize-script pattern
    was chosen over the alternatives (inline key = leaks via gitleaks;
    source whole .env = injects unrelated secrets into OpenViking)

## 3. Sync to host + restart

- [x] `git push origin fix/openviking-openrouter-env` from the working branch
- [x] PR #107 opened, CI green, reviewed by edsadr, merged
- [x] `cd /home/ubuntu/data/code/mercury-host && git pull --ff-only origin main`
  (so the symlink at `~/.config/systemd/user/openviking-server.service`
  picks up the new unit file)
- [x] `systemctl --user daemon-reload`
- [x] `systemctl --user restart openviking-server`
- [x] Verify `~/.openviking/.openrouter-env` materialized with mode 0600
- [x] Verify `ExecStartPre=` exited `status=0/SUCCESS`
- [x] Verify `curl http://127.0.0.1:1933/health` returns
  `{"status":"ok","healthy":true}`

## 4. Post-merge cleanup

- [ ] (this PR) Add the sync-and-archive entry to
  `openspec/changes/archive/2026-07-24-openviking-openrouter-env-fix/`
  (proposal.md, tasks.md, README.md)
- [ ] (after this PR merges) Delete the local `fix/openviking-openrouter-env`
  branch with `git branch -d fix/openviking-openrouter-env`
- [ ] (after this PR merges) Verify the archive dir lives on `main`
  with `ls openspec/changes/archive/ | grep openviking-openrouter-env`

## 5. Out of scope (tracked separately)

- **audit.sh drift check for openviking auth health** — adding a
  `curl /health` + assert `auth_mode` match check would have caught
  this sooner. Rubric criterion `openviking_healthy_post_restart`
  gets promoted to a `[openviking-server]` block check. Estimated
  ~20 lines, single PR, opens after this archive merges.

- **OpenViking 0.4.10 semantic search bug** — the `/api/v1/search/search`
  endpoint currently returns 0 hits even though the vector store has
  10 valid Qwen embeddings with norm 1.0. This appears to be a
  content-truncation or threshold-filter bug in OpenViking 0.4.10, not
  an auth problem. Tracked separately; embedding and storage paths
  are healthy. (Mentioned in the commit body of #107 but explicitly
  marked out of scope.)
