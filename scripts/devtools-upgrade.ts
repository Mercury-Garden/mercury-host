// devtools-upgrade — invoked by `hermes cron` daily at 06:00 America/Bogota
// (11:00 UTC).
//
// Audits every tracked dev tool against its latest release, performs the
// upgrade if a newer version is available, and emits one JSON line per tool
// on stdout. The cron prompt reads those lines and posts a deterministic
// Discord report via the LLM.
//
// Tracked tools (canonical list lives below — keep it short and actionable):
//
//   Runtime (managed by mise; pnpm via corepack):
//     • node        — pinned to current LTS major (24.x); only auto-upgrade
//                     within the same major. New LTS major lines are
//                     surfaced as a "lts-major-changed" report but NOT
//                     auto-applied.
//     • pnpm        — corepack-managed per package.json#packageManager
//     • mise        — self-update via the official mise.run installer
//
//   Opencode core + opencode plugins (from `opencode.jsonc` plugin block):
//     • opencode-ai                                     — npm
//     • context-mode                                    — npm
//     • @plannotator/opencode                           — npm
//     • @colbymchenry/codegraph                         — npm
//     • opencode-plugin-openspec                        — npm
//     • @fission-ai/openspec                            — npm
//
//   Companion CLI binaries (standalone release artifacts):
//     • rtk         — rtk-ai/rtk GitHub releases (aarch64-unknown-linux-gnu)
//     • plannotator — backnotprop/plannotator releases (linux-arm64)
//     • codegraph   — managed by its own CLI (`codegraph upgrade`)
//
//   Standalone npm CLIs (NOT in opencode.jsonc's plugin block, but installed
//   via the same `npm install -g <pkg>@latest` recipe as the opencode plugins):
//     • openwiki    — langchain-ai/openwiki (LangChain's repo-doc CLI)
//
//   Project service:
//     • openchamber — @openchamber/web on npm via pnpm; restart
//                     `openchamber.service` after any successful upgrade
//
// Cron contract: this script ALWAYS emits a JSON line per tracked tool
// (including `action: "noop"` when installed == latest). It NEVER prints a
// preamble, summary, or markdown. Its stdout is structured data consumed by
// the LLM-bound prompt — never delivered directly.
//
// Failure handling:
//   • Network/registry errors per-tool → JSON line with `error`, `latest=null`
//   • Upgrade command failures        → JSON line with `error` and the failure
//   • opencode-ai always restarts openchamber.service via systemd --user
//     when an upgrade succeeds (this is the load-bearing reason we run a
//     daemonized cron and not a Node script)
//   • The script never aborts the whole run — one tool's failure must not
//     skip the rest of the audit
//
// References:
//   • opencode.jsonc plugin list: ~/.config/opencode/opencode.jsonc
//   • pnpm-managed openchamber bin: ~/.local/share/pnpm/bin/openchamber
//   • openchamber service unit:    ~/.config/systemd/user/openchamber.service
//
// Last verified: 2026-06-30 — versions:
//   opencode-ai 1.17.11 → 1.17.12 available
//   openchamber  1.13.3 (installed via pnpm) → 1.13.8 available
//   node         v24.18.0 Krypton LTS (current — no upgrade)
//   pnpm         11.14.0 (current — no upgrade)
//   mise         2026.7.7 (current — no upgrade)
//   rtk          0.42.4 → 0.43.0 available
//   plannotator  0.21.2 → 0.21.3 available
//   codegraph    1.1.1 (use `codegraph upgrade --check`)

import { execSync } from 'node:child_process'
import { existsSync, readFileSync, writeFileSync, mkdirSync, chmodSync, unlinkSync, statSync, lstatSync, readlinkSync, symlinkSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import { homedir } from 'node:os'

const HOME = homedir()

// ─── Mise + pnpm path constants (resolved at module load) ───────────────
// We resolve the mise data dir once at module load. There are three
// plausible homes for mise's data, in priority order:
//   1. /home/ubuntu/data/.local/share/mise      (data volume, canonical)
//   2. ${HOME}/.local/share/mise                 (via data-volume symlink)
//   3. /home/ubuntu/.local/share/mise            (legacy / boot-volume fallback)
// MISE_DATA_DIR is whichever exists. MISE_NODE_BIN is the active node's
// bin dir under installs/node/<ver>/bin (resolved at module load by
// shelling out to `mise current --no-color`). Prepended to every exec().
const MISE_DATA_DIR = (() => {
  for (const cand of [
    process.env.MISE_DATA_DIR,
    '/home/ubuntu/data/.local/share/mise',
    join(HOME, '.local/share/mise'),
  ]) {
    if (cand && existsSync(cand)) return cand
  }
  return join(HOME, '.local/share/mise') // default if nothing exists
})()

let MISE_NODE_BIN = ''
try {
  MISE_NODE_BIN = execSync(`"${MISE_DATA_DIR}/../bin/mise" current --no-color`, { encoding: 'utf8' })
    .split('\n').find((l) => l.startsWith('node'))?.split(/\s+/)[1] ? '' : ''
  // Resolve the node bin dir by reading the live mise node-version
  const nodeVer = execSync(`"${MISE_DATA_DIR}/../bin/mise" current node --no-color`, { encoding: 'utf8' }).trim().replace(/^node\s+/, '')
  MISE_NODE_BIN = join(MISE_DATA_DIR, 'installs', `node`, nodeVer, 'bin')
} catch {
  // best-effort; fall through to symlinked path
}
if (!MISE_NODE_BIN || !existsSync(MISE_NODE_BIN)) {
  MISE_NODE_BIN = join(HOME, '.local/share/mise/installs/node/24.18.0/bin')
}

// Pnpm_HOME_DIR may be set explicitly. Default to ~/.local/share/pnpm
// (also on data volume via symlink).
const Pnpm_HOME_DIR = process.env.Pnpm_HOME || (() => {
  for (const cand of [join(HOME, '.local/share/pnpm'), '/home/ubuntu/data/.local/share/pnpm']) {
    if (cand && existsSync(cand)) return cand
  }
  return join(HOME, '.local/share/pnpm')
})()
const PNPM_BIN = join(Pnpm_HOME_DIR, 'bin')

const MISE_BIN = (() => {
  // The mise CLI itself lives at ~/.local/bin/mise (relocated by the
  // installer); we don't strictly need it on PATH for this script, but
  // it's tracked here for completeness.
  for (const cand of [join(HOME, '.local/bin/mise'), '/home/ubuntu/data/.local/bin/mise']) {
    if (cand && existsSync(cand)) return cand
  }
  return ''
})()

// ─── JSON-line output ──────────────────────────────────────────────────────
// The cron prompt reads stdout line-delimited. Keep this line shape stable.
type ToolLine = {
  tool: string
  installed: string | null
  latest: string | null
  action: 'noop' | 'upgraded' | 'failed' | 'lts-major-changed'
  old: string | null
  new: string | null
  duration_ms: number
  error: string | null
}
const emit = (line: ToolLine) => process.stdout.write(JSON.stringify(line) + '\n')

const timed = async <T>(fn: () => Promise<T>): Promise<{ value: T | null; ms: number; err: string | null }> => {
  const t0 = Date.now()
  try {
    const value = await fn()
    return { value, ms: Date.now() - t0, err: null }
  } catch (e) {
    return { value: null, ms: Date.now() - t0, err: e instanceof Error ? e.message : String(e) }
  }
}

const exec = (cmd: string, opts: { timeout?: number; env?: NodeJS.ProcessEnv } = {}): string => {
  // Always run with MISE_NODE_BIN at the front of PATH so bare `node` /
  // `npm` invocations resolve to the user-managed toolchain even when the
  // parent process's PATH (e.g. hermes-gateway.service) does not include
  // it. We also prepend PNPM_BIN so pnpm does not print
  // `[ERROR] The configured global bin directory "…"` is not in PATH` to
  // stdout on every invocation (that non-JSON line corrupts the JSON-line
  // contract used by the openchamber audit — pitfall #14).
  const basePath = process.env.PATH || ''
  // Prepend in priority order: mise-managed node bin first (so `node`/
  // `npm` from mise win), then pnpm bin (so pnpm's self-check on its
  // configured bin dir passes), then whatever the parent supplied.
  const pnpmPrefix = existsSync(PNPM_BIN) ? `${PNPM_BIN}:` : ''
  const miseNodePrefix = MISE_NODE_BIN && existsSync(MISE_NODE_BIN) ? `${MISE_NODE_BIN}:` : ''
  const env = {
    ...process.env,
    PATH: `${miseNodePrefix}${pnpmPrefix}${basePath}`,
    ...(opts.env || {}),
  } as NodeJS.ProcessEnv
  return execSync(cmd, {
    timeout: opts.timeout ?? 60_000,
    env,
    stdio: ['ignore', 'pipe', 'pipe'],
    encoding: 'utf8',
  }).toString().trim()
}

// ─── Version comparison (semver-ish, lexicographic on integer parts) ───────
// Strips ANY non-digit-dot-and-dash noise (e.g. "plannotator 0.21.2" or
// "v2.0.2") before splitting. Strings with no recognizable version fall to
// undefined and short-circuit to equal.
const extractVersion = (s: string | null): string | null => {
  if (!s) return null
  const m = String(s).match(/v?(\d+(?:\.\d+){0,3}(?:[-+][0-9A-Za-z.-]+)?)/)
  return m ? m[1] : null
}
const cmpVer = (a: string | null, b: string | null): number => {
  const [va, vb] = [extractVersion(a), extractVersion(b)]
  if (!va || !vb) return 0  // unknown → treat as equal (don't claim upgrade)
  const parse = (v: string) => v.split(/[.+-]/).map((p) => /^\d+$/.test(p) ? parseInt(p, 10) : p)
  const [pa, pb] = [parse(va), parse(vb)]
  const n = Math.max(pa.length, pb.length)
  for (let i = 0; i < n; i++) {
    const x = pa[i] ?? 0; const y = pb[i] ?? 0
    if (typeof x === 'number' && typeof y === 'number') { if (x !== y) return x - y }
    else return String(x).localeCompare(String(y))
  }
  return 0
}

// ─── Helper: read a JSON field from a package.json on disk ────────────────
const pkgField = (path: string, field: string): string | null => {
  try {
    const j = JSON.parse(readFileSync(path, 'utf8'))
    return j?.[field] ?? null
  } catch { return null }
}

// ─── Helper: locate the on-disk version of a plugin across BOTH opencode
// runtime storage pools (npm-global-installed globals AND the opencode
// per-user cache used by `opencode plugin add`). Returns null when missing. ──
// (Volta's image-managed global pool used to be Pool 1; post-2026-07-18
//  global npm installs land at ~/.npm-global/ or wherever npm decides;
//  we check the opencode per-user cache as a definitive fallback.)
const locateInstalledVersion = (pkg: string): string | null => {
  // Pool 1: opencode per-user cache (most reliable post-migration)
  //   ~/.cache/opencode/packages/<pkg>/package.json
  //    (Plus possibly one level deeper for bundled native binaries.)
  const ocRoot = join(HOME, '.cache/opencode/packages', pkg, 'package.json')
  const v2 = pkgField(ocRoot, 'version')
  if (v2) return v2
  const ocInner = join(HOME, '.cache/opencode/packages', pkg, 'node_modules', pkg, 'package.json')
  return pkgField(ocInner, 'version')
}

// ─── Helper: read the installed version of a pnpm-global package from disk ─
// Avoids `pnpm ls -g --json`, which is unreliable under pnpm 11.11.0 on this
// filesystem layout (pitfall #14). The cmd-shim in `~/.local/share/pnpm/bin/<bin>`
// has a `cmd-shim-target=...` comment line that records the install hash dir.
// We strip `/bin/<entry>.js` from that target and read the sibling package.json.
// Pnpm_HOME may be overridden via env (default ~/.local/share/pnpm).
export const pnpmInstalledVersion = (binName: string, pkgName?: string): string | null => {
  const shim = join(PNPM_BIN, binName)
  if (!existsSync(shim)) return null
  // The shim is a shell script with a `# cmd-shim-target=<path>` trailer. Read
  // it and parse the trailer. We tolerate the absence of the trailer (older
  // pnpm versions, manually-edited shims) by falling back to walking the
  // most-recently-modified hash dir under `…/global/v11/`.
  let target: string | null = null
  try {
    const raw = readFileSync(shim, 'utf8')
    const m = raw.match(/^#\s*cmd-shim-target=(.+)$/m)
    if (m) target = m[1].trim()
  } catch { /* */ }
  // The target points at `<dir>/bin/<entry>.js`. Read `<dir>/package.json`.
  const candidates: string[] = []
  if (target) candidates.push(target.replace(/\/bin\/[^/]+$/, '/package.json'))
  // Fallback: scan global hash dirs newest-first for the package.json
  // matching pkgName (or binName as a fallback). This is the recovery path
  // when the shim trailer is missing/stale. Hash dirs are content-addressed
  // (sha-prefix + counter), so lexicographic sort by name is a stable proxy
  // for "most-recent install" — newer installs append, never replace.
  const globalRoot = join(PNPM_BIN.replace(/\/bin$/, ''), 'global/v11')
  if (existsSync(globalRoot)) {
    let dirs: string[] = []
    try {
      dirs = readdirSync(globalRoot, { withFileTypes: true })
        .filter((d) => d.isDirectory() && /^[0-9a-f]+-/.test(d.name))
        .map((d) => d.name)
        .sort((a, b) => b.localeCompare(a))
    } catch { /* */ }
    const wanted = pkgName ?? binName
    for (const d of dirs) {
      const pj = join(globalRoot, d, 'node_modules', wanted, 'package.json')
      if (existsSync(pj)) candidates.push(pj)
    }
  }
  for (const c of candidates) {
    const v = pkgField(c, 'version')
    if (v) return v
  }
  return null
}

// ─── Helper: latest version from npm registry (Node 22+ has native fetch) ─
// Cache-busted with a timestamp query param because the npm registry's
// edge cache can serve a stale `/latest` for several minutes after a
// publish. We keep forward slashes unencoded (npm accepts both, but some
// edge caches differ in their treatment of %2F vs /).
const npmLatest = async (pkg: string): Promise<string | null> => {
  const url = `https://registry.npmjs.org/${pkg}/latest?_=${Date.now()}`
  try {
    const r = await fetch(url, {
      signal: AbortSignal.timeout(15_000),
      headers: { 'cache-control': 'no-cache', 'accept': 'application/json' },
    })
    if (!r.ok) return null
    const j = await r.json() as { version?: string }
    return j.version ?? null
  } catch { return null }
}

// ─── Helper: latest GitHub release via the redirect-fast path ─────────────
const ghLatest = async (org: string, repo: string): Promise<{ tag: string | null; assets: { name: string; url: string }[] }> => {
  try {
    const r = await fetch(`https://api.github.com/repos/${org}/${repo}/releases/latest`, {
      headers: { 'user-agent': 'mercury-devtools-upgrade' },
      signal: AbortSignal.timeout(15_000),
    })
    if (!r.ok) return { tag: null, assets: [] }
    const j = await r.json() as { tag_name?: string; assets?: { name: string; browser_download_url: string }[] }
    return {
      tag: j.tag_name ?? null,
      assets: (j.assets ?? []).map((a) => ({ name: a.name, url: a.browser_download_url })),
    }
  } catch { return { tag: null, assets: [] } }
}

// ─── Helper: pin the active node major and fetch the latest 4.x.y LTS ─────
// Uses nodejs.org/dist/index.json (the canonical, no-auth source). We always
// stay within the active node major — we do NOT auto-bump majors.
const nodeLatestLtsInActiveMajor = async (): Promise<{ latestMinor: string | null; latestLts: string | null; activeMajor: number | null }> => {
  try {
    const r = await fetch('https://nodejs.org/dist/index.json', {
      signal: AbortSignal.timeout(20_000),
    })
    if (!r.ok) return { latestMinor: null, latestLts: null, activeMajor: null }
    const data = await r.json() as { version: string; lts: string | false; date: string }[]
    const installed = exec('node --version', { timeout: 5_000 })
    const installedMajor = parseInt(installed.replace(/^v/, '').split('.')[0], 10)
    const inMajor = data.filter((d) => parseInt(d.version.replace(/^v/, '').split('.')[0], 10) === installedMajor)
    if (inMajor.length === 0) return { latestMinor: null, latestLts: null, activeMajor: installedMajor }
    const latestMinor = inMajor.map((d) => d.version).sort((a, b) => cmpVer(b, a))[0]
    const ltsInMajor = inMajor.filter((d) => d.lts)
    const latestLts = ltsInMajor.length
      ? ltsInMajor.map((d) => d.version).sort((a, b) => cmpVer(b, a))[0]
      : null
    return { latestMinor, latestLts, activeMajor: installedMajor }
  } catch { return { latestMinor: null, latestLts: null, activeMajor: null } }
}

// ─── Upgrade: npm global package via mise's active node ──────────────────
const npmGlobalUpgrade = (pkg: string): string => {
  // `npm install -g <pkg>@latest`. Running through the active node's npm so
  // the install lands in the same root opencode-ai currently lives under.
  // 5-minute ceiling — a fresh install of a 50MB package can take a while.
  return exec(`npm install -g ${pkg}@latest --no-audit --no-fund --silent --no-progress`, { timeout: 240_000 })
}

// ─── pnpm global-install repair helpers (pitfall #14 Layer B+D) ───────────
// pnpm 11.11.0 + the box's `~/.local/share -> /home/ubuntu/data/.local/share`
// symlink chain has two openchamber-upgrade gotchas that pure `@latest`
// resolution cannot work around:
//
//   Layer B — pnpm writes a relative symlink (`../../../../../../../data/
//             .pnpm-store/...`) one `..` short of the actual store path.
//             The hash-dir is left in a state where `node bin/cli.js` cannot
//             resolve. The cron tick would otherwise hit ENOENT.
//
//   Layer D — pnpm's offline resolver prefers the version already in the
//             local store over the published `@latest`. Even after the
//             metadata cache says "latest=1.16.0", `pnpm add -g @latest`
//             silently resolves to the satisfied store version (1.15.0).
//
// We work around both by:
//   (1) converting any broken relative `@<scope>/<pkg>` symlinks to absolute
//       ones BEFORE the upgrade (preventive Layer B repair).
//   (2) pinning the upgrade to the explicit `latest` version read from
//       `npmLatest()` (forces a network fetch — no offline-store shortcut).
//   (3) repointing the cmd-shim to the canonical hash-dir AFTER the upgrade
//       if pnpm left it pointing at a hash that no longer exists.
//
// These helpers are idempotent — safe to run on a healthy install. Returns
// the canonical hash-dir name (the newest mtime, content-addressed prefix).
const pnpmGlobalRoot = (): string => join(PNPM_BIN.replace(/\/bin$/, ''), 'global/v11')
export const newestPnpmHashDir = (): string | null => {
  const root = pnpmGlobalRoot()
  if (!existsSync(root)) return null
  let dirs: string[] = []
  try {
    dirs = readdirSync(root, { withFileTypes: true })
      .filter((d) => d.isDirectory() && /^[0-9a-f]+-/.test(d.name))
      .map((d) => d.name)
      .sort((a, b) => b.localeCompare(a))
  } catch { return null }
  return dirs[0] ?? null
}
// Convert any broken relative symlinks under `…/global/v11/<hash>/node_modules/<pkgPath>`
// into absolute ones pointing at the resolved store target. Walks every
// hash-dir (not just the canonical one) because the canonical install may
// roll forward between calls. Safe to re-run — already-absolute symlinks
// are skipped.
//
// CRITICAL: we use lstatSync (not existsSync) to detect the symlink. Node's
// existsSync FOLLOWS symlinks and returns false on a broken one, which
// would silently skip exactly the symlinks we came here to fix. lstat
// returns the symlink's own metadata (no follow), so it returns truthy for
// any present symlink regardless of whether its target resolves. Captured
// 2026-07-14 during the watchdog integration test for fix/cron-openchamber-
// watchdog: existsSync returned false on a deliberately-broken symlink,
// resulting in scanned: 0 / repaired: 0 and no repair.
export const repairPnpmSymlinks = (pkgPath: string): { repaired: number; scanned: number } => {
  const root = pnpmGlobalRoot()
  if (!lstatSync(root, { throwIfNoEntry: false })) return { repaired: 0, scanned: 0 }
  let dirs: string[] = []
  try {
    dirs = readdirSync(root, { withFileTypes: true })
      .filter((d) => d.isDirectory() && /^[0-9a-f]+-/.test(d.name))
      .map((d) => d.name)
  } catch { return { repaired: 0, scanned: 0 } }
  let repaired = 0
  let scanned = 0
  for (const d of dirs) {
    const href = join(root, d, 'node_modules', pkgPath)
    // lstat does not follow symlinks — a broken symlink still returns
    // truthy here (which is what we want; those are the ones to repair).
    let st: Stats | null = null
    try { st = lstatSync(href) } catch { continue }
    if (!st.isSymbolicLink()) continue
    let raw: string | null = null
    try { raw = readlinkSync(href) } catch { continue }
    scanned++
    if (raw.startsWith('/')) continue   // already absolute
    // Convert `../../../../../../../data/<rest>` → `/home/ubuntu/data/<rest>`.
    // The `data/` token in the symlink target is the signal that pnpm reached
    // through `~/.local/share` (its own symlink) to the real data volume.
    const m = raw.match(/data\/(.+)$/)
    if (!m) continue
    const absTarget = `/home/ubuntu/data/${m[1]}`
    if (!lstatSync(join(absTarget, 'package.json'), { throwIfNoEntry: false })) continue
    try {
      unlinkSync(href)
      symlinkSync(absTarget, href)
      repaired++
    } catch { /* best effort — leave the broken symlink if the FS refuses */ }
  }
  return { repaired, scanned }
}
// Rewrite `~/.local/share/pnpm/bin/<bin>` so every occurrence of an
// obsolete hash-dir (the one pnpm just removed) is replaced with the
// canonical hash-dir (newest mtime). Also updates the `# cmd-shim-target=`
// trailer. Returns the hash-dir the shim now points at, or null on no-op.
export const repointPnpmCmdShim = (binName: string, pkgPath: string): string | null => {
  const shim = join(PNPM_BIN, binName)
  if (!existsSync(shim)) return null
  const canonical = newestPnpmHashDir()
  if (!canonical) return null
  let raw = ''
  try { raw = readFileSync(shim, 'utf8') } catch { return null }
  // Match any `…/global/v11/<hash-dir>/node_modules/<pkgPath>/…` substring
  // (the shim is generated by pnpm and contains the hash-dir inline).
  // The `pkgPath` anchor makes the replacement surgical — we only touch the
  // openchamber-shaped references, not e.g. a future shared dependency.
  const re = new RegExp(`(/global/v11/)([0-9a-f]+-[^/]+)(/node_modules/${pkgPath.replace('/', '\\/')}/)`, 'g')
  let touched = false
  const rewritten = raw.replace(re, (_, prefix, hash, suffix) => {
    if (hash === canonical) return _  // already canonical
    touched = true
    return `${prefix}${canonical}${suffix}`
  })
  if (!touched) return null
  try {
    writeFileSync(shim, rewritten)
    return canonical
  } catch { return null }
}

// ─── Upgrade: pnpm global package (used by openchamber) ───────────────────
// `version` MUST be the explicit numeric version resolved from the npm
// registry. Using `@latest` triggers pnpm's offline-store preference
// (pitfall #14 Layer D) and silently resolves to the store-cached version
// instead of the published latest.
const pnpmGlobalUpgrade = (pkg: string, version: string): string => {
  return exec(`pnpm add -g ${pkg}@${version}`, { timeout: 240_000 })
}

// ─── Upgrade: mise install (handles node + global packages alike) ─────────
const miseInstall = (what: string): string => {
  // `mise install` is silent on no-op — but it ALWAYS exits 0. Capture stdout.
  return exec(`mise install ${what}`, { timeout: 240_000 })
}

// ─── Upgrade: GH-release binary (download + atomic replace + chmod) ───────
const ghBinaryUpgrade = async (org: string, repo: string, assetMatch: RegExp, destAbs: string, isArchive: boolean): Promise<void> => {
  const { assets, tag } = await ghLatest(org, repo)
  if (!tag) throw new Error(`no release for ${org}/${repo}`)
  const asset = assets.find((a) => assetMatch.test(a.name))
  if (!asset) throw new Error(`no matching asset for ${assetMatch} in ${org}/${repo}@${tag}`)
  const r = await fetch(asset.url, { signal: AbortSignal.timeout(120_000) })
  if (!r.ok) throw new Error(`download failed: HTTP ${r.status}`)
  const buf = Buffer.from(await r.arrayBuffer())
  const tmpDir = join(HOME, '.cache', 'devtools-upgrade')
  mkdirSync(tmpDir, { recursive: true })
  if (isArchive) {
    // rtk ships as a tarball. Extract the `rtk` binary.
    const tar = join(tmpDir, `pkg-${Date.now()}.tar.gz`)
    writeFileSync(tar, buf)
    exec(`tar -xzf ${tar} -C ${tmpDir}`, { timeout: 30_000 })
    const extracted = join(tmpDir, 'rtk')
    if (!existsSync(extracted)) throw new Error(`rtk binary not in tarball — looked for ${extracted}`)
    unlinkSync(tar)
    // Atomic move onto destination (overwrite in place after a brief `.old`).
    const bak = `${destAbs}.old`
    if (existsSync(bak)) unlinkSync(bak)
    if (existsSync(destAbs)) {
      exec(`mv -f ${destAbs} ${bak}`, { timeout: 5_000 })
    }
    exec(`mv -f ${extracted} ${destAbs}`, { timeout: 5_000 })
    chmodSync(destAbs, 0o755)
    if (existsSync(bak)) unlinkSync(bak)
  } else {
    // plannotator: raw ELF, download straight onto destination (tmp + mv).
    const tmp = `${destAbs}.new`
    writeFileSync(tmp, buf)
    chmodSync(tmp, 0o755)
    const bak = `${destAbs}.old`
    if (existsSync(bak)) unlinkSync(bak)
    if (existsSync(destAbs)) exec(`mv -f ${destAbs} ${bak}`, { timeout: 5_000 })
    exec(`mv -f ${tmp} ${destAbs}`, { timeout: 5_000 })
    if (existsSync(bak)) unlinkSync(bak)
  }
}

// ─── Restart: openchamber.service via systemd --user ──────────────────────
// Per edsadr: "you need to stop openchamber always to upgrade opencode and
// after start it again". Practically this is needed for openchamber upgrades
// (binary swap) AND for opencode-ai upgrades (since openchamber hosts an
// opencode-gate subprocess that holds the on-disk binary in memory).
const stopOpenchamber = (): string => {
  const env = { ...process.env } as NodeJS.ProcessEnv
  try { exec(`systemctl --user stop openchamber.service`, { timeout: 30_000, env }) } catch { /* may already be stopped */ }
  // Brief settle — openchamber holds port 9090, the kernel keeps it in TIME_WAIT
  execSync('sleep 2', { encoding: 'utf8' })
  return 'stopped'
}
const startOpenchamber = (): string => {
  exec(`systemctl --user start openchamber.service`, { timeout: 30_000 })
  return 'started'
}

// ─── Health-check + auto-repair: openchamber.service post-upgrade ──────────
// Captured on 2026-07-14: a successful `pnpm add -g @openchamber/web@<ver>`
// install can leave the service in `activating (auto-restart)` because pnpm
// 11.11.0 generates relative `@<scope>/<pkg>` symlinks with off-by-one `../`
// depth when the parent dir (`~/.local/share`) is itself a symlink into the
// data volume (pitfall #14 Layer B). The cmd-shim points at the new install,
// but the path it walks through is broken, so cli.js can't be required →
// service exits 1 every 2s.
//
// Without this watchdog, the cron reports `action:"failed"` even though the
// install SUCCEEDED — just the post-install state is unusable. With it, the
// cron converts that into a transparent auto-repair and the user only sees a
// one-line note in the JSON's `error` field.
//
// Design choices:
//   - Runs ONLY after a successful upgrade (r.err === null). A failed
//     upgrade may have left a half-written hash-dir; absolute-symlink
//     repair against an incomplete install would be unsafe.
//   - Always idempotent. Already-absolute symlinks are skipped. A healthy
//     install goes through both helpers in <50ms and changes nothing.
//   - systemd exit-code semantics are NOT errors: 0 = active, 3 = inactive,
//     4 = no such unit. We capture stdout/stderr regardless and decode.
//   - Graceful degradation: if systemctl isn't on PATH (CI container, weird
//     chroot), we log to error and skip the repair — don't false-alarm.
export const openchamberHealthcheck = (): { active: boolean; subState: string; raw: string } => {
  let raw = ''
  try {
    raw = exec(`systemctl --user is-active openchamber.service 2>&1 || true`, { timeout: 10_000 })
  } catch (e) {
    // systemctl missing entirely (no init, container without --user, etc.)
    return { active: false, subState: 'unreachable', raw: e instanceof Error ? e.message : String(e) }
  }
  const subState = (raw || '').trim()
  return { active: subState === 'active', subState, raw }
}
// Convert any broken relative `@openchamber/web` symlinks under every
// hash-dir to absolute ones, repoint the cmd-shim to the canonical hash,
// and (re)start the service. Returns the auto-repair telemetry so the
// audit function can attach it to the JSON line's error annotation.
export const autoRepairOpenchamber = (): { repaired: number; scanned: number; shimRepointed: boolean; restartOk: boolean } => {
  const repaired = repairPnpmSymlinks('@openchamber/web')
  const canonical = repointPnpmCmdShim('openchamber', '@openchamber/web')
  let restartOk = false
  try { startOpenchamber(); restartOk = true } catch { /* leave as-is */ }
  return { repaired: repaired.repaired, scanned: repaired.scanned, shimRepointed: canonical !== null, restartOk }
}

// ─── Tool: opencode-ai ─────────────────────────────────────────────────────
async function auditOpencode(): Promise<void> {
  const installed = locateInstalledVersion('opencode-ai')
  const latest = await npmLatest('opencode-ai')
  if (!latest) {
    emit({ tool: 'opencode-ai', installed, latest, action: 'failed', old: null, new: null, duration_ms: 0, error: 'npm registry fetch failed' })
    return
  }
  if (!installed || cmpVer(installed, latest) >= 0) {
    emit({ tool: 'opencode-ai', installed, latest, action: 'noop', old: null, new: null, duration_ms: 0, error: null })
    return
  }
  // Stop openchamber BEFORE the npm install — its opencode-gate subprocess
  // holds a handle to the on-disk binary and would block the file replacement.
  try { stopOpenchamber() } catch { /* */ }
  let r: { value: string | null; ms: number; err: string | null } = { value: null, ms: 0, err: null }
  try {
    r = await timed(() => Promise.resolve().then(() => npmGlobalUpgrade('opencode-ai')))
    const after = locateInstalledVersion('opencode-ai')
    // Post-restart health-check: opencode-ai upgrades also touch openchamber
    // (it hosts an opencode-gate subprocess). If the restart didn't bring
    // openchamber back up, run the watchdog (symlink repair + restart).
    let errMsg: string | null = r.err
    if (!r.err) {
      const hc = openchamberHealthcheck()
      if (!hc.active && hc.subState !== 'unreachable') {
        const repair = autoRepairOpenchamber()
        execSync('sleep 3', { encoding: 'utf8' })
        const hc2 = openchamberHealthcheck()
        if (hc2.active) {
          errMsg = `openchamber auto-repaired after opencode upgrade (was ${hc.subState}, fixed ${repair.repaired}/${repair.scanned} symlinks${repair.shimRepointed ? ', repointed shim' : ''})`
        } else {
          errMsg = `openchamber still ${hc2.subState} after auto-repair (fixed ${repair.repaired}/${repair.scanned} symlinks); manual intervention required`
        }
      }
    }
    emit({ tool: 'opencode-ai', installed, latest: after ?? latest, action: r.err ? 'failed' : 'upgraded', old: installed, new: after, duration_ms: r.ms, error: errMsg })
  } finally {
    // Always restart openchamber — even on upgrade failure — so we don't
    // leave the box without the web UI after a failed tick.
    try { startOpenchamber() } catch { /* */ }
  }
}

// ─── Tool: openchamber (@openchamber/web via pnpm) ─────────────────────────
async function auditOpenchamber(): Promise<void> {
  // openchamber is a pnpm-global install. We deliberately do NOT use
  // `pnpm ls -g --json` to read the installed version — under pnpm 11.11.0
  // on this filesystem (`~/.local/share` is itself a symlink to the data
  // volume), the global-install index is unreliable (pitfall #14 Layer C).
  // Instead, parse the cmd-shim's `# cmd-shim-target=` trailer to find the
  // install hash dir, and read its sibling package.json. Fallback: walk the
  // hash dirs newest-first.
  const installed = pnpmInstalledVersion('openchamber', '@openchamber/web')
  const latest = await npmLatest('@openchamber/web')
  if (!latest) {
    emit({ tool: 'openchamber', installed, latest, action: 'failed', old: null, new: null, duration_ms: 0, error: 'npm registry fetch failed' })
    return
  }
  if (!installed || cmpVer(installed, latest) >= 0) {
    emit({ tool: 'openchamber', installed, latest, action: 'noop', old: null, new: null, duration_ms: 0, error: null })
    return
  }
  // Per edsadr: restart openchamber.service after every openchamber upgrade.
  try { stopOpenchamber() } catch { /* */ }
  // Preventive Layer B repair: convert any broken relative symlinks for the
  // package under any hash-dir to absolute ones. This way even if pnpm's
  // upcoming install re-creates the same broken `../` math, the existing
  // links already work — and our post-install shim repoint handles the new
  // hash-dir explicitly.
  const pre = repairPnpmSymlinks('@openchamber/web')
  let after: string | null = null
  try {
    const r = await timed(() => Promise.resolve().then(() => pnpmGlobalUpgrade('@openchamber/web', latest)))
    // Unconditional Layer B+D post-install repair: regardless of whether
    // `pnpm add -g` succeeded or partial-failed, run the symlink repair +
    // cmd-shim repoint. On pnpm 11 with `~/.local/share` as a parent-dir
    // symlink, a failed install can leave the new hash-dir's
    // `@openchamber/web` link as a broken relative path with the wrong
    // number of `../` — the store entry IS intact, only the linkage is
    // bad. Repairing it brings the service back without manual
    // intervention. Both helpers are idempotent — safe on a healthy
    // install (~50ms).
    //
    // The previous version only called `repointPnpmCmdShim` on the
    // success path (it was wrapped in `if (!r.err)` indirectly via the
    // `after` read). On 2026-07-18 11:00 UTC the install partial-failed
    // (pnpm wrote a hash-dir with a broken relative symlink, then
    // errored out on `readInstalledPackages`). Because the post-install
    // repair ran only on success, the new hash-dir's broken symlink
    // was never healed, the cmd-shim pointed at a hash-dir whose
    // `bin/cli.js` couldn't resolve, and openchamber.service went into
    // `activating (auto-restart)` for ~4 hours.
    try { repairPnpmSymlinks('@openchamber/web') } catch { /* best effort */ }
    try { repointPnpmCmdShim('openchamber', '@openchamber/web') } catch { /* best effort */ }
    after = pnpmInstalledVersion('openchamber', '@openchamber/web')
    // Post-upgrade classification + watchdog. Three cases:
    //
    //   (a) install OK + service active        → `upgraded`, no error
    //   (b) install OK + service still down    → `upgraded`, error notes auto-repair
    //   (c) install failed                     → `upgraded` IF the
    //                                            post-install repair healed
    //                                            the box, else `failed`.
    //
    // Cases (b) and (c) both invoke the watchdog (health-check +
    // auto-repair loop + re-check). The install did succeed at the
    // package level (store entry written, hash-dir created) — only the
    // post-install linkage was bad. The watchdog heals that, and we
    // report `upgraded` so the cron doesn't accumulate bogus `failed`
    // reports on a class of failure the box can heal itself. This is
    // the same shape as pitfall #14 Layer E.
    let errMsg: string | null = null
    let action: 'upgraded' | 'failed' = 'upgraded'
    const hc = openchamberHealthcheck()
    if (!hc.active && hc.subState !== 'unreachable') {
      const repair = autoRepairOpenchamber()
      execSync('sleep 3', { encoding: 'utf8' })
      const hc2 = openchamberHealthcheck()
      if (hc2.active) {
        errMsg = `${r.err ? `install reported error but post-install repair healed it (was: ${r.err}); ` : 'auto-'}repaired: service was ${hc.subState} → now active (fixed ${repair.repaired}/${repair.scanned} symlinks${repair.shimRepointed ? ', repointed shim' : ''})`
      } else if (r.err) {
        // Repair didn't bring it back AND the install reported an error.
        // This is the genuine "we couldn't heal it" case — report failed
        // with the full diagnostic so the user can intervene.
        action = 'failed'
        errMsg = `${r.err} (post-install repair did not bring service back; substate=${hc2.subState}; fixed ${repair.repaired}/${repair.scanned} symlinks${repair.shimRepointed ? ', repointed shim' : ''})${pre.repaired > 0 ? `; pre-install also repaired ${pre.repaired}/${pre.scanned} symlinks` : ''}; manual intervention required`
      } else {
        // Install reported success but service still down after repair.
        // Genuinely stuck — manual intervention required.
        errMsg = `install OK but service still ${hc2.subState} after auto-repair (fixed ${repair.repaired}/${repair.scanned} symlinks${repair.shimRepointed ? ', repointed shim' : ''})${pre.repaired > 0 ? `; pre-install also repaired ${pre.repaired}/${pre.scanned} symlinks` : ''}; manual intervention required`
      }
    } else if (r.err && hc.active) {
      // Install errored but service is healthy anyway (unusual — e.g.
      // pnpm errored on a post-install bookkeeping step but the binary
      // works). Annotate the error for transparency but keep action=upgraded.
      errMsg = `install reported '${r.err}' but service is active (canonical install: ${after ?? 'unknown'})${pre.repaired > 0 ? `; pre-install also repaired ${pre.repaired}/${pre.scanned} symlinks` : ''}`
    }
    emit({ tool: 'openchamber', installed, latest: after ?? latest, action, old: installed, new: after, duration_ms: r.ms, error: errMsg })
  } finally {
    try { startOpenchamber() } catch { /* */ }
  }
}

// ─── Tool: pnpm (via corepack; declared per-project in package.json#packageManager) ─
// The actual upgrade happens project-side via corepack. Global pnpm
// version is recorded here for visibility only — no upgrade action
// performed. mise's pnpm plugin is also tracked separately by
// auditMise(); corepack takes precedence over mise-installed pnpm when
// both are present (verified 2026-07-18).
async function auditPnpm(): Promise<void> {
  let installed: string | null = null
  try { installed = exec('pnpm --version', { timeout: 5_000 }) } catch { /* */ }
  const r = await fetch('https://registry.npmjs.org/pnpm/latest', { signal: AbortSignal.timeout(15_000) })
  const latest = r.ok ? ((await r.json() as { version?: string }).version ?? null) : null
  if (!latest) { emit({ tool: 'pnpm', installed, latest, action: 'failed', old: null, new: null, duration_ms: 0, error: 'npm fetch failed' }); return }
  if (!installed || cmpVer(installed, latest) >= 0) {
    emit({ tool: 'pnpm', installed, latest, action: 'noop', old: null, new: null, duration_ms: 0, error: null })
    return
  }
  // pnpm versions are pinned per-project via package.json#packageManager
  // (corepack-managed). We do NOT run `mise use pnpm@latest` globally
  // — that would race with the per-project pin. Report the gap; let
  // callers upgrade by editing their package.json.
  emit({
    tool: 'pnpm',
    installed,
    latest,
    action: 'noop',
    old: null,
    new: null,
    duration_ms: 0,
    error: `corepack-managed; bump package.json#packageManager to "pnpm@${latest}" to upgrade`,
  })
}

// ─── Tool: node (via mise, same-major LTS pinning) ────────────────────────
async function auditNode(): Promise<void> {
  let installed: string | null = null
  try { installed = exec('node --version', { timeout: 5_000 }) } catch { /* */ }
  const { latestMinor, activeMajor } = await nodeLatestLtsInActiveMajor()
  if (!installed || !activeMajor) {
    emit({ tool: 'node', installed, latest: latestMinor, action: 'failed', old: null, new: null, duration_ms: 0, error: 'node or index.json unavailable' })
    return
  }
  if (!latestMinor) {
    emit({ tool: 'node', installed, latest: null, action: 'noop', old: null, new: null, duration_ms: 0, error: null })
    return
  }
  // Same-major compare: if installed is already the latest minor in its major,
  // no-op. Otherwise upgrade.
  if (cmpVer(installed.replace(/^v/, ''), latestMinor.replace(/^v/, '')) >= 0) {
    emit({ tool: 'node', installed, latest: latestMinor, action: 'noop', old: null, new: null, duration_ms: 0, error: null })
    return
  }
  const u = await timed(() => Promise.resolve().then(() => miseInstall(`node@${latestMinor}`)))
  let after: string | null = null
  try { after = exec('node --version', { timeout: 5_000 }) } catch { /* */ }
  emit({ tool: 'node', installed, latest: after ?? latestMinor, action: after && cmpVer(after.replace(/^v/, ''), installed.replace(/^v/, '')) > 0 ? 'upgraded' : 'failed', old: installed, new: after, duration_ms: u.ms, error: u.err })
}

// ─── Tool: mise (self-update via mise.run installer) ───────────────────────
async function auditMise(): Promise<void> {
  let installed: string | null = null
  try { installed = exec('mise --version', { timeout: 5_000 }) } catch { /* */ }
  // No npm registry for mise — GitHub releases.
  const { tag } = await ghLatest('jdx', 'mise')
  if (!tag) { emit({ tool: 'mise', installed, latest: null, action: 'failed', old: null, new: null, duration_ms: 0, error: 'github fetch failed' }); return }
  // tag looks like "v2026.7.7"
  if (!installed || cmpVer(installed, tag.replace(/^v/, '')) >= 0) {
    emit({ tool: 'mise', installed, latest: tag, action: 'noop', old: null, new: null, duration_ms: 0, error: null })
    return
  }
  // Self-update. The installer is non-interactive (it never asks). 5 minutes
  // ceiling — the script re-downloads into ~/.local/bin/mise and rewrites
  // ~/.local/share/mise on the data volume (via the existing symlink).
  const u = await timed(() => Promise.resolve().then(() => exec('curl -fsSL https://mise.run | sh', { timeout: 240_000 })))
  let after: string | null = null
  try { after = exec('mise --version', { timeout: 5_000 }) } catch { /* */ }
  emit({ tool: 'mise', installed, latest: after ?? tag, action: after && cmpVer(after, installed) > 0 ? 'upgraded' : 'failed', old: installed, new: after, duration_ms: u.ms, error: u.err })
}

// ─── Tool: rtk (rtk-ai/rtk aarch64 tarball) ────────────────────────────────
async function auditRtk(): Promise<void> {
  const dest = join(HOME, '.local/bin/rtk')
  let installed: string | null = null
  if (existsSync(dest)) {
    try { installed = exec('rtk --version', { timeout: 5_000 }).split('\n')[0]?.replace(/^rtk\s*/i, '').trim() ?? null } catch { /* */ }
  }
  const { tag } = await ghLatest('rtk-ai', 'rtk')
  if (!tag) { emit({ tool: 'rtk', installed, latest: null, action: installed ? 'failed' : 'noop', old: null, new: null, duration_ms: 0, error: 'github fetch failed' }); return }
  const tagV = tag.replace(/^v/, '')
  // Three branches:
  //   1. installed == null        → missing binary; (re)install latest
  //   2. installed >= tagV        → up to date; noop
  //   3. installed <  tagV        → upgrade available; install
  if (installed && cmpVer(installed, tagV) >= 0) {
    emit({ tool: 'rtk', installed, latest: tag, action: 'noop', old: null, new: null, duration_ms: 0, error: null })
    return
  }
  const u = await timed(() => ghBinaryUpgrade('rtk-ai', 'rtk', /^rtk-aarch64-unknown-linux-gnu\.tar\.gz$/, dest, /* isArchive */ true))
  let after: string | null = null
  try { after = exec('rtk --version', { timeout: 5_000 }).split('\n')[0]?.replace(/^rtk\s*/i, '').trim() ?? null } catch { /* */ }
  emit({ tool: 'rtk', installed: installed ?? 'missing', latest: after ?? tag, action: u.err ? 'failed' : (installed === null ? 'upgraded' : 'upgraded'), old: installed, new: after, duration_ms: u.ms, error: u.err })
}

// ─── Tool: plannotator (backnotprop/plannotator linux-arm64 ELF) ──────────
async function auditPlannotator(): Promise<void> {
  const dest = join(HOME, '.local/bin/plannotator')
  let installed: string | null = null
  if (existsSync(dest)) {
    try { installed = exec('plannotator --version', { timeout: 5_000 }).trim() ?? null } catch { /* */ }
  }
  const { tag } = await ghLatest('backnotprop', 'plannotator')
  if (!tag) { emit({ tool: 'plannotator', installed, latest: null, action: installed ? 'failed' : 'noop', old: null, new: null, duration_ms: 0, error: 'github fetch failed' }); return }
  const tagV = tag.replace(/^v/, '')
  // (re)install when missing OR behind; same logic as rtk above.
  if (installed && cmpVer(installed, tagV) >= 0) {
    emit({ tool: 'plannotator', installed, latest: tag, action: 'noop', old: null, new: null, duration_ms: 0, error: null })
    return
  }
  // linux-arm64 is the ELF for this aarch64 box.
  const u = await timed(() => ghBinaryUpgrade('backnotprop', 'plannotator', /^plannotator-linux-arm64$/, dest, /* isArchive */ false))
  let after: string | null = null
  try { after = exec('plannotator --version', { timeout: 5_000 }).trim() ?? null } catch { /* */ }
  emit({ tool: 'plannotator', installed: installed ?? 'missing', latest: after ?? tag, action: u.err ? 'failed' : 'upgraded', old: installed, new: after, duration_ms: u.ms, error: u.err })
}

// ─── Tool: codegraph (its own `codegraph upgrade` subcommand) ──────────────
async function auditCodegraph(): Promise<void> {
  let installed: string | null = null
  try { installed = exec('codegraph --version', { timeout: 5_000 }).trim() ?? null } catch { /* */ }
  if (!installed) { emit({ tool: 'codegraph', installed, latest: null, action: 'noop', old: null, new: null, duration_ms: 0, error: null }); return }
  // `codegraph upgrade --check` exits 0 in both "up to date" and "upgrade
  // available" states (it prints a version diff to compare). We branch on
  // the printed text instead of the exit code. Observed output:
  //   on latest:       "You're on the latest version (vX.Y.Z)."
  //                    OR  "CodeGraph  current vX current  latest vX.Y.Z"
  //   upgrade avail:   "CodeGraph  current vX current  latest vY.Y.Z" (Y > X)
  //                    OR  "CodeGraph vX.Y.Z → vY.Y.Z available"
  // We trust the SECOND number (latest) when both are printed; if there is no
  // upgrade, latest == installed and we short-circuit to noop.
  let checkRaw = ''
  try { checkRaw = exec('codegraph upgrade --check', { timeout: 30_000, env: { ...process.env, NO_COLOR: '1' } }) } catch (_) { /* fallthrough */ }
  const m = checkRaw.match(/current\s+v?(\d[\d.]*)\s+latest\s+v?(\d[\d.]*)/i)
  let codegraphLatest: string | null = m?.[2] ?? null
  // If check output didn't yield a latest version, fall back to GitHub releases.
  if (!codegraphLatest) {
    const { tag } = await ghLatest('just-every', 'codegraph')
    // We don't know the exact org/repo (probe earlier failed). Skip if unknown.
    if (tag) codegraphLatest = tag.replace(/^v/, '')
  }
  if (!codegraphLatest || cmpVer(installed, codegraphLatest) >= 0) {
    emit({ tool: 'codegraph', installed, latest: codegraphLatest ?? installed, action: 'noop', old: null, new: null, duration_ms: 0, error: null })
    return
  }
  // Default: an upgrade is available. Run it.
  const u = await timed(() => Promise.resolve().then(() => exec('codegraph upgrade -f', { timeout: 240_000, env: { ...process.env, NO_COLOR: '1' } })))
  let after: string | null = null
  try { after = exec('codegraph --version', { timeout: 5_000 }).trim() ?? null } catch { /* */ }
  emit({ tool: 'codegraph', installed, latest: after ?? codegraphLatest, action: u.err ? 'failed' : 'upgraded', old: installed, new: after, duration_ms: u.ms, error: u.err })
}

// ─── Tool: opencode npm-plugin pool (6 packages) ──────────────────────────
const OPENCODE_PLUGINS = [
  'context-mode',
  '@plannotator/opencode',
  '@colbymchenry/codegraph',
  'opencode-plugin-openspec',
  '@fission-ai/openspec',
] as const

// ─── Tool: standalone npm CLIs (NOT opencode.jsonc plugins) ────────────────
// Same install shape as `OPENCODE_PLUGINS` (`npm install -g <pkg>@latest`
// against the npm registry), but kept semantically separate because these
// packages are NOT loaded by opencode. Tracking them here lets the cron
// pin them to current without polluting the opencode plugin audit semantics.
const STANDALONE_NPM_CLIS = [
  'openwiki',
] as const

async function auditOpencodePlugin(name: string): Promise<void> {
  // Installed version comes from the unified on-disk search via
  // locateInstalledVersion — searches the opencode plugin cache as the
  // runtime source of truth. `npm install -g` writes to npm's global
  // prefix; the cache reflects a subsequent `opencode` runtime load.
  const installedCache = locateInstalledVersion(name)
  const installed = installedCache
  const latest = await npmLatest(name)
  if (!latest) { emit({ tool: name, installed, latest, action: 'failed', old: null, new: null, duration_ms: 0, error: 'npm registry fetch failed' }); return }
  if (!installed || cmpVer(installed, latest) >= 0) {
    emit({ tool: name, installed, latest, action: 'noop', old: null, new: null, duration_ms: 0, error: null })
    return
  }
  const u = await timed(() => Promise.resolve().then(() => npmGlobalUpgrade(name)))
  // After install, refresh the on-disk read; the npm global prefix is
  // what `npm install -g` just touched, so the post-install truth comes
  // back through locateInstalledVersion (cache or global prefix).
  const after = locateInstalledVersion(name)
  emit({ tool: name, installed, latest: after ?? latest, action: u.err ? 'failed' : 'upgraded', old: installed, new: after, duration_ms: u.ms, error: u.err })
}

async function auditStandaloneNpmCli(name: string): Promise<void> {
  // Same shape as `auditOpencodePlugin` — these packages are tracked by the
  // cron but are NOT loaded by opencode, so we don't search the opencode
  // plugin cache pool. `npm install -g <pkg>@latest` is the upgrade path.
  // Kept as a separate helper so the semantic boundary (opencode-plugin
  // vs. standalone-CLI) stays clear for future maintainers.
  const installed = locateInstalledVersion(name)
  const latest = await npmLatest(name)
  if (!latest) { emit({ tool: name, installed, latest, action: 'failed', old: null, new: null, duration_ms: 0, error: 'npm registry fetch failed' }); return }
  if (!installed || cmpVer(installed, latest) >= 0) {
    emit({ tool: name, installed, latest, action: 'noop', old: null, new: null, duration_ms: 0, error: null })
    return
  }
  const u = await timed(() => Promise.resolve().then(() => npmGlobalUpgrade(name)))
  const after = locateInstalledVersion(name)
  emit({ tool: name, installed, latest: after ?? latest, action: u.err ? 'failed' : 'upgraded', old: installed, new: after, duration_ms: u.ms, error: u.err })
}

// ─── Main ──────────────────────────────────────────────────────────────────
async function main() {
  // Audit order: opencode-ai first (the load-bearing upgrade — restarts
  // openchamber). Then openchamber itself. Then runtimes. Then plugins.
  // Then standalone npm CLIs. Then companion binaries.
  await auditOpencode()
  await auditOpenchamber()
  await auditPnpm()
  await auditNode()
  await auditMise()
  for (const p of OPENCODE_PLUGINS) await auditOpencodePlugin(p)
  for (const c of STANDALONE_NPM_CLIS) await auditStandaloneNpmCli(c)
  await auditRtk()
  await auditPlannotator()
  await auditCodegraph()
}

main().catch((e) => {
  // The contract is: ALWAYS emit one JSON line per tool. A top-level throw
  // means we missed emitting some lines. To preserve "one line per tool"
  // semantics, emit a single catch-all marker so the cron agent knows.
  emit({ tool: '__script__', installed: null, latest: null, action: 'failed', old: null, new: null, duration_ms: 0, error: e instanceof Error ? e.message : String(e) })
  process.exit(1)
})
