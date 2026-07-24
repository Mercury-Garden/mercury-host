# omniroute-first-dev-stack

**Status:** in-flight (2026-07-24). One PR delivering all three pieces of
the dev-stack entry.

**Source PR:** TBD — `feat(omniroute): first dev-stack entry` on
`feat/omniroute-first-dev-stack` in `Mercury-Garden/mercury-host`.

## Goal

Add [OmniRoute](https://omniroute.online) (`diegosouzapw/OmniRoute`,
`omniroute@3.8.48`, MIT, npm-published with bin `omniroute` +
`omniroute-reset-password`) as the first entry in the Mercury dev stack.
Three things must be true after this change lands:

1. **The dashboard is always running and reachable.** `omniroute.service`
   is a systemd user unit, started at boot, restarts on crash
   (`Restart=always`, `RestartSec=5`), binds to `127.0.0.1:20128`. The
   `omniroute.mercury.garden` nginx vhost fronts it on the public
   hostname with oauth2-proxy-gated GitHub OAuth (same SSO as the rest
   of the Mercury Garden subdomains).
2. **The version stays current.** The existing daily devtools-upgrade
   cron (`job id d9cae3886311`, schedule `0 11 * * *` UTC) now also
   audits `omniroute`, upgrades it when a newer version is on npm, and
   restarts `omniroute.service` around the install (same shape as
   `auditOpenchamber`: explicit-version pin to dodge the pnpm-11
   offline-store-prefers-old-version trap; post-upgrade watchdog with
   symlink repair + service health-check + auto-repair loop).
3. **It's all tracked in mercury-host.** A new row in
   `inventory.yaml#services` declares the unit, the bind, and the
   vhost. The nginx `enabled_vhosts:` block now lists
   `omniroute.mercury.garden`. `bash scripts/audit.sh` enforces all of
   it on every CI gate.

## Deliverable (this PR)

Five files:

1. **`systemd/user/omniroute.service`** (new) — systemd user unit, mode
   0644. Mirrors `systemd/user/openchamber.service` with port `20128`
   swapped in. Symlinked to `~/.config/systemd/user/` and
   `enable --now`'d at the time of the PR. Hardened: `PrivateTmp=true`,
   `NoNewPrivileges=true`, `ProtectSystem=full`, `ProtectHome=read-only`.
2. **`nginx/sites-available/omniroute.mercury.garden`** (new) — copy of
   `nginx/sites-available/chamber.mercury.garden` with the
   `proxy_pass http://127.0.0.1:20128` upstream and the matching
   `server_name` swapped in. Reuses the wildcard Letsencrypt cert at
   `/etc/letsencrypt/live/mercury.garden/` (the same cert chamber /
   memory / tasks / plans / webhook already use; no new cert needed).
   Symlinked into `/etc/nginx/sites-enabled/`. `sudo nginx -t && sudo
   systemctl reload nginx` is part of the PR verification gate, not
   the deliverable.
3. **`scripts/devtools-upgrade.ts`** (modified) — new
   `auditOmniroute()` function + `stopOmniroute` / `startOmniroute` /
   `omnirouteHealthcheck` / `autoRepairOmniroute` helpers, slotted
   right after `auditOpenchamber()` in `main()`. The helpers and
   audit function are a verbatim copy of the openchamber shape — this
   is intentional. The "dev-stack" entry pattern is now established:
   any future dev-stack tool with its own systemd service should
   mirror this shape (explicit-version pin + post-upgrade watchdog +
   health-check auto-repair). Header comment block in the script
   (lines 19-34) updated to document the new entry.
4. **`scripts/devtools-upgrade-prompt.txt`** (modified) — three
   sites: the opening line (`14 lines` → `15 lines`, append
   `omniroute` to the canonical-order list with an inline note about
   the 2026-07-24 addition), the "What this cron does" line (`14
   dev tools` → `15 dev tools`, mention `omniroute.service` alongside
   `openchamber.service`), and the canonical-order hard-rule (append
   `omniroute` to the list).
5. **`scripts/register-devtools-upgrade-cron.sh`** (modified) — the
   header comment block (the "What this cron does" section) bumped
   `13 dev tools` → `15 dev tools` with the new entry.

Plus the inventory bookkeeping in the same PR:

6. **`inventory.yaml`** (modified) — new `services` row for
   `omniroute` (kind: systemd-user, unit, binds: 127.0.0.1:20128,
   nginx_vhost: omniroute.mercury.garden, repo: local, managed_by:
   human+mercutio) + `omniroute.mercury.garden` appended to
   `nginx.enabled_vhosts`.

## Live install (happens at PR time, not after merge)

To make `git diff` tell the truth about what's on the box, the actual
`pnpm add -g omniroute@3.8.48` install + `systemctl --user enable --now
omniroute.service` + `ln -s` for the vhost + `nginx -t && systemctl
reload nginx` all run **before** the commit. The diff is
config-as-code only; the running service is the result of that code.

## Verification gate (mandatory, run before `git push`)

1. `yamllint -c .yamllint.yml --strict .` → exit 0
2. `shellcheck scripts/*.sh` → exit 0
3. `gitleaks detect --no-git --redact --exit-code 1 .` → exit 0
4. `bash scripts/audit.sh` → no drift
5. `node --experimental-strip-types ~/.hermes/scripts/devtools-upgrade.ts | wc -l`
   → 15 (was 14)
6. `node --experimental-strip-types ~/.hermes/scripts/devtools-upgrade.ts | grep -E '"tool":"(openchamber|omniroute)"'`
   → exactly two lines, in the canonical order, both with the right
   `action` (noop on a healthy install).
7. `hermes cron run <devtools-upgrade-id>` (force-tick) — rendered
   message shows `Unchanged (15): …, omniroute, …` in the
   canonical-order listing.
8. `curl -o /dev/null -w '%{http_code}\n' 127.0.0.1:20128/` → `200` or
   `302` (service up).
9. `curl -o /dev/null -w '%{http_code}\n' https://omniroute.mercury.garden/`
   → `302` (oauth2-proxy bounce = up + behind auth = correct).

## Companion PR (separate repo, same day)

`Mercury-Garden/mercury.garden` ships `feat/omniroute-landing-card-and-services-count-derivation`
in parallel. It adds the OmniRoute card to the public landing page
(`/var/www/mercury.garden/index.html`, served by the `mercury.garden`
nginx vhost), adds the `memory` entry that was missing from the JS
`services` probe array (closes the pre-existing 5-vs-6 inconsistency),
and derives the hero "Services" stat and the `online-count` denominator
from `services.length` so this class of bug cannot reoccur. **That PR
must not merge until the mercury-host PR is merged and the dashboard
is reachable on `omniroute.mercury.garden`.** The PR body carries
`Blocked-by: Mercury-Garden/mercury-host#<N>`.

## Rollback

Reversible cleanly. `git revert` (or the standard sync-and-archive
revert PR); `systemctl --user disable --now omniroute.service`;
`pnpm remove -g omniroute`; remove the symlinks for the vhost. The
inventory entries revert in the same revert commit. Nothing
destructive.
