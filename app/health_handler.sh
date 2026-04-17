#!/bin/sh
# Handles one HTTP connection on stdin/stdout (invoked by socat).
# GET /health  — liveness (always 200 while this process can run)
# GET /ready   — readiness (200 when OpenVPN tun0 has IPv4 and Privoxy is running)

IFS= read -r req_line || exit 0
path=$(printf '%s' "$req_line" | awk '{print $2}' | tr -d '\r')

while IFS= read -r hdr; do
  hdr=$(printf '%s' "$hdr" | tr -d '\r')
  [ -z "$hdr" ] && break
done

case "$path" in
  /health)
    printf 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok'
    ;;
  /ready)
    if pgrep -x privoxy >/dev/null 2>&1 && ip addr show tun0 2>/dev/null | grep -q 'inet '; then
      printf 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\nConnection: close\r\n\r\nready'
    else
      printf 'HTTP/1.1 503 Service Unavailable\r\nContent-Type: text/plain\r\nContent-Length: 9\r\nConnection: close\r\n\r\nnot ready'
    fi
    ;;
  *)
    printf 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
    ;;
esac
