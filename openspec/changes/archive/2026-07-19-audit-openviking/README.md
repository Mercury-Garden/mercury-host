# Arc archive: audit-openviking

**Date archived:** 2026-07-19
**Arc step:** feat → sync-and-archive
**Source PR:** [#78](https://github.com/Mercury-Garden/mercury-host/pull/78)
**Implementing PR:** [#78](https://github.com/Mercury-Garden/mercury-host/pull/78)
**Archive marker:** `2026-07-19-audit-openviking`

## What this arc delivered

PR #78 (feat(audit): actively verify openviking-server + memory.mercury.garden vhost)
extended three lists in `scripts/audit.sh`:

- **USER_UNITS** — added `openviking-server.service` to the user-unit verification list
- **ACTIVE_24_7** — added openviking-server (active 24/7 as a user unit)
- **NGINX_VHOSTS** — added `memory.mercury.garden` symlink check

The 24/7-active loop was refactored to dispatch on a tagged `kind:name` set so it
can correctly invoke `systemctl --user` for user units and plain `systemctl` for
system units.

**No `openspec/` source delta to sync:** this repo (mercury-host) is a
single-host declarative inventory + bootstrap repo (per `AGENTS.md`). It does
not track specs under `openspec/specs/`. The spec narrative for this arc lives
in the OpenSpec change `openviking-external-memory` (managed in the
opencode/coordination layer, not committed here). This README is the
archive marker so the arc has a closing traceable artifact.

## Verification at archive time

PR #78's local verification (verbatim from the source PR body):

```
$ bash scripts/audit.sh 2>&1 | grep -E 'openviking|memory\.mercury'
✓ openviking-server enabled (user)
✓ openviking-server active (user)
✓ memory.mercury.garden enabled (symlink)
drift count: 0
audit exit: 0
```

CI gates: shellcheck clean, gitleaks clean, yamllint-clean.

## Status

**Arc closed.** No follow-up changes required. The next plan step (Stage 11
'Bake + verify') is satisfied — `audit.sh` now actively verifies what
PR #76 deployed.
