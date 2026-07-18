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
#
# IMPORTANT: capture.sh shells out to `volta` (and pnpm) via subprocess. If the
# parent shell doesn't have ~/.volta/bin on PATH — e.g. running under hermes-
# gateway.service (pitfall #11), under a CI runner with a sanitized PATH, or
# from any subprocess context that doesn't inherit the user's interactive
# shell — the `volta` invocation fails with FileNotFoundError and the script
# silently captures `globally_pinned_packages: 0`, nuking the real entries.
# audit.sh already guards this with USER_SHELL_LOADED (sourcing ~/.zshrc to
# reconstruct the user's real PATH). capture.sh does the same here.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

# Try to reconstruct the user's real PATH. Mirrors the same guard in
# scripts/audit.sh so both scripts see the same toolchain when invoked from a
# service / CI / hermes-gateway context. The env var is a one-shot guard so
# this block is idempotent if capture.sh ever sources another script.
if [ -z "${USER_SHELL_LOADED:-}" ]; then
  if [ -f "$HOME/.zshrc" ] && command -v zsh >/dev/null 2>&1; then
    USER_PATH=$(zsh -i -c 'echo $PATH' 2>/dev/null | tail -1)
  elif [ -f "$HOME/.bashrc" ]; then
    USER_PATH=$(bash -i -c 'echo $PATH' 2>/dev/null | tail -1)
  fi
  if [ -n "${USER_PATH:-}" ]; then
    export PATH="$USER_PATH"
  fi
  export USER_SHELL_LOADED=1
fi

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
import os, pathlib, re, subprocess

node_path = pathlib.Path('packages/node.yaml')
text = node_path.read_text()

# Defensive PATH prepend for the subprocesses below. Mirrors the pattern in
# scripts/devtools-upgrade.ts exec() helper (which prepends VOLTA_BIN +
# PNPM_BIN ahead of whatever the parent supplied). Required for hermes-
# gateway.service and CI runners that sanitize PATH. The bash-level
# USER_SHELL_LOADED guard at the top of capture.sh handles the parent
# shell; this handles the python3 subprocess inside.
#
# Try multiple candidate locations for volta + pnpm bin dirs because
# subprocess env's HOME may not match the user's real HOME (hermes-gateway
# subprocess inherits a different $HOME in some cases, CI runners often
# set $HOME=/tmp/<id>). The first one that exists wins.
_subprocess_env = os.environ.copy()
_user_home = os.path.expanduser('~')
_volta_candidates = [
    os.environ.get('VOLTA_HOME', '').rstrip('/') + '/bin' if os.environ.get('VOLTA_HOME') else None,
    f'{_user_home}/.volta/bin',
    '/home/ubuntu/.volta/bin',  # mercury host default; harmless on other hosts
]
_pnpm_candidates = [
    os.environ.get('PNPM_HOME', '').rstrip('/') + '/bin' if os.environ.get('PNPM_HOME') else None,
    f'{_user_home}/.local/share/pnpm/bin',
    '/home/ubuntu/.local/share/pnpm/bin',  # mercury host default
]
for cand in _volta_candidates:
    if cand and os.path.isdir(cand):
        _subprocess_env['PATH'] = cand + ':' + _subprocess_env.get('PATH', '')
        break
for cand in _pnpm_candidates:
    if cand and os.path.isdir(cand):
        _subprocess_env['PATH'] = cand + ':' + _subprocess_env['PATH']
        break

# ── default_node / default_npm / default_pnpm ─────────────────────────
try:
    volta_out = subprocess.check_output(
        ['volta', 'list', 'all'], text=True, env=_subprocess_env
    ).splitlines()
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

# ── cron: refresh hermes jobs + system cron.d list ───────────────────────
echo
echo "[cron]"
python3 - <<'PYEOF'
import json, os, pathlib, re

inv_path = pathlib.Path('inventory.yaml')
text = inv_path.read_text()
home = pathlib.Path.home()

# ── 1. system_cron_d: list of /etc/cron.d/<name> files present ──────
cron_d = pathlib.Path('/etc/cron.d')
real_system_cron = []
if cron_d.is_dir():
    for entry in sorted(cron_d.iterdir()):
        # Skip the .placeholder file Ubuntu ships
        if entry.name.startswith('.'):
            continue
        real_system_cron.append(f"/etc/cron.d/{entry.name}")
print(f"  system_cron_d: {len(real_system_cron)} entries: {[p.rsplit('/', 1)[-1] for p in real_system_cron]}")

# Replace the system_cron_d: block. The block has the form:
#   system_cron_d:
#     # comment
#     - item1
#     - item2
# We match the key line, optional indented comments, then the list items.
def replace_list_block(text, key, items, list_indent='  ', key_indent=''):
    """Replace the YAML list under `key:` with the given items.

    Tolerates indented comment lines between the key and the list items.
    """
    pat = re.compile(
        rf'^{re.escape(key_indent)}{re.escape(key)}:\n'
        rf'((?:{re.escape(list_indent)}[^\n]*\n)*)',
        re.MULTILINE,
    )
    m = pat.search(text)
    if not m:
        print(f"  {key}: not found in inventory, skipping")
        return text
    new_block = f"{key_indent}{key}:\n"
    for it in items:
        new_block += f"{list_indent}- {it}\n"
    return text[:m.start()] + new_block + text[m.end():]

text = replace_list_block(text, 'system_cron_d', real_system_cron, list_indent='    ', key_indent='  ')

# ── 2. hermes.jobs: parse ~/.hermes/cron/jobs.json ──────────────────
jobs_file = home / '.hermes' / 'cron' / 'jobs.json'
hermes_jobs = []
if jobs_file.exists():
    try:
        jd = json.loads(jobs_file.read_text())
        for j in jd.get('jobs', []):
            sched = j.get('schedule', {})
            display = sched.get('display', '?')
            hermes_jobs.append({'id': j.get('id', ''), 'schedule': display, 'name': j.get('name', '')})
    except json.JSONDecodeError as e:
        print(f"  hermes.jobs: JSON parse error: {e}")
print(f"  hermes.jobs: {len(hermes_jobs)} jobs")

# Replace the hermes.jobs: block using a per-entry diff that preserves
# hand-written comments. The previous fix (PR #64) replaced the whole
# block atomically, which silently stripped comments like:
#
#         # Watchdog for the Hermes gateway on :8644. no_agent cron that runs
#         # ~/.hermes/scripts/gateway-health-check.sh every 5 min; ...
#
# Per-entry diff is the right shape because the most common drift class
# is **cron id rotation** from `register-*-cron.sh`'s clean re-register
# contract — the block's structure (entries + comments + ordering) is
# stable for long periods, only the `id:` field changes. We update the
# `id:` line where needed and leave everything else verbatim. Comments,
# whitespace, and entry ordering are all preserved.
#
# Block shape (default-profile only — mercury-butler lives under
# hermes_profiles[] and capture.sh does not touch it):
#
#     jobs:
#       - id: xxx              ← entry marker (6 spaces + "- id:")
#         name: yyy
#         schedule: "..."
#         # comment           ← preserved verbatim
#       - id: zzz              ← next entry
#         ...
#                       ← block ends at first ≤4-space-indent, non-blank line
#
# Strategy:
#   1. Find `    jobs:` line, capture everything up to next sibling key.
#   2. Split on entry markers (`      - id:`), preserving each entry verbatim.
#   3. Build `name -> live_id` lookup from jobs.json.
#   4. For each inventory entry: if `name` matches a jobs.json entry AND
#      `id:` line differs from the live id, replace JUST the `id:` line.
#      Otherwise leave the entry untouched.
#   5. For each jobs.json entry whose name isn't in inventory, append a
#      new entry to the end of the block.
#   6. If hermes_jobs is empty (parse failure), leave the block untouched.

hermes_block_start_re = re.compile(r'^(    jobs:)[ \t]*[^\n]*\n', re.MULTILINE)

def update_hermes_jobs(text):
    m = hermes_block_start_re.search(text)
    if not m:
        print(f"  hermes.jobs: `    jobs:` line not found, skipping")
        return text
    # Capture only the `    jobs:` portion of the matched line — strip any
    # same-line value (`[]`, comments, etc.). The replacement ALWAYS starts
    # with a bare `    jobs:\n` so the parsed body line-for-line matches
    # what we wrote.
    prefix = f"{m.group(1)}\n"
    # Scan forward line by line until we hit a line at <6-space indent
    # (the next sibling key like `  hermes_profiles:` or `# Per-profile`
    # comment at 2-space indent). Collect the body verbatim.
    body_lines = []
    i = m.end()
    while i < len(text):
        nl = text.find('\n', i)
        if nl == -1:
            nl = len(text)
        line = text[i:nl + 1]
        if line and not line[0].isspace():
            # Non-whitespace start = end of block (a new top-level key).
            break
        # Count leading spaces. The block is entries at ≥6 spaces; the
        # terminating line is at ≤4 spaces (sibling key or comment).
        stripped = line.lstrip(' ')
        leading = len(line) - len(stripped)
        if leading < 6:
            break
        body_lines.append(line)
        i = nl + 1
    body = ''.join(body_lines)
    entries = []  # list of (raw_text, name_or_None, id_value_or_None)
    current = None
    for line in body.splitlines(keepends=True):
        m_id = re.match(r'^(      - id:\s*)([^\s#]*)(.*)$', line)
        if m_id:
            if current is not None:
                entries.append(current)
            current = {'raw': [line], 'id': m_id.group(2).strip(), 'name': None}
            continue
        m_name = re.match(r'^(\s+name:\s*)(.+?)\s*$', line)
        if m_name and current is not None:
            current['name'] = m_name.group(2).strip()
        if current is not None:
            current['raw'].append(line)
    if current is not None:
        entries.append(current)

    # Build name -> live_id lookup from hermes_jobs.
    live_by_name = {j['name']: j['id'] for j in hermes_jobs if j.get('name')}
    inventory_names = set()

    # Per-entry update: only touch the `id:` line.
    drift_count = 0
    new_block_lines = []
    for entry in entries:
        name = entry['name']
        inventory_names.add(name)
        if name in live_by_name and entry['id'] != live_by_name[name]:
            new_id = live_by_name[name]
            for line in entry['raw']:
                if re.match(r'^\s*- id:\s', line):
                    new_block_lines.append(re.sub(
                        r'^(\s*- id:\s*)[^\s#]*',
                        lambda mm, new_id=new_id: f"{mm.group(1)}{new_id}",
                        line, count=1,
                    ))
                    drift_count += 1
                else:
                    new_block_lines.append(line)
        else:
            # No drift — entry passes through verbatim (preserves comments).
            new_block_lines.extend(entry['raw'])

    # Append new jobs (in jobs.json but not in inventory).
    appended = 0
    for j in hermes_jobs:
        if j.get('name') and j['name'] not in inventory_names:
            new_block_lines.append(f"      - id: {j['id']}\n")
            new_block_lines.append(f"        name: {j['name']}\n")
            new_block_lines.append(f"        schedule: \"{j['schedule']}\"\n")
            inventory_names.add(j['name'])
            appended += 1

    if drift_count or appended:
        print(f"  hermes.jobs: {drift_count} id(s) refreshed, {appended} entry(s) appended")
    else:
        print(f"  hermes.jobs: 0 drift (block current)")

    new_block = ''.join(new_block_lines)
    return text[:m.start()] + prefix + new_block + text[i:]

text = update_hermes_jobs(text)

# ── 3. user_crontab: parse `crontab -l` ──────────────────────────────
import subprocess
user_crontab = None
try:
    out = subprocess.check_output(['crontab', '-l'], stderr=subprocess.DEVNULL, text=True).strip()
    user_crontab = out if out else None
except subprocess.CalledProcessError:
    # Exit 1 from crontab = no crontab
    user_crontab = None
print(f"  user_crontab: {'set' if user_crontab else 'empty'}")

# Replace the user_crontab: null line
if user_crontab:
    # We DO NOT write the contents (security + gitignore) — just mark non-null.
    text = re.sub(
        r'^([ \t]+user_crontab: ).+$',
        r'\1"present (not tracked — see /var/spool/cron/crontabs/$USER)"',
        text, count=1, flags=re.MULTILINE,
    )
else:
    text = re.sub(
        r'^([ \t]+user_crontab: ).+$',
        r'\1null',
        text, count=1, flags=re.MULTILINE,
    )

inv_path.write_text(text.rstrip('\n') + '\n')
print("  refreshed cron: block in inventory.yaml")
PYEOF

# ── state_backup: refresh mercury-state backup metadata ───────────────
echo
echo "[state_backup]"
python3 - <<'PYEOF'
import json, pathlib, re

inv_path = pathlib.Path('inventory.yaml')
text = inv_path.read_text()
backup_root = pathlib.Path('/home/ubuntu/data/backups')

# Read latest manifest
manifest = None
manifests = sorted(backup_root.glob('mercury-state-*.manifest.json'), reverse=True)
if manifests:
    latest = manifests[0]
    try:
        manifest = json.loads(latest.read_text())
        print(f"  latest: {latest.name}")
    except json.JSONDecodeError as e:
        print(f"  WARN: {latest.name} unparseable: {e}")

# Read latest verify
verify = None
verifies = sorted(backup_root.glob('mercury-state-*.verify.json'), reverse=True)
if verifies:
    latest_v = verifies[0]
    try:
        verify = json.loads(latest_v.read_text())
    except json.JSONDecodeError:
        pass

# Count existing tarballs
tarballs = sorted(backup_root.glob('mercury-state-*.tar.zst'))
print(f"  tarballs on disk: {len(tarballs)} (oldest: {tarballs[0].name if tarballs else 'none'}, newest: {tarballs[-1].name if tarballs else 'none'})")

# Replace the state_backup: block values
def replace_yaml_value(text, key, value):
    """Replace `key: <anything>` with `key: <value>` (preserves indent)."""
    if value is None:
        new_v = 'null'
    elif isinstance(value, bool):
        new_v = 'true' if value else 'false'
    elif isinstance(value, (int, float)):
        new_v = str(value)
    else:
        new_v = f'"{value}"'
    pat = re.compile(rf'^(\s+{re.escape(key)}:\s*)(.+)$', re.MULTILINE)
    if not pat.search(text):
        print(f"  {key}: not found in inventory, skipping")
        return text
    return pat.sub(rf'\g<1>{new_v}', text, count=1)

if manifest:
    text = replace_yaml_value(text, 'last_run_at', manifest.get('started_at_utc'))
    text = replace_yaml_value(text, 'last_size_mb', manifest.get('archive', {}).get('size_mb'))
    text = replace_yaml_value(text, 'last_file_count', manifest.get('contents', {}).get('file_count'))
    text = replace_yaml_value(text, 'last_sha256', manifest.get('archive', {}).get('sha256'))
if verify:
    samples_ok = verify.get('samples_ok')
    samples_total = verify.get('samples_total')
    text = replace_yaml_value(text, 'last_verify_ok', f"{samples_ok}/{samples_total}")
    text = replace_yaml_value(text, 'last_verify_at', verify.get('checked_at_utc'))
text = replace_yaml_value(text, 'tarballs_on_disk', len(tarballs))

inv_path.write_text(text.rstrip('\n') + '\n')
print("  refreshed state_backup: block in inventory.yaml")
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