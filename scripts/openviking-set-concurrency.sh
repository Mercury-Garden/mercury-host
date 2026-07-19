#!/usr/bin/env bash
# openviking-set-concurrency.sh — adjust OpenViking concurrent-inference ceilings
# without restarting the provider path or losing the existing config.
#
# Plan §8.3: "embedding.max_concurrent: 4, vlm.max_concurrent: 8. Lower to 1
# if a misbehaving cron spikes cost."
#
# This script edits ~/.openviking/ov.conf in place and reloads openviking-server.
# `kill -HUP` does NOT make OpenViking re-read config; we must fully restart.
#
# Usage:
#   openviking-set-concurrency.sh               # show current values
#   openviking-set-concurrency.sh 4 8           # set embedding=4, vlm=8 (default)
#   openviking-set-concurrency.sh 1 1           # KILL SWITCH (both at 1)
#   openviking-set-concurrency.sh 4 8 --skip-restart   # write file, manual restart
#
# After running this script, the OpenViking server reloads; the next
# memory.add / viking_search call will use the new limits.

set -uo pipefail

CONFIG="${HOME}/.openviking/ov.conf"
SERVER_UNIT="openviking-server.service"

show_current() {
  python3 -c "
import json
d = json.load(open('$CONFIG'))
e = d.get('embedding', {}).get('max_concurrent', '?')
v = d.get('vlm', {}).get('max_concurrent', '?')
print(f'current:  embedding.max_concurrent={e}  vlm.max_concurrent={v}')
"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [--skip-restart] [EMBEDDING_CONCURRENT VLM_CONCURRENT]

Without arguments: show current values.

EMBEDDING_CONCURRENT / VLM_CONCURRENT: positive integers. Defaults from plan:
  embedding=4  vlm=8  (production)
  embedding=1  vlm=1  (kill switch — drops cost ceiling to ~1 RPM / 1 RPM)

After editing $CONFIG, openviking-server is restarted (unless --skip-restart).
EOF
}

main() {
  local skip_restart=0
  local emb="" vlm=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --skip-restart) skip_restart=1; shift ;;
      *) emb="$1"; vlm="${2:-}"; break ;;
    esac
  done

  echo "── Current config ──"
  show_current
  echo "  config file: $CONFIG"
  echo "  server unit: $SERVER_UNIT"
  echo

  if [ -z "$emb" ] || [ -z "$vlm" ]; then
    usage
    exit 0
  fi

  if ! [[ "$emb" =~ ^[0-9]+$ ]] || [ "$emb" -lt 1 ]; then
    echo "ERROR: embedding concurrency must be a positive integer, got: '$emb'" >&2
    exit 2
  fi
  if ! [[ "$vlm" =~ ^[0-9]+$ ]] || [ "$vlm" -lt 1 ]; then
    echo "ERROR: vlm concurrency must be a positive integer, got: '$vlm'" >&2
    exit 2
  fi

  # Detect mode
  local mode="custom"
  if [ "$emb" = "1" ] && [ "$vlm" = "1" ]; then
    mode="kill-switch (1 / 1 — minimum)"
  elif [ "$emb" = "4" ] && [ "$vlm" = "8" ]; then
    mode="default (4 / 8 — per plan §8.3)"
  fi

  echo "── Setting $mode ──"
  echo "  embedding.max_concurrent: $emb"
  echo "  vlm.max_concurrent:       $vlm"
  echo

  # Edit file in place: preserve everything else, just update the two fields.
  python3 - <<PYEOF
import json
p = "$CONFIG"
d = json.load(open(p))
d.setdefault("embedding", {})["max_concurrent"] = $emb
d.setdefault("vlm", {})["max_concurrent"] = $vlm
import os
mode = 0o600
flags = os.O_RDWR | os.O_CREAT | os.O_TRUNC
fd = os.open(p, flags, mode)
with os.fdopen(fd, "w") as f:
  json.dump(d, f, indent=2)
  f.write("\n")
os.chmod(p, 0o600)
print(f"  wrote {p} (mode 0600)")
PYEOF

  if [ "$skip_restart" = "1" ]; then
    echo "  --skip-restart given; not restarting server."
    echo "  Next call to openviking-server will still use the OLD values until"
    echo "  you run:  systemctl --user restart $SERVER_UNIT"
    exit 0
  fi

  echo
  echo "── Restarting openviking-server.service ──"
  systemctl --user restart "$SERVER_UNIT"

  # Wait for uvicorn to come up (server boot takes ~3-5s).
  echo "  waiting for /health ..."
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if curl -sf http://127.0.0.1:1933/health >/dev/null 2>&1; then
      echo "  ✓ ready after ${i}s"
      break
    fi
    sleep 1
  done

  echo
  echo "── Health check ──"
  if curl -sf http://127.0.0.1:1933/health > /dev/null; then
    echo "  ✓ /health responded"
  else
    echo "  ✗ /health did NOT respond — check: journalctl --user -u $SERVER_UNIT"
    exit 1
  fi

  echo
  echo "── New effective config ──"
  echo "  On the running server's perspective (may show old values until first request):"
  /home/ubuntu/.hermes/hermes-agent/venv/bin/ov status 2>&1 | grep -E "System|VLM|Embedding|Config" | head -5
  echo
  echo "  On disk (authoritative):"
  show_current
}

main "$@"