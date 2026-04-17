#!/bin/sh
# Minimal HTTP server for /health and /ready (default: 0.0.0.0:8081).
# Requires socat.

set -e
HEALTH_PORT="${HEALTH_PORT:-8081}"
HEALTH_LISTEN_ADDR="${HEALTH_LISTEN_ADDR:-0.0.0.0}"

exec socat \
  "TCP-LISTEN:${HEALTH_PORT},bind=${HEALTH_LISTEN_ADDR},fork,reuseaddr" \
  "SYSTEM:/app/health_handler.sh"
