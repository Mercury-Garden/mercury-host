#!/usr/bin/env bash
# scripts/capture.sh — walk the live host and regenerate the declarative files.
# Idempotent. Safe to re-run. NEVER touches secrets.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

note() { printf '  %s\n' "$*"; }

echo "=== mercury-host capture — $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

# ── packages/apt.list ────────────────────────────────────────────────────
echo
echo "[apt]"
apt-mark showmanual 2>/dev/null | sort > packages/apt.list
note "wrote packages/apt.list ($(wc -l < packages/apt.list) entries)"

# ── packages/snap.yaml ───────────────────────────────────────────────────
echo
echo "[snap]"
snap list 2>/dev/null > /tmp/snap-raw.txt || note "snap not available"
if [ -s /tmp/snap-raw.txt ]; then
  python3 - <<'PYEOF' > packages/snap.yaml
import subprocess, yaml
out = subprocess.check_output(['snap', 'list'], text=True).splitlines()
# Skip header
apps = []
runtimes = {'bare', 'core18', 'core22', 'core24', 'snapd'}
for line in out[1:]:
    parts = line.split()
    if len(parts) < 5:
        continue
    name, version, rev, tracking, publisher = parts[0], parts[1], parts[2], parts[3], parts[4]
    notes = ' '.join(parts[5:]) if len(parts) > 5 else ''
    classic = 'classic' in notes
    held = 'held' in notes
    entry = {
        'name': name,
        'version': version,
        'revision': rev,
        'channel': tracking,
        'publisher': publisher,
        'classic': classic,
        'held': held,
        'notes': '',
        'purpose': '',
    }
    if name in runtimes:
        continue
    apps.append(entry)
print(yaml.safe_dump({'apps': apps, 'runtime_bases': sorted(runtimes)}, sort_keys=False, default_flow_style=False))
PYEOF
  note "wrote packages/snap.yaml"
fi

# ── packages/node.yaml ───────────────────────────────────────────────────
echo
echo "[node]"
volta list all 2>/dev/null > /tmp/volta.txt || true
python3 - <<'PYEOF' > packages/node.yaml
import subprocess, yaml
out = subprocess.check_output(['volta', 'list', 'all'], text=True).splitlines()
runtime_versions = []
default_node = default_npm = default_pnpm = ''
packages = []
for line in out:
    if line.startswith('runtime node'):
        parts = line.split()
        ver = parts[1].lstrip('@').rstrip('()')
        is_default = '(default)' in line
        runtime_versions.append(ver)
        if is_default:
            default_node = ver
    elif line.startswith('package-manager'):
        parts = line.split()
        ver = parts[1].lstrip('@').rstrip('()')
        if '(default)' in line:
            default_npm = ver
    elif line.startswith('package pnpm'):
        parts = line.split()
        ver = parts[1].lstrip('@').rstrip('()')
        if '(default)' in line:
            default_pnpm = ver
    elif line.startswith('package '):
        # "package <name>@<ver> / ... / node@<ver> npm@built-in (default)"
        parts = line.split()
        name_ver = parts[1]
        if '@' not in name_ver:
            continue
        name, ver = name_ver.split('@', 1)
        # Find pinned node in this line
        node = ''
        for tok in parts:
            if tok.startswith('node@'):
                node = tok[5:]
        packages.append({'name': name, 'version': ver, 'node': node})
print(yaml.safe_dump({
    'node_managers': {
        'volta': {
            'install_method': 'https://volta.sh',
            'home': '~/.volta',
            'default_node': default_node,
            'default_npm': default_npm,
            'default_pnpm': default_pnpm,
            'cached_runtimes': runtime_versions,
            'globally_pinned_packages': packages,
        },
        'hermes_bundled': {
            'home': '~/.hermes/node',
            'node': subprocess.getoutput('~/.hermes/node/bin/node --version 2>/dev/null').lstrip('v'),
            'npm': subprocess.getoutput('~/.hermes/node/bin/npm --version 2>/dev/null'),
            'pnpm': None,
            'purpose': 'Hermes gateway runtime; not user-managed',
        },
    },
}, sort_keys=False, default_flow_style=False))
PYEOF
note "wrote packages/node.yaml"

# ── projects lockfile SHAs ───────────────────────────────────────────────
echo
echo "[projects]"
python3 - <<'PYEOF'
import hashlib, re, pathlib, yaml
inv_path = pathlib.Path('inventory.yaml')
data = yaml.safe_load(inv_path.read_text())
for proj in data.get('projects', []):
    p = pathlib.Path(proj['path'].replace('~', str(pathlib.Path.home())))
    lf = p / 'pnpm-lock.yaml'
    if lf.exists():
        h = hashlib.sha256(lf.read_bytes()).hexdigest()[:12]
        proj['lockfile_sha256'] = h
inv_path.write_text(yaml.safe_dump(data, sort_keys=False, default_flow_style=False))
PYEOF
note "refreshed lockfile_sha256 in inventory.yaml"

echo
echo "Done. Review the diff with: git diff"