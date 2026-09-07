#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MICROSERVICES_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TRIGGER_DIR="$SCRIPT_DIR/../webhook/triggers"
TRIGGER_FILE="$TRIGGER_DIR/deploy.pending"

mkdir -p "$TRIGGER_DIR"

echo "===================================================================="
echo "  RIDEHUB WEBHOOK DEPLOY WATCHER (VPS-MICROSERVICES)"
echo "===================================================================="
echo "Watching trigger file: $TRIGGER_FILE"
echo "Listening for webhook events..."

while true; do
  if [ -f "$TRIGGER_FILE" ]; then
    # Thu thập và gộp các service đang chờ deploy
    RAW_SERVICES="$(tr '\n' ',' < "$TRIGGER_FILE" | sed 's/,$//' | sed 's/^,//')"
    rm -f "$TRIGGER_FILE"

    echo ""
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🚀 Nhận trigger deploy cho: ${RAW_SERVICES:-all}"

    if [ "$RAW_SERVICES" = "all" ] || [ -z "$RAW_SERVICES" ]; then
      "$SCRIPT_DIR/auto-deploy.sh" || true
    else
      "$SCRIPT_DIR/auto-deploy.sh" -s "$RAW_SERVICES" || true
    fi
  fi
  sleep 3
done
