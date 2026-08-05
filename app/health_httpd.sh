#!/bin/sh
# Minimal HTTP server for /health and /ready (default: 0.0.0.0:8081).
# Requires socat.
#
# Use EXEC (not SYSTEM) so stdin/stdout map directly to the handler; SYSTEM
# runs via "sh -c" and can drop the connection before any response is sent.

HEALTH_PORT="${HEALTH_PORT:-8081}"
HEALTH_LISTEN_ADDR="${HEALTH_LISTEN_ADDR:-0.0.0.0}"
HEALTH_MAX_CHILDREN="${HEALTH_MAX_CHILDREN:-16}"
HEALTH_IO_TIMEOUT="${HEALTH_IO_TIMEOUT:-5}"

# max-children: `fork` with no cap lets anyone who can reach this port spawn
#   an unbounded number of shell processes, one per TCP connection.
# -T: idle timeout, so a client that connects and never sends a complete
#   request cannot hold a handler open indefinitely.
# This binds 0.0.0.0 inside the container's network namespace, which is fine;
# what matters is that docker-compose.yml publishes it to 127.0.0.1 on the
# host rather than to every interface.
exec socat -T "${HEALTH_IO_TIMEOUT}" \
  "TCP-LISTEN:${HEALTH_PORT},bind=${HEALTH_LISTEN_ADDR},fork,reuseaddr,max-children=${HEALTH_MAX_CHILDREN}" \
  "EXEC:/app/health_handler.sh"
