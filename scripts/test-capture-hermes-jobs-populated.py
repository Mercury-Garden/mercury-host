#!/usr/bin/env python3
"""Regression test: capture.sh's hermes.jobs refresh must use a per-entry
diff that preserves hand-written comments AND handles three drift classes:
cron-id rotation, new-job append, and sibling-block preservation.

Bug context:
  - PR #64 (2026-07-18) shipped a regex that matched the whole block
    atomically. Side effect: every capture.sh run stripped hand-written
    comments inside the hermes.jobs block. The drift class it was meant
    to fix (cron-id rotation) only changes the `id:` field, so a
    per-entry diff is the correct shape.

This test runs capture.sh end-to-end (not an inlined copy) and verifies
the inventory transformation. Running against the actual script — not
a paste — is the only way to catch drift between the test and the
script's logic (the vacuous-green trap from pre-pr-ci-gate pitfall).

Cases:
  1. id-only drift on a populated block preserves comments
  2. new entry in jobs.json (not in inventory) is appended
  3. no drift = no-op (byte-for-byte)
  4. empty list -> populated (the original PR #64 case)
  5. project-shaped blocks under decommissioned_projects are ignored

Run from repo root:
    python3 scripts/test-capture-hermes-jobs-populated.py --verbose

Exit codes: 0 = all pass, 1 = at least one assertion failed.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile


CAPTURE_SH = "scripts/capture.sh"


def run_capture_on_inventory(inventory_text, hermes_jobs, project_names=()):
    """Run capture.sh end-to-end while preserving every touched repo file.

    Sandbox HOME supplies a controlled jobs.json plus optional synthetic
    projects. capture.sh itself still runs from the real repo root, so this
    helper snapshots and restores inventory.yaml plus the generated package
    inventories around every case. That exercises the actual script without
    leaving test drift in the worktree.
    """
    import pathlib
    repo_root = pathlib.Path(__file__).resolve().parent.parent
    inv_path = repo_root / "inventory.yaml"
    backup_path = repo_root / ".test-inventory-backup.yaml"
    generated_paths = (repo_root / "packages" / "apt.list",
                       repo_root / "packages" / "node.yaml")
    generated_backups = {}

    # capture.sh refreshes these files as collateral. Preserve them too so
    # the regression test is side-effect-free for the surrounding worktree.
    shutil.copy(inv_path, backup_path)
    for path in generated_paths:
        generated_backups[path] = path.read_bytes()
    try:
        with open(inv_path, "w") as f:
            f.write(inventory_text)
        # Sandbox HOME so capture.sh reads our jobs.json fixture.
        with tempfile.TemporaryDirectory() as tmp_home:
            os.makedirs(f"{tmp_home}/.hermes/cron", exist_ok=True)
            with open(f"{tmp_home}/.hermes/cron/jobs.json", "w") as f:
                json.dump({"jobs": hermes_jobs}, f)
            # Optional synthetic projects make the project-refresh path real
            # rather than vacuously green. Each has the files capture.sh needs
            # to compute a lockfile hash + toolchain pin.
            for project_name in project_names:
                project = f"{tmp_home}/data/code/{project_name}"
                os.makedirs(project, exist_ok=True)
                with open(f"{project}/package.json", "w") as f:
                    json.dump({"name": project_name}, f)
                with open(f"{project}/pnpm-lock.yaml", "w") as f:
                    f.write("lockfileVersion: '9.0'\n")
                with open(f"{project}/mise.toml", "w") as f:
                    f.write('[tools]\nnode = "24"\n')
            env = dict(os.environ)
            env["HOME"] = tmp_home
            proc = subprocess.run(
                ["bash", str(repo_root / "scripts" / "capture.sh")],
                cwd=str(repo_root), env=env,
                capture_output=True, text=True, timeout=60,
            )
            if proc.returncode != 0:
                raise RuntimeError(
                    f"capture.sh failed (rc={proc.returncode})\n"
                    f"  stdout: {proc.stdout}\n"
                    f"  stderr: {proc.stderr}"
                )
            with open(inv_path) as f:
                return f.read()
    finally:
        # Always restore the original inventory + generated package files.
        shutil.move(backup_path, inv_path)
        for path, content in generated_backups.items():
            path.write_bytes(content)


# ── Test fixtures ────────────────────────────────────────────────────────

# (1) Populated block with stale id AND hand-written comments. The
# fixture has 3 entries with comments; the jobs.json snapshot has the
# same 3 names but with FRESH ids. Expected: id lines refresh, comments
# preserved verbatim.
POPULATED_WITH_COMMENTS = """\
cron:
  hermes:
    jobs_file: ~/.hermes/cron/jobs.json
    jobs:
      - id: OLDID-1
        name: foo
        # Hand-written comment about foo. Preserved verbatim.
        schedule: "0 1 * * *"
      - id: OLDID-2
        name: bar
        schedule: "*/5 * * * *"
        # Comment interleaved between fields.
        # Multi-line comment block.
      - id: OLDID-3
        name: baz
        # Indented comment block.
        #   - sub-bullet 1
        #   - sub-bullet 2
        schedule: "0 9 * * 0"
  # Sibling block.
  hermes_profiles:
    - profile: mercury-butler
      jobs_file: ~/.hermes/profiles/mercury-butler/cron/jobs.json
      jobs:
        - id: MB-1
          name: mercury-butler-job
          schedule: "0 8 * * *"
"""

LIVE_JOBS_FRESH = [
    {'id': 'NEWID-1', 'name': 'foo', 'schedule': {'display': '0 1 * * *'}},
    {'id': 'NEWID-2', 'name': 'bar', 'schedule': {'display': '*/5 * * * *'}},
    {'id': 'NEWID-3', 'name': 'baz', 'schedule': {'display': '0 9 * * 0'}},
]

# (2) jobs.json has a NEW job that isn't in the inventory. Expected: the
# existing entries are preserved verbatim (comments intact), the new
# entry is appended at the end of the block (before the sibling).
POPULATED_WITH_NEW_JOB_IN_JSON = """\
cron:
  hermes:
    jobs_file: ~/.hermes/cron/jobs.json
    jobs:
      - id: aaa
        name: foo
        # Comment for foo.
        schedule: "0 1 * * *"
      - id: bbb
        name: bar
        schedule: "*/5 * * * *"
  # Sibling block.
  hermes_profiles:
    - profile: mercury-butler
      jobs_file: ~/.hermes/profiles/mercury-butler/cron/jobs.json
      jobs:
        - id: MB-1
          name: mercury-butler-job
          schedule: "0 8 * * *"
"""

LIVE_JOBS_WITH_NEW = [
    {'id': 'aaa', 'name': 'foo', 'schedule': {'display': '0 1 * * *'}},
    {'id': 'bbb', 'name': 'bar', 'schedule': {'display': '*/5 * * * *'}},
    {'id': 'ccc-NEW', 'name': 'qux', 'schedule': {'display': '0 6 * * *'}},
]

# (3) jobs.json matches inventory exactly. Expected: no drift, output
# is identical to input (byte-for-byte preservation).
POPULATED_NO_DRIFT = """\
cron:
  hermes:
    jobs_file: ~/.hermes/cron/jobs.json
    jobs:
      - id: aaa
        name: foo
        # A comment that must survive a no-op run.
        schedule: "0 1 * * *"
      - id: bbb
        name: bar
        schedule: "*/5 * * * *"
"""

LIVE_JOBS_NO_DRIFT = [
    {'id': 'aaa', 'name': 'foo', 'schedule': {'display': '0 1 * * *'}},
    {'id': 'bbb', 'name': 'bar', 'schedule': {'display': '*/5 * * * *'}},
]

# (4) hermes.jobs: [] empty list + jobs.json has live jobs. Expected:
# the empty list is replaced with a populated block, no comments to
# preserve (empty has none).
EMPTY_FIXTURE = """\
cron:
  hermes:
    jobs_file: ~/.hermes/cron/jobs.json
    jobs: []
"""

LIVE_JOBS_FOR_EMPTY = [
    {'id': 'aaa', 'name': 'foo', 'schedule': {'display': '0 1 * * *'}},
    {'id': 'bbb', 'name': 'bar', 'schedule': {'display': '*/5 * * * *'}},
]


# (5) Active + decommissioned project blocks share the same `- path:` shape.
# Expected: capture updates only the active project; the cold-copy metadata
# remains byte-for-byte unchanged even when its package files exist.
DECOMMISSIONED_PROJECT_FIXTURE = """\
projects:
  - path: ~/data/code/active
    repo: Mercury-Garden/active
    lockfile_sha256: aaaaaaaaaaaa
    toolchain_pinned: false

decommissioned_projects:
  - path: ~/data/code/retired
    repo: Mercury-Garden/retired
    lockfile_sha256: keep-this-value
    toolchain_pinned: false
    disposition: cold copy

cron:
  hermes:
    jobs_file: ~/.hermes/cron/jobs.json
    jobs: []
"""


def test_decommissioned_project_not_refreshed(verbose):
    """capture.sh must ignore project-shaped blocks outside active projects."""
    out = run_capture_on_inventory(
        DECOMMISSIONED_PROJECT_FIXTURE, [], project_names=("retired",)
    )
    assert_contains(out, "lockfile_sha256: keep-this-value",
                    "decommissioned project metadata must not be refreshed")
    assert_contains(out, "disposition: cold copy",
                    "decommissioned project disposition must survive")
    if verbose:
        print("  decommissioned project block preserved")


# ── Assertions ───────────────────────────────────────────────────────────

def assert_contains(haystack, needle, msg):
    if needle not in haystack:
        raise AssertionError(f"FAIL: {msg}\n  expected to find: {needle!r}\n  in:\n{haystack}")

def assert_not_contains(haystack, needle, msg):
    if needle in haystack:
        raise AssertionError(f"FAIL: {msg}\n  expected NOT to find: {needle!r}\n  in:\n{haystack}")


# ── Tests ────────────────────────────────────────────────────────────────

def test_id_drift_preserves_comments(verbose):
    """The core regression: id rotation must preserve all comments."""
    out = run_capture_on_inventory(POPULATED_WITH_COMMENTS, LIVE_JOBS_FRESH)
    # All ids refreshed
    assert_contains(out, "- id: NEWID-1", "id drift should write NEWID-1")
    assert_contains(out, "- id: NEWID-2", "id drift should write NEWID-2")
    assert_contains(out, "- id: NEWID-3", "id drift should write NEWID-3")
    assert_not_contains(out, "OLDID-1", "stale OLDID-1 must be removed")
    assert_not_contains(out, "OLDID-2", "stale OLDID-2 must be removed")
    assert_not_contains(out, "OLDID-3", "stale OLDID-3 must be removed")
    # All comments preserved verbatim
    assert_contains(out, "# Hand-written comment about foo. Preserved verbatim.",
                    "foo's hand-written comment must survive")
    assert_contains(out, "# Comment interleaved between fields.",
                    "bar's interleaved comment must survive")
    assert_contains(out, "# Multi-line comment block.",
                    "bar's multi-line comment must survive")
    assert_contains(out, "# Indented comment block.",
                    "baz's indented comment must survive")
    assert_contains(out, "#   - sub-bullet 1",
                    "baz's nested sub-bullet must survive")
    assert_contains(out, "#   - sub-bullet 2",
                    "baz's nested sub-bullet 2 must survive")
    if verbose: print("  ok: id drift preserves all hand-written comments")

def test_new_job_appended_with_comments_intact(verbose):
    """A new jobs.json entry not in inventory must be appended at the end
    of the existing block, with existing comments intact."""
    out = run_capture_on_inventory(POPULATED_WITH_NEW_JOB_IN_JSON, LIVE_JOBS_WITH_NEW)
    # Existing entries unchanged
    assert_contains(out, "- id: aaa", "existing entry `aaa` must survive")
    assert_contains(out, "- id: bbb", "existing entry `bbb` must survive")
    assert_contains(out, "# Comment for foo.", "existing comment must survive")
    # New entry appended
    assert_contains(out, "- id: ccc-NEW", "new entry must be appended")
    assert_contains(out, "name: qux", "new entry's name must be appended")
    assert_contains(out, 'schedule: "0 6 * * *"', "new entry's schedule must be appended")
    # Order: existing entries first, new entry last
    aaa_pos = out.index("- id: aaa")
    bbb_pos = out.index("- id: bbb")
    new_pos = out.index("- id: ccc-NEW")
    if not (aaa_pos < bbb_pos < new_pos):
        raise AssertionError(f"FAIL: order should be aaa < bbb < ccc-NEW, "
                             f"got aaa={aaa_pos}, bbb={bbb_pos}, ccc-NEW={new_pos}")
    # Sibling blocks untouched
    assert_contains(out, "hermes_profiles:", "sibling hermes_profiles: must survive")
    assert_contains(out, "mercury-butler-job", "sibling profile entries must survive")
    if verbose: print("  ok: new entry appended, existing comments + siblings intact")

def test_no_drift_no_change(verbose):
    """No drift means no output change (byte-for-byte preservation)."""
    out = run_capture_on_inventory(POPULATED_NO_DRIFT, LIVE_JOBS_NO_DRIFT)
    if out != POPULATED_NO_DRIFT:
        raise AssertionError(f"FAIL: no-drift case should be byte-for-byte identical\n"
                             f"  expected identical to input\n"
                             f"  diff:\n"
                             f"  in:  {POPULATED_NO_DRIFT!r}\n"
                             f"  out: {out!r}")
    if verbose: print("  ok: no-drift case is byte-for-byte identical (truly idempotent)")

def test_empty_to_populated(verbose):
    """The original case from PR #64: empty list becomes populated block."""
    out = run_capture_on_inventory(EMPTY_FIXTURE, LIVE_JOBS_FOR_EMPTY)
    assert_contains(out, "- id: aaa", "empty -> populated should write `id: aaa`")
    assert_contains(out, "- id: bbb", "empty -> populated should write `id: bbb`")
    assert_not_contains(out, "jobs: []", "empty -> populated should remove `jobs: []`")
    if verbose: print("  ok: empty -> populated (the original PR #64 case)")


# ── Runner ───────────────────────────────────────────────────────────────

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--verbose", "-v", action="store_true")
    args = p.parse_args()
    tests = [
        ("id_drift_preserves_comments", test_id_drift_preserves_comments),
        ("new_job_appended_with_comments_intact", test_new_job_appended_with_comments_intact),
        ("no_drift_no_change", test_no_drift_no_change),
        ("empty_to_populated", test_empty_to_populated),
        ("decommissioned_project_not_refreshed", test_decommissioned_project_not_refreshed),
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