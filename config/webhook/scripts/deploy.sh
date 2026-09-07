#!/bin/sh
set -eu

SERVICE="${1:-}"
TRIGGER_DIR="/triggers"
TRIGGER_FILE="${TRIGGER_DIR}/deploy.pending"

mkdir -p "$TRIGGER_DIR"

if [ -n "$SERVICE" ]; then
    echo "$SERVICE" >> "$TRIGGER_FILE"
    echo "✓ Queued deploy for service: $SERVICE"
else
    echo "all" >> "$TRIGGER_FILE"
    echo "✓ Queued deploy for all changed services"
fi
