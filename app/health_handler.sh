#!/bin/sh
# Handles one HTTP connection on stdin/stdout (invoked by socat via EXEC).
# GET /health  — liveness (always 200 while this process can run)
# GET /ready   — readiness (200 when OpenVPN tun0 has IPv4 and Privoxy is running)

# Send HTTP response with JSON body (ASCII only; Content-Length = byte length of body).
send_json() {
  _status_line="$1"
  _body="$2"
  _len=$(printf '%s' "$_body" | wc -c | tr -d ' ')
  printf '%s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' \
    "$_status_line" "$_len" "$_body"
}

http_400() {
  send_json "HTTP/1.1 400 Bad Request" '{"error":"bad_request"}'
}

IFS= read -r req_line || {
  http_400
  exit 0
}
path=$(printf '%s' "$req_line" | awk '{print $2}' | tr -d '\r')
if [ -z "$path" ]; then
  http_400
  exit 0
fi

while IFS= read -r hdr; do
  hdr=$(printf '%s' "$hdr" | tr -d '\r')
  [ -z "$hdr" ] && break
done

case "$path" in
  /health)
    send_json "HTTP/1.1 200 OK" '{"status":"ok"}'
    ;;
  /ready)
    if pgrep -x privoxy >/dev/null 2>&1 && ip addr show tun0 2>/dev/null | grep -q 'inet '; then
      send_json "HTTP/1.1 200 OK" '{"status":"ready"}'
    else
      send_json "HTTP/1.1 503 Service Unavailable" '{"status":"not_ready"}'
    fi
    ;;
  *)
    send_json "HTTP/1.1 404 Not Found" '{"error":"not_found"}'
    ;;
esac
