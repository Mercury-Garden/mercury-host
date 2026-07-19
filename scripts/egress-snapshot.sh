#!/usr/bin/env bash
# egress-snapshot.sh — captures daily egress totals via vnstat, alerts if
# a single day's outbound exceeds the threshold (default 10 GB).
#
# Exit codes:
#   0 = within threshold (silent — empty stdout)
#   1 = over threshold (alert printed to stdout)
#   2 = vnstat missing, no traffic yet, or unparseable output (alert printed to stdout)
#
# Used as a `no_agent: true` cron script. Matches the gateway-health-check
# pattern: empty stdout = silent, non-empty = deliver to Discord via the
# cron system.
#
# Cadence: once daily (set on the cron entry).

set -uo pipefail

THRESHOLD_GB="${EGRESS_THRESHOLD_GB:-10}"
LOG_DIR="${EGRESS_LOG_DIR:-$HOME/data/backups}"
DATE_UTC="$(date -u +%Y-%m-%d)"
LOG_FILE="$LOG_DIR/egress-${DATE_UTC}.log"

mkdir -p "$LOG_DIR"

if ! command -v vnstat >/dev/null 2>&1; then
  cat <<EOF
🚨 **egress-snapshot: vnstat not installed**

- Host: \`$(hostname)\`
- Time: \`$(date -u +%Y-%m-%dT%H:%M:%SZ)\`

Cannot capture egress totals. Install \`vnstat\` (apt package
\`vnstat\`) and re-run the cron registration.
EOF
  exit 2
fi

# `vnstat -d --oneline` emits a single concatenated line per row:
#   row;iface;YYYY-MM-DD;rx;tx;total;rate;month_rx;month_tx;month_total;month_rate;year_...;...
# tx in field 5 (1-indexed) = $5 in awk, with units like "23.79 MiB".
# On a fresh install / no traffic yet, vnstat returns an English notice
# line like " enp0s6: No data. ..." with no semicolons. Treat that as
# "no data yet" and exit silently.
#
# The parse is done in awk to avoid shell variable-quoting hell and to
# keep shellcheck happy (no IFS= read with multiple unused fields).
read_tx_gb="$(vnstat -d --oneline 2>/dev/null | awk -F';' '
  /^[^;]*$/ { exit 3 }                                          # English notice, no semicolons
  NF >= 7 {
    # field 5 holds "<value> <unit>", e.g. "23.79 MiB"
    n = split($5, parts, " ")
    val = parts[1] + 0
    if      (parts[2] == "KiB") scale = 1.0 / (1024 * 1024)
    else if (parts[2] == "MiB") scale = 1.0 / 1024
    else if (parts[2] == "GiB") scale = 1.0
    else if (parts[2] == "TiB") scale = 1024.0
    else                       scale = 1.0 / 1024   # assume MiB if unknown
    printf "%.3f\n", val * scale
    exit 0
  }
  { exit 4 }                                                    # anything else: unparseable
' 2>/dev/null)"
awk_rc=$?

if [ "$awk_rc" = "3" ]; then
  # No semicolons in output → English notice → silent skip.
  printf '(no data yet for %s; vnstat returned an English notice line, not a row)\n' "$DATE_UTC" > "$LOG_FILE"
  exit 0
fi

if [ -z "$read_tx_gb" ] || [ "$awk_rc" != "0" ]; then
  printf '(parse issue for %s; awk_rc=%s output=%s)\n' "$DATE_UTC" "$awk_rc" "$read_tx_gb" > "$LOG_FILE"
  cat <<EOF
🚨 **egress-snapshot: vnstat output did not match expected schema**

- Host: \`$(hostname)\`
- Day: \`${DATE_UTC}\`
- awk_rc: \`${awk_rc}\`
- parsed_tx_GB: \`${read_tx_gb:-<empty>}\`

Expected \`vnstat -d --oneline\` to return \`<row>;<iface>;<date>;<rx>;<tx>;...\`
with the tx field shaped \`<number> <unit>\` (KiB|MiB|GiB|TiB). The live
output did not parse cleanly. Investigate \`vnstat -d\` and \`man vnstat\`.
EOF
  exit 2
fi

tx_gb="$read_tx_gb"

# Persist raw + parsed values to the daily log.
printf '%s: tx=%s GB (threshold %s GB)\n' "$DATE_UTC" "$tx_gb" "$THRESHOLD_GB" >> "$LOG_DIR/egress-history.log"

# Threshold check — alert if today's tx is over threshold.
over=$(awk -v t="$tx_gb" -v thr="$THRESHOLD_GB" 'BEGIN { print (t + 0 > thr + 0) ? 1 : 0 }')
if [ "$over" = "1" ]; then
  cat <<EOF
🚨 **Daily egress over threshold**

- Host: \`$(hostname)\`
- Day: \`${DATE_UTC}\`
- Today's outbound: \`${tx_gb} GB\`
- Threshold: \`${THRESHOLD_GB} GB\`

OpenViking Web Studio (memory.mercury.garden) or other services may be
driving unusual egress. Oracle Always Free caps egress at ~480 Mbps
aggregate; sustained high egress may trigger support tickets.

Check: \`vnstat -d\` for daily breakdown, \`vnstat -h\` for hourly detail.
EOF
  exit 1
fi

# Within threshold — silent.
exit 0