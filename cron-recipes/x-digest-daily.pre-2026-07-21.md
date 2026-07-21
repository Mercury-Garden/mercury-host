You are running the x-digest pipeline. This is a fully-automated run — no user is present. Execute the steps below and report only the outcome.

## What this pipeline does
Daily X (Twitter) digest focused on AI + JavaScript ecosystem. Scrapes your home timeline via cookie-auth Playwright, scores posts by engagement + topic relevance, dedupes against a local SQLite store, writes a Markdown digest into a new row of the "Daily Digests" data source under Mercury Space (Notion). Discord delivery was removed on 2026-07-02 — the cron response itself is the only notification.

## Steps

1. `cd /home/ubuntu/data/code/x-digest`
2. **Ensure .env exists.** The project-tree `.env` has been observed to disappear between sessions (likely a workdir-snapshot rollback on this host — the cause is undetermined as of 2026-07-20). The canonical secret source-of-truth is `~/.secrets/secrets.yaml` (captured daily by `~/.hermes/scripts/backup-secrets.sh`). If `ls .env` fails, run: `bash ~/.hermes/scripts/restore-secrets.sh --env /home/ubuntu/data/code/x-digest/.env` — this writes the file at mode 0600 from the snapshot. Then verify `[[ -f .env ]]` is true before proceeding.
3. Load env: `set -a && source .env && set +a`
4. Run: `pnpm run run` (this executes the pipeline). `pnpm run` alone only lists scripts — `pnpm dry-run` is available for a no-side-effects test.
5. If the run failed with "X cookie expired" (exit code 2), report that to the user with the cookie-refresh steps from the README. Otherwise continue.
6. **Read the section breakdown from `pnpm run run` stdout.** Since 2026-07-16, the pipeline prints a `=== ai (N, top 3) ===`, `=== javascript (N, top 3) ===`, `=== emerging (N, top 3) ===`, and `=== honorable (N, top 3) ===` block immediately after the Notion write line (or after the dedupe line on dry-runs). Use those printed lines — DO NOT read other files, DO NOT run `--dry-run`, DO NOT write inspector scripts, DO NOT invent ways to derive section output. If stdout is missing the section blocks for any reason, surface "section output missing from run.ts stdout" as a known limitation, do not patch around it.
7. Compose your digest report from these fields, all of which appear in the `pnpm run run` stdout:
   - Lookback window (the `window <start> → <end>` line; "24h" for Tue–Fri, "48h" for Mon — weekend wrap)
   - `Scanned / Kept / Deduped` from the `[run]` lines
   - Top item per section (🤖 AI, ⚡ JavaScript, 🚀 Emerging / HN, 🌟 Honorable Mentions), one bullet each: author handle, score, and the printed 120-char snippet. The first item in each printed block is the section winner.
   - Notion URL from `wrote Notion page … url=…` line (omit on dry runs)
   - Mention whether step 2 auto-restored the .env (one short sentence, only if it did).
8. Deliver the report as your final response. No additional context, no verification steps, no tooling side-quests.
9. On any other failure, report the exact error and the last 30 lines of the run output.

## Failure handling
- Cookie expired (exit 2): tell the user to re-extract `auth_token` + `ct0` from x.com DevTools and update `.env`. Reference the README's "Get an X session cookie" section.
- Notion write failed: report the HTTP error code and the Notion API response body.
- Playwright browser missing: report `pnpm exec playwright install chromium` as the fix.
- Any other error: paste the full stderr.

## Hard constraints (learned from a 2026-07-16 drift incident)
- **DO NOT create new files in the project tree.** All section data is already in stdout.
- **DO NOT re-run the pipeline** to "test" or "verify" — one `pnpm run run` per cron tick.
- **DO NOT run lint, build, typecheck, or any other command** beyond the one pipeline invocation.
- **The first execution of `pnpm run run` is the authoritative one.** Do not pad your response with retry output.
- **Your final response must be the digest report itself** — nothing else. If a step failed, surface that as the report.

## Skill
Load the `cron-digest-pipeline` skill for full architecture context if you need to debug anything.

## Self-contained prompt — why this exists
This prompt runs in a fresh Hermes cron session with no chat history. Treat every step as autonomous: don't ask the user clarifying questions, don't reach for tools that aren't strictly needed, just execute and report. The only human-facing artifact of each run is the final message.