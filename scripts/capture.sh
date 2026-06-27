#!/usr/bin/env bash
# scripts/capture.sh — surgical refresh of declarative YAML files + network state.
# NEVER touches secrets. Idempotent. Safe to re-run.
#
# Scope:
#   1. packages/apt.list          — full regen from `apt-mark showmanual`, header preserved
#   2. inventory.yaml projects[]  — refresh lockfile_sha256 + volta_pinned per project
#   3. packages/snap.yaml apps[]  — refresh version/revision/channel/publisher/classic/notes,
#                                   preserve hand-written `purpose:` per app + runtime_bases
#   4. packages/node.yaml         — refresh default_* + cached_runtimes +
#                                   globally_pinned_packages + hermes_bundled node/npm
#   5. network/hostname + network/hosts — refresh from `hostname` and /etc/hosts
#
# Out of scope (hand-curated):
#   - inventory.yaml services[]   — managed_by/repo/description human-curated;
#                                   audit.sh flags drift via systemctl is-enabled
#   - inventory.yaml nginx enabled_vhosts  — hand-curated; audit.sh flags drift
#   - packages/node.yaml system_node block — static description
#   - packages/node.yaml path_order_required — aspirational PATH order, not a snapshot
#   - packages/node.yaml projects[] block   — duplicate of inventory.yaml; removed
#   - network/vcn-topology.md     — hand-written Oracle VCN reference, manually updated

set -euo pipefail

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
inv_path.write_text(text.rstrip('\n') + '\n')
print("  refreshed lockfile_sha256 + volta_pinned in inventory.yaml")
PYEOF

# ── packages/snap.yaml: refresh apps[] while preserving `purpose:` + runtime_bases ─
echo
echo "[snap]"
python3 - <<'PYEOF'
import pathlib, re, subprocess

snap_path = pathlib.Path('packages/snap.yaml')
text = snap_path.read_text()

# Parse `snap list` once.
try:
    raw = subprocess.check_output(['snap', 'list'], text=True).splitlines()
except (subprocess.CalledProcessError, FileNotFoundError):
    print("  snap not available, skipping")
    raise SystemExit(0)

runtimes = {'bare', 'core18', 'core22', 'core24', 'snapd',
             'gnome-46-2404', 'gtk-common-themes', 'mesa-2404'}
apps = []
for line in raw[1:]:
    parts = line.split()
    if len(parts) < 5:
        continue
    name, ver, rev, tracking, publisher = parts[0], parts[1], parts[2], parts[3], parts[4]
    # Strip terminal-rendering ellipsis "…" that snap list appends when channel
    # is too wide to fit. The actual channel is the prefix.
    tracking = tracking.removesuffix('/…').removesuffix('/...')
    notes_field = ' '.join(parts[5:]) if len(parts) > 5 else ''
    if name in runtimes:
        continue
    apps.append({
        'name': name,
        'version': ver,
        'revision': rev,
        'channel': tracking,
        'publisher': publisher,
        'classic': 'classic' in notes_field,
        'held': 'held' in notes_field,
        'notes': '',
    })

def update_app_block(block, info):
    """Update the auto-refreshable fields in one app block, preserve `purpose:`."""
    new = block
    # Bare-value fields: replace everything after the colon
    for field in ('version', 'channel', 'publisher'):
        new = re.sub(
            rf'^([ \t]*{field}: ).+$',
            rf'\g<1>{info[field]}',
            new, count=1, flags=re.MULTILINE,
        )
    # revision: quoted string
    new = re.sub(
        r'^([ \t]*revision: )"[^"]*"$',
        rf'\g<1>"{info["revision"]}"',
        new, count=1, flags=re.MULTILINE,
    )
    # notes: always emit "" (canonical empty)
    new = re.sub(
        r'^([ \t]*notes: ).+$',
        rf'\g<1>""',
        new, count=1, flags=re.MULTILINE,
    )
    # classic: bool (insert if missing, after publisher:)
    classic_str = str(info['classic']).lower()
    if re.search(r'^[ \t]*classic: ', new, re.MULTILINE):
        new = re.sub(
            r'^([ \t]*classic: )(true|false).*$',
            rf'\g<1>{classic_str}',
            new, count=1, flags=re.MULTILINE,
        )
    else:
        # Insert classic line after publisher: line
        new = re.sub(
            r'^([ \t]*publisher: .+)$',
            rf'\1\n    classic: {classic_str}',
            new, count=1, flags=re.MULTILINE,
        )
    # held: bool (insert if missing, after classic:)
    if not re.search(r'^[ \t]*held: ', new, re.MULTILINE):
        new = re.sub(
            r'^([ \t]*classic: .+)$',
            rf'\1\n    held: {str(info["held"]).lower()}',
            new, count=1, flags=re.MULTILINE,
        )
    else:
        held_str = str(info['held']).lower()
        new = re.sub(
            r'^([ \t]*held: )(true|false).*$',
            rf'\g<1>{held_str}',
            new, count=1, flags=re.MULTILINE,
        )
    return new

# Find each app block: starts at "  - name: <name>" and ends at the next
# "  - name:" or end of apps: section (or top-level key change).
app_pattern = re.compile(
    r'^[ \t]*- name: (\S+)\s*$\n((?:^[ \t]+.*\n)*)',
    re.MULTILINE,
)

existing_names = set()
def replace_app(m):
    name = m.group(1)
    block = m.group(0)
    existing_names.add(name)
    info = next((a for a in apps if a['name'] == name), None)
    if info is None:
        # App no longer installed — keep the block but log
        print(f"  {name}: not in snap list, keeping as-is")
        return block
    print(f"  {name}: ver={info['version']} rev={info['revision']} channel={info['channel']}")
    return update_app_block(block, info)

text = app_pattern.sub(replace_app, text)

# Add new apps not in the file: append at end of apps: section.
new_apps = [a for a in apps if a['name'] not in existing_names]
if new_apps:
    # Find end of apps: section (next top-level key like "runtime_bases:" or EOF)
    m = re.search(r'^apps:\s*$\n(?:.*\n)*?(?=^[a-zA-Z_]|\Z)', text, re.MULTILINE)
    insert_point = m.end() if m else len(text)
    new_block = ''
    for a in new_apps:
        new_block += f"  - name: {a['name']}\n"
        new_block += f"    version: {a['version']}\n"
        new_block += f'    revision: "{a["revision"]}"\n'
        new_block += f"    channel: {a['channel']}\n"
        new_block += f"    publisher: {a['publisher']}\n"
        new_block += f"    classic: {str(a['classic']).lower()}\n"
        new_block += f'    notes: ""\n'
        new_block += f'    purpose: ""\n'
        new_block += "\n"
    text = text[:insert_point] + new_block + text[insert_point:]
    print(f"  added {len(new_apps)} new apps: {[a['name'] for a in new_apps]}")

snap_path.write_text(text.rstrip('\n') + '\n')
print("  refreshed apps[] in packages/snap.yaml")
PYEOF

# ── packages/node.yaml: refresh default_*, cached_runtimes, globally_pinned_packages ─
echo
echo "[node]"
python3 - <<'PYEOF'
import pathlib, re, subprocess

node_path = pathlib.Path('packages/node.yaml')
text = node_path.read_text()

# ── default_node / default_npm / default_pnpm ─────────────────────────
try:
    volta_out = subprocess.check_output(['volta', 'list', 'all'], text=True).splitlines()
except (subprocess.CalledProcessError, FileNotFoundError):
    volta_out = []

def extract_version(line, prefix):
    """Extract version from a `volta list` line.

    Examples:
      'runtime node@24.18.0 (default)'      → '24.18.0'  (prefix='runtime node')
      'package-manager npm@11.17.0 (default)' → '11.17.0' (prefix='package-manager npm')
      'package pnpm@11.9.0 / ...'            → '11.9.0'   (prefix='package pnpm')
    """
    if not line.startswith(prefix):
        return None
    parts = line.split()
    if len(parts) < 2:
        return None
    token = parts[1]
    # Strip trailing (default) and similar parens
    token = re.sub(r'\(.*\)$', '', token)
    # Take everything after the LAST '@'
    if '@' in token:
        return token.rsplit('@', 1)[1]
    return token

# Find current versions
default_node = default_npm = default_pnpm = ''
cached = []
for line in volta_out:
    if line.startswith('runtime node'):
        ver = extract_version(line, 'runtime node')
        if ver:
            cached.append(ver)
            if '(default)' in line:
                default_node = ver
    elif line.startswith('package-manager npm') and '(default)' in line:
        default_npm = extract_version(line, 'package-manager npm')
    elif line.startswith('package pnpm') and '(default)' in line:
        default_pnpm = extract_version(line, 'package pnpm')

# Update default_node / default_npm / default_pnpm (within node_managers.volta)
for field, value in [('default_node', default_node), ('default_npm', default_npm), ('default_pnpm', default_pnpm)]:
    if value:
        text = re.sub(
            rf'^([ \t]+{field}: ).+$',
            rf'\g<1>{value}',
            text, count=1, flags=re.MULTILINE,
        )
        print(f"  {field} = {value}")

# ── cached_runtimes: refresh list, preserve inline comments by version ─
# Inline comments are like "- 24.16.0   # kept for openspec". We need to:
#  1. Parse current list with their (version, comment) pairs
#  2. Build new list with same comments, refreshed versions
existing_rt = re.search(
    r'^[ \t]+cached_runtimes:\n((?:^[ \t]+- \S+(?:[ \t]+#[^\n]*)?\n)*)',
    text, re.MULTILINE,
)
if existing_rt:
    lines = existing_rt.group(1).splitlines()
    # Preserve: version → comment (or empty)
    comments_by_version = {}
    for ln in lines:
        m = re.match(r'^[ \t]+- (\S+)(?:[ \t]+(#[^\n]*))?$', ln)
        if m:
            comments_by_version[m.group(1)] = m.group(2) or ''
    # Build new lines: keep comment if version still cached, drop if gone
    new_lines = []
    seen = set()
    for v in cached:
        seen.add(v)
        comment = comments_by_version.get(v, '')
        if comment:
            new_lines.append(f'      - {v}   {comment}')
        else:
            new_lines.append(f'      - {v}')
    # Append any versions that had comments but are gone (with note)
    for v, c in comments_by_version.items():
        if v not in seen and c:
            new_lines.append(f'      - {v}   # stale; not in current volta cache')
    new_block = '    cached_runtimes:\n' + '\n'.join(new_lines) + '\n'
    text = text[:existing_rt.start()] + new_block + text[existing_rt.end():]
    print(f"  cached_runtimes: {len(cached)} live + stale-annotated")

# ── globally_pinned_packages: rebuild from `volta list` ─────────────────
# Format examples:
#   package @fission-ai/openspec@1.4.1 / openspec / node@24.16.0 npm@built-in (default)
#   package context-mode@1.0.162 / context-mode / node@24.16.0 npm@built-in (default)
#   package pnpm@11.9.0 / pnpm, pnpx, pn, pnx / node@24.18.0 npm@built-in (default)
# Token at index 1 is "<name>@<version>". Split on LAST '@' to get name and version.
pkgs = []
for line in volta_out:
    if not line.startswith('package '):
        continue
    parts = line.split()
    if len(parts) < 2 or '@' not in parts[1]:
        continue
    token = parts[1]
    # Strip trailing (default) if present
    token = re.sub(r'\(.*\)$', '', token)
    name, ver = token.rsplit('@', 1)
    # Quote scoped packages (start with '@'); unquoted otherwise (e.g., context-mode, pnpm)
    needs_quotes = name.startswith('@')
    node = ''
    for tok in parts:
        if tok.startswith('node@'):
            node = tok[5:]
    pkgs.append({'name': name, 'version': ver, 'node': node, 'quoted': needs_quotes})

gp_match = re.search(
    r'^[ \t]+globally_pinned_packages:\n((?:[ \t]+- .+\n(?:[ \t]+.+\n)*)*)',
    text, re.MULTILINE,
)
if gp_match:
    new_gp = '    globally_pinned_packages:\n'
    for p in pkgs:
        name_repr = f'"{p["name"]}"' if p['quoted'] else p['name']
        new_gp += f'      - name: {name_repr}\n'
        new_gp += f'        version: {p["version"]}\n'
        new_gp += f'        node: {p["node"]}\n'
    text = text[:gp_match.start()] + new_gp + text[gp_match.end():]
    print(f"  globally_pinned_packages: {len(pkgs)} packages")

# ── hermes_bundled: refresh node + npm ──────────────────────────────────
try:
    hermes_node_out = subprocess.check_output(
        ['/home/ubuntu/.hermes/node/bin/node', '--version'], text=True
    ).strip().lstrip('v')
    hermes_npm_out = subprocess.check_output(
        ['/home/ubuntu/.hermes/node/bin/npm', '--version'], text=True
    ).strip()
    text = re.sub(
        r'^([ \t]+hermes_bundled:\n(?:[ \t]+.*\n)*?[ \t]+node: ).+$',
        rf'\g<1>{hermes_node_out}',
        text, count=1, flags=re.MULTILINE,
    )
    text = re.sub(
        r'^([ \t]+hermes_bundled:\n(?:[ \t]+.*\n)*?[ \t]+npm: ).+$',
        rf'\g<1>{hermes_npm_out}',
        text, count=1, flags=re.MULTILINE,
    )
    print(f"  hermes_bundled: node={hermes_node_out} npm={hermes_npm_out}")
except (subprocess.CalledProcessError, FileNotFoundError):
    print("  hermes node binary not found, skipping")

# ── Remove the redundant `projects:` section (now in inventory.yaml) ─
# Match `projects:` at column 0, then all indented/blank lines below it, until
# the next column-0 line or EOF. Allows blank lines as part of the section.
projects_match = re.search(
    r'^projects:\n((?:[ \t]+.*\n|\n)*)',
    text, re.MULTILINE,
)
if projects_match:
    text = text[:projects_match.start()] + text[projects_match.end():]
    print("  removed redundant projects: section (now lives in inventory.yaml)")

node_path.write_text(text.rstrip('\n') + '\n')
print("  refreshed packages/node.yaml")
PYEOF

# ── network/: refresh hostname + hosts ────────────────────────────────────
echo
echo "[network]"
hostname > network/hostname
note "wrote network/hostname ($(wc -c < network/hostname) bytes, value: $(cat network/hostname))"
if sudo -n true 2>/dev/null; then
  sudo cp /etc/hosts network/hosts
  note "wrote network/hosts from /etc/hosts"
else
  note "skipping network/hosts (no sudo) — manually copy from /etc/hosts"
fi

echo
echo "Done. Review the diff with: git diff"