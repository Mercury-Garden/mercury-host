#!/usr/bin/env python3
"""Regression test: capture.sh's hermes_block_re must refresh a POPULATED jobs: block,
not just the empty-list form.

Bug context (PR #63, 2026-07-18): every cron re-register rotates the cron id
(via register-*-cron.sh's clean re-register contract). The previous regex
only matched `    jobs: []`, so per-id drift on a populated block silently
survived capture.sh refreshes — audit.sh's `[cron]` check reports
`N jobs match inventory` because it counts entries, not ids.

This test imports the exact regex from capture.sh (paste of the live
compiled pattern + fill_hermes_jobs function — kept in sync manually)
and exercises three cases:

  1. Empty list -> populated: the original case the regex already handled.
  2. Populated with stale ids -> populated with live ids: the regression.
  3. No-op when hermes_jobs is empty: keep the existing block as-is.

Run from the repo root:
    python3 scripts/test-capture-hermes-jobs-populated.py --verbose

Exit codes: 0 = all pass, 1 = at least one assertion failed. Stdout is
deliberately minimal so the script is suitable for a CI step.
"""
import argparse
import os
import re
import sys

# The exact regex + filler from scripts/capture.sh at the time of this
# commit. If you change the regex there, copy the change here verbatim
# AND add a regression case below.
HERMES_BLOCK_RE = re.compile(
    r'^(    jobs:)[ \t]*([^\n]*)\n'
    r'((?:^[ ]{6,}[^\n]*\n?)*)',
    re.MULTILINE,
)

def fill_hermes_jobs(m, hermes_jobs):
    if not hermes_jobs:
        return m.group(0)
    new = '    jobs:\n'
    for j in hermes_jobs:
        new += f"      - id: {j['id']}\n"
        new += f"        name: {j['name']}\n"
        new += f"        schedule: \"{j['schedule']}\"\n"
    return new

def run_replace(text, hermes_jobs):
    return HERMES_BLOCK_RE.sub(lambda m: fill_hermes_jobs(m, hermes_jobs), text, count=1)

# ── Test fixtures ────────────────────────────────────────────────────────

# (1) Empty list — the original case. Should become populated.
EMPTY_FIXTURE = """\
cron:
  hermes:
    jobs_file: ~/.hermes/cron/jobs.json
    jobs: []
  # Per-profile cron jobs ...
"""

LIVE_JOBS = [
    {'id': 'aaa', 'name': 'foo', 'schedule': '0 1 * * *'},
    {'id': 'bbb', 'name': 'bar', 'schedule': '*/5 * * * *'},
]

# (2) Populated with stale ids — the regression. The PRE-FIX regex would
# silently leave this block alone. The POST-FIX regex must replace it.
POPULATED_STALE_FIXTURE = """\
cron:
  hermes:
    jobs_file: ~/.hermes/cron/jobs.json
    jobs:
      - id: OLDID-1
        name: foo
        schedule: "0 1 * * *"
        # Stale entry left over from a previous cron rotation. The cron
        # id rotated to NEWID-1 weeks ago but capture.sh never picked it up
        # because the regex only matched the empty-list form.
      - id: OLDID-2
        name: bar
        schedule: "*/5 * * * *"
  # Per-profile cron jobs ...
"""

LIVE_JOBS_NEW = [
    {'id': 'NEWID-1', 'name': 'foo', 'schedule': '0 1 * * *'},
    {'id': 'NEWID-2', 'name': 'bar', 'schedule': '*/5 * * * *'},
]

# (3) The surrounding `hermes_profiles: [...]` block must be PRESERVED
# even when the default-profile jobs: block is replaced. The fix's regex
# must not eat the next sibling key.
POPULATED_WITH_SIBLING_FIXTURE = """\
cron:
  hermes:
    jobs_file: ~/.hermes/cron/jobs.json
    jobs:
      - id: STALE-1
        name: foo
        schedule: "0 1 * * *"
  # Per-profile cron jobs (one block per Hermes profile). Each block lists
  # the jobs in that profile's ~/.hermes/profiles/<name>/cron/jobs.json so
  # `audit.sh` can verify drift between the manifest and reality. Profiles
  # are enumerated statically (not auto-discovered) to keep the manifest
  # authoritative — if you add a profile, add a block here.
  hermes_profiles:
    - profile: mercury-butler
      jobs_file: ~/.hermes/profiles/mercury-butler/cron/jobs.json
      jobs:
        - id: MB-1
          name: mercury-butler-job
          schedule: "0 8 * * *"
  system_timers:
    - certbot.timer
"""

LIVE_JOBS_FRESH = [
    {'id': 'FRESH-1', 'name': 'foo', 'schedule': '0 1 * * *'},
]

# (4) No-op: hermes_jobs is empty (e.g., parse failed). Block must be
# preserved exactly as-is — do NOT erase the populated block.
NOOP_FIXTURE = POPULATED_STALE_FIXTURE

# ── Assertions ───────────────────────────────────────────────────────────

def assert_contains(haystack, needle, msg):
    if needle not in haystack:
        raise AssertionError(f"FAIL: {msg}\n  expected to find: {needle!r}\n  in:\n{haystack}")

def assert_not_contains(haystack, needle, msg):
    if needle in haystack:
        raise AssertionError(f"FAIL: {msg}\n  expected NOT to find: {needle!r}\n  in:\n{haystack}")

def test_empty_to_populated(verbose):
    out = run_replace(EMPTY_FIXTURE, LIVE_JOBS)
    assert_contains(out, "- id: aaa", "empty -> populated should write `id: aaa`")
    assert_contains(out, "- id: bbb", "empty -> populated should write `id: bbb`")
    assert_not_contains(out, "jobs: []", "empty -> populated should remove `jobs: []`")
    if verbose: print("  ok: empty -> populated")

def test_populated_stale_to_live(verbose):
    out = run_replace(POPULATED_STALE_FIXTURE, LIVE_JOBS_NEW)
    assert_not_contains(out, "OLDID-1", "populated -> live should remove OLDID-1")
    assert_not_contains(out, "OLDID-2", "populated -> live should remove OLDID-2")
    assert_contains(out, "- id: NEWID-1", "populated -> live should write NEWID-1")
    assert_contains(out, "- id: NEWID-2", "populated -> live should write NEWID-2")
    if verbose: print("  ok: populated-stale -> live (the regression case)")

def test_preserve_sibling_blocks(verbose):
    out = run_replace(POPULATED_WITH_SIBLING_FIXTURE, LIVE_JOBS_FRESH)
    # The default-profile jobs: block was replaced.
    assert_not_contains(out, "STALE-1", "populated-with-sibling should remove STALE-1")
    assert_contains(out, "- id: FRESH-1", "populated-with-sibling should write FRESH-1")
    # The sibling hermes_profiles: block was NOT touched.
    assert_contains(out, "mercury-butler", "sibling profile block must be preserved")
    assert_contains(out, "- id: MB-1", "sibling profile entries must be preserved")
    assert_contains(out, "hermes_profiles:", "hermes_profiles: key must be preserved")
    assert_contains(out, "system_timers:", "next sibling key must be preserved")
    if verbose: print("  ok: populated-with-sibling preserves next key + sibling profile entries")

def test_noop_when_jobs_empty(verbose):
    out = run_replace(NOOP_FIXTURE, [])
    # The populated block should be untouched — no data loss.
    assert_contains(out, "OLDID-1", "noop when hermes_jobs is empty should preserve existing block")
    assert_contains(out, "OLDID-2", "noop when hermes_jobs is empty should preserve existing block")
    if verbose: print("  ok: noop preserves populated block when hermes_jobs is empty")

# ── Runner ───────────────────────────────────────────────────────────────

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--verbose", "-v", action="store_true")
    args = p.parse_args()
    tests = [
        ("empty_to_populated", test_empty_to_populated),
        ("populated_stale_to_live", test_populated_stale_to_live),
        ("preserve_sibling_blocks", test_preserve_sibling_blocks),
        ("noop_when_jobs_empty", test_noop_when_jobs_empty),
    ]
    failed = 0
    for name, fn in tests:
        try:
            fn(args.verbose)
        except AssertionError as e:
            print(f"[FAIL] {name}: {e}")
            failed += 1
        else:
            print(f"[ ok ] {name}")
    if failed:
        print(f"\n{failed}/{len(tests)} assertions failed")
        sys.exit(1)
    print(f"\n{len(tests)}/{len(tests)} assertions passed")

if __name__ == "__main__":
    main()