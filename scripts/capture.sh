#!/usr/bin/env bash
# scripts/capture.sh — surgical refresh of inventory.yaml + packages/apt.list.
# NEVER touches secrets. Idempotent. Safe to re-run.
#
# Scope (deliberately limited):
#   1. packages/apt.list          — full regeneration from `apt-mark showmanual`
#   2. inventory.yaml projects[]  — refresh lockfile_sha256 + volta_pinned per project
#
# Out of scope (require manual editing or a separate refactor):
#   - packages/snap.yaml          — needs ruamel.yaml or per-field edits to preserve
#                                   human-added `purpose:` annotations
#   - packages/node.yaml          — same: per-runtime notes like "kept for openspec"
#                                   are hand-written comments
#   - inventory.yaml services[]   — hand-curated (managed_by, repo, description, etc.);
#                                   audit.sh flags drift via systemctl is-enabled
#   - inventory.yaml nginx enabled_vhosts  — hand-curated; audit.sh flags drift
#   - inventory.yaml node_managers.volta.* — currently hand-edited with per-runtime
#                                    notes; auto-refresh would lose those notes

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

note() { printf '  %s\n' "$*"; }

echo "=== mercury-host capture — $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

# ── packages/apt.list ────────────────────────────────────────────────────
# Preserve the header (everything before the first package-name line, which
# starts with a letter/digit). Regenerate the package list below it.
echo
echo "[apt]"
: > /tmp/apt-keep
if [ -f packages/apt.list ]; then
  # Header ends at the line BEFORE the first line that starts with a letter/digit.
  HEADER_LINES=$(awk '/^[a-zA-Z0-9]/{exit} {n++} END{print n+0}' packages/apt.list)
  if [ "$HEADER_LINES" -gt 0 ]; then
    head -n "$HEADER_LINES" packages/apt.list > /tmp/apt-keep
  fi
fi
apt-mark showmanual 2>/dev/null | sort > /tmp/apt-list
cat /tmp/apt-keep /tmp/apt-list > packages/apt.list
rm -f /tmp/apt-keep /tmp/apt-list
note "wrote packages/apt.list ($(wc -l < packages/apt.list) entries, $(grep -cE '^[a-zA-Z0-9]' packages/apt.list) packages)"

# ── inventory.yaml: refresh lockfile_sha256 + volta_pinned per project ─
echo
echo "[projects]"
python3 - <<'PYEOF'
import hashlib, json, pathlib, re

inv_path = pathlib.Path('inventory.yaml')
text = inv_path.read_text()
home = pathlib.Path.home()

# Find every project block: starts at "  - path: <path>" and ends at the next
# "  - path:" or end of the projects: section. Anchored by the projects: line.
def update_block(block, lockfile_sha, volta_pinned, proj_name):
    """Update lockfile_sha256 and volta_pinned within a single project block."""
    new = re.sub(
        r'^([ \t]*lockfile_sha256: )[0-9a-f]+.*$',
        rf'\g<1>{lockfile_sha}    # capture.sh: refreshed {proj_name}',
        block, count=1, flags=re.MULTILINE,
    )
    new = re.sub(
        r'^([ \t]*volta_pinned: )(true|false).*$',
        rf'\g<1>{str(volta_pinned).lower()}',
        new, count=1, flags=re.MULTILINE,
    )
    return new

# Find all project paths (greedy until next - path: or end of file/projects section)
proj_pattern = re.compile(
    r'^[ \t]*- path: (\S+)\s*$\n((?:^[ \t]+.*\n)*)',
    re.MULTILINE,
)

def replace_proj(m):
    proj_path = m.group(1)
    block = m.group(0)  # full match including "- path:" header + indented body
    full = pathlib.Path(proj_path.replace('~', str(home)))
    proj_name = full.name
    if not (full / 'package.json').exists():
        print(f"  {proj_name}: no package.json, skipping")
        return block
    pkg = json.loads((full / 'package.json').read_text())
    volta_node = pkg.get('volta', {}).get('node', '')
    volta_pinned = bool(volta_node)
    lf = full / 'pnpm-lock.yaml'
    lockfile_sha = hashlib.sha256(lf.read_bytes()).hexdigest()[:12] if lf.exists() else 'MISSING'
    print(f"  {proj_name}: lockfile_sha={lockfile_sha} volta_pinned={volta_pinned}")
    return update_block(block, lockfile_sha, volta_pinned, proj_name)

text = proj_pattern.sub(replace_proj, text)
inv_path.write_text(text)
print("  refreshed lockfile_sha256 + volta_pinned in inventory.yaml")
PYEOF

echo
echo "Done. Review the diff with: git diff"