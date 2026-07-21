# Varlock + Pass rotation policy — Stage 8.4 of the Varlock plan

This document is the **rotation and offboarding procedure** for the
host-local encrypted Varlock+pass secret store that backs
`mercury-host`, `x-digest`, `better-bet`, and `scriptcaster`.

## What is on disk

| Path | Component | Notes |
|---|---|---|
| `~/.gnupg/` | GnuPG keyring | Live production GPG identity. Default is `1783B58858FD26D16D4BF58C490FE2DCACFEE578` (ed25519, RSA fallback if previously used), cv25519 subkey `F7C29CD4E50186EF8B1BEFEAABE4E09A78765D16` for encryption. |
| `~/.password-store/mercury/` | Encrypted secret store | One `.gpg` file per secret. Namespaced by `mercury/<repo>/<KEY>`. |
| Off-host encrypted recovery bundle | Recovery seed | Encrypted with a human-controlled symmetric passphrase (kept separately, not on the VM). Typically `mercury-recovery-<unix-timestamp>.asc.gpg`. |
| `~/.secrets/secrets.yaml` | Backup snapshot | Auto-discovered plaintext snapshot (mode 0600). Used by `backup-secrets.sh`; not authoritative for runtime. |

The **runtime authoritative store** is `~/.password-store/`. All
project schemas (`x-digest/.env.schema`, `better-bet/.env.schema`,
`scriptcaster/.env.schema`) reference entries under this directory.

## When to rotate

| Trigger | Action |
|---|---|
| Production GPG private key compromised (lost, stolen, exfiltrated) | Full rotation — new identity, re-encrypt all entries, re-mint recovery bundle, replace inventory.yaml pin |
| GPG key reaches expiry | Standard rotation — generate new identity, re-encrypt all entries, re-mint recovery bundle |
| `pass` upgrade that breaks on-disk format | No action if `~/.password-store` is the same format; re-import encrypted-store from `backup-mercury-state-*.tar.zst` if needed |
| `varlock` upgrade | No automatic rotation; verify round-trip after upgrade (see AGENTS.md upgrade recipe) |
| Project schema changes (new env var added/changed/removed) | NOT a key rotation; modify `.env.schema` and commit, then add/update the entry in `mercury/<repo>/<KEY>` |
| Operator leaves the project | Offboarding — see below |

## Rotation procedure (full — production identity)

Use this when you suspect the GPG private key has been exposed, or as a
scheduled key-refresh (recommended annually, or when the configured
expiry approaches).

### 1. Mint a fresh identity on the live host (or a fresh host)

```bash
# Recipe from Stage 2 — same parameters unless requirements changed.
# Generate a new ed25519 master + cv25519 subkey. 2-year expiry is the
# Stage 2 baseline; higher-frequency rotation means a shorter expiry.
gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-generate-key \
    'Mercury Secrets 2026 <mercury-secrets@mercury.garden>' \
    ed25519 default 2y
# Then add an encryption-capable subkey:
echo "Adding cv25519 subkey..."
gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-add-key "$NEW_FP" cv25519 encr 2y
```

If you want a passphrase-protected identity (recommended for higher-
assurance environments), substitute a non-empty `passphrase` above. Note
that passphrase-protected keys require a running `gpg-agent` with the
passphrase cached for unattended cron use; this is outside the plan's
default.

### 2. Re-encrypt every entry with the new key

```bash
NEW_FP=NEW_FP_HERE   # paste the new fingerprint
STORE=~/.password-store

# For each entry, decrypt with the OLD key (still works because we'll
# have backup), re-encrypt with the NEW key. The simplest recipe is
# to mirror Stages 4.5 / 5.5: read each plaintext (which lives in the
# project .env schemas' pass-store references), re-encrypt, verify
# round-trip.
#
# IMPORTANT: this requires lift-of-boundary. Read every .env, hash to
# sha256, hand to gpg via tempfile, round-trip, replace gpg files. Do
# NOT echo or log the plaintext. Audit memo required per the plan.
```

The simplest mechanized recipe (full migration under boundary lift):

```bash
# Run from each repo that has a varlock schema (x-digest, better-bet, scriptcaster)
for repo in ~/data/code/{x-digest,better-bet,scriptcaster}; do
  cd "$repo"
  # 1. Read .env.example (safe — no values, just key names) to enumerate
  #    which secrets each project declares in its schema.
  # 2. For each @sensitive @required key whose declaration is via
  #    pass("mercury/$REPO_BASE/$KEY"), read the existing .gpg entry:
  for key in $(grep -oP 'pass\("mercury/[^)]+/(\K[^)]+)' .env.schema | sort -u); do
    old_entry="$STORE/mercury/$REPO_BASE/$key.gpg"
    [ -f "$old_entry" ] || continue
    # 3. Decrypt with the OLD key, re-encrypt with the NEW key.
    gpg --batch --pinentry-mode loopback --yes \
        --decrypt "$old_entry" 2>/dev/null \
        | gpg --batch --yes --pinentry-mode loopback --trust-model always \
              -e -r "$NEW_FP" \
              --output "$old_entry.tmp"
    mv "$old_entry.tmp" "$old_entry"
    chmod 600 "$old_entry"
    # 4. Round-trip verify
    gpg --batch --pinentry-mode loopback --decrypt "$old_entry" >/dev/null \
        || echo "ROTATION FAILED: $key"
  done
done
```

This recipe **requires lift-of-boundary** because the plaintext
`.env` files contain the secret values. After rotation, the boundary
re-engages — only sha-prefixes appear in audit logs.

### 3. Update `~/.password-store/.gpg-id`

```bash
echo "$NEW_FP" > ~/.password-store/.gpg-id
chmod 600 ~/.password-store/.gpg-id
```

### 4. Re-mint the recovery bundle

```bash
# Export the new master key, symmetrically encrypt with the new
# passphrase (or reuse an existing one), put off-host.
WORKDIR=$(mktemp -d -t vp-key-XXXXXX); chmod 700 "$WORKDIR"
echo "${WORKDIR}/gpg-key.asc.gpg to be created"
gpg --batch --pinentry-mode loopback \
    --homedir "$WORKDIR" --armor --export-secret-keys "$NEW_FP" \
    | gpg --batch --pinentry-mode loopback --passphrase-fd 3 \
          --homedir "$WORKDIR" --symmetric --cipher-algo AES256 \
          --output "$WORKDIR/mercury-recovery-NEW.asc.gpg" \
          3<<< "$RECOVERY_PASSPHRASE"
shred -u /tmp/gpg-key.asc 2>/dev/null
chmod 600 "$WORKDIR/mercury-recovery-NEW.asc.gpg"
ls -la "$WORKDIR/mercury-recovery-NEW.asc.gpg"

# Copy off-host (manual step)
scp "$WORKDIR/mercury-recovery-NEW.asc.gpg" \
    "your-backup-storage:recoveries/mercury-$(date -u +%Y-%m-%d).asc.gpg"

# Verify integrity (sha256 round-trip):
sha256sum "$WORKDIR/mercury-recovery-NEW.asc.gpg"
echo "$RECOVERY_PASSPHRASE" | gpg --batch --pinentry-mode loopback --decrypt \
    --passphrase-fd 3 "$WORKDIR/mercury-recovery-NEW.asc.gpg" \
    3<<< "$RECOVERY_PASSPHRASE" \
    | head -3
# Should print the armored block start
```

### 5. Update inventory.yaml

The `inventory.yaml` file (or your host's declarative surface)
contains the GPG fingerprint pin. Update to the new fingerprint.

### 6. Re-run the audit + restore drill

```bash
bash scripts/audit.sh
bash scripts/test-varlock-backup-restore.sh
```

Both should pass with no drift.

## Offboarding procedure

When an operator leaves the project (or a fresh host is provisioned):

### If the recovery bundle is available and the key is intact

No action is required for secrets; the encryption is per-recipient
(GPG encrypts to the new identity's public key, which is on the
encrypted bundle). The new operator just needs to install GnuPG,
import the bundle, and the existing store remains decryptable.

### If the recovery bundle is lost

This is a total secret-store loss. The plan §7 risk register calls
this out: "Loss of GPG private key or passphrase = total secret-store
loss". Mitigation is the off-host bundle; if it's also lost, secrets
that existed only in the encrypted store are unrecoverable.

Mitigation strategies in priority order:

1. **Always maintain at least 2 off-host bundles** in different
   physical/logical locations. Cloud-storage encrypted vault + offline
   encrypted backup disk is the recommended pairing.
2. **Document the symmetric passphrase** in a password manager
   alongside the bundle. Two factors (having the bundle AND knowing
   the passphrase) is the recovery unlock.
3. **Verify the canary periodically** — once a month, restore to a
   fresh `$HOME` and confirm `gpg -d ~/.password-store/mercury/_canary/test.gpg`
   returns the expected value. This is what `scripts/probe-varlock-cold-decrypt.sh`
   automates.

## Migration-era backups (Stage 8 risk register)

> "Two sources of truth persist forever" risk → time-boxed dual-run;
> explicit Stage 8 retirement gate.

The plan migrates plaintext `.env` files out of the runtime path but
**retains them on disk** until 3+ clean cron ticks prove the
varlock-only path works in production (`./secrets/secrets.yaml` block
`x_digest_env` + `code_env_x-digest__env` remains as the safety net).

After Stage 8 formally closes:

* The plaintext `.env` files in `~/data/code/<repo>/.env` are
  `shred -u -z -n 3`'d (this already happened for x-digest on
  2026-07-21 as part of Stage 5.5).
* The `x_digest_env` block in `~/.secrets/secrets.yaml` is manually
  blanked (or removed) since auto-restore is no longer needed.
* `~/.password-store/mercury/<repo>/` is now the only runtime source.

The retention policy for migration-era backups:

* `~/.secrets/secrets.yaml` — retained for **30 days** post-Stage-8.
  After that, run `bash scripts/backup-secrets.sh --force && sed -i '/^x_digest_env:/,/^$/d' ~/.secrets/secrets.yaml` (or equivalent manual edit) to retire the plaintext block.
* Off-host bundle — retained **indefinitely**, rotated on key change.

## Test surface

| Script | Purpose | Run cadence |
|---|---|---|
| `scripts/test-varlock-backup-restore.sh` | Round-trip the encrypted store through tar+restore in a synthetic HOME | After any host-state change to the store; weekly cron |
| `scripts/probe-varlock-cold-decrypt.sh` | Prove canary decrypts from cold gpg-agent (post-restart) | After any gpg-agent restart |
| `scripts/probe-varlock-pass-backup-restore.sh` | Prove pass entries round-trip through tar+restore | After any backup/restore change |
| `scripts/audit.sh` (the `[varlock]` section) | Drift check: bin versions, store modes, canary | Daily (cron-driven via `register-secrets-test-cron.sh`) |

## Cross-references

* `secrets/inventory.yaml` — fingerprint pin (one line: `varlock-pass-store:` block)
* `secrets/secrets.yaml.template` — sanitized inventory (placeholder blocks)
* `AGENTS.md` — operator-facing rules
* `cron-recipes/x-digest-daily.md` — runtime invocation example
