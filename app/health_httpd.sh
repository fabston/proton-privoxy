#!/bin/sh
# Minimal HTTP server for /health and /ready (default: 0.0.0.0:8081).
# Requires socat.
#
# Use EXEC (not SYSTEM) so stdin/stdout map directly to the handler; SYSTEM
# runs via "sh -c" and can drop the connection before any response is sent.

HEALTH_PORT="${HEALTH_PORT:-8081}"
HEALTH_LISTEN_ADDR="${HEALTH_LISTEN_ADDR:-0.0.0.0}"

exec socat \
  "TCP-LISTEN:${HEALTH_PORT},bind=${HEALTH_LISTEN_ADDR},fork,reuseaddr" \
  "EXEC:/app/health_handler.sh"
