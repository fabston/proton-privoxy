#!/bin/sh
# Handles one HTTP connection on stdin/stdout (invoked by socat via EXEC).
# GET /health   — liveness (always 200 while this process can run)
# GET /ready    — readiness, from the supervisor's published state
# GET /metrics  — Prometheus text exposition of endpoint latency/degradation

STATE_FILE="${STATE_FILE:-/var/lib/proxy/state}"
METRICS_FILE="${METRICS_FILE:-/var/lib/proxy/metrics.prom}"
MAX_HEADERS="${HEALTH_MAX_HEADERS:-64}"

# Send HTTP response with JSON body (ASCII only; Content-Length = byte length of body).
send_json() {
  _status_line="$1"
  _body="$2"
  _len=$(printf '%s' "$_body" | wc -c | tr -d ' ')
  printf '%s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' \
    "$_status_line" "$_len" "$_body"
}

send_text() {
  _status_line="$1"
  _ctype="$2"
  _body="$3"
  _len=$(printf '%s' "$_body" | wc -c | tr -d ' ')
  printf '%s\r\nContent-Type: %s\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' \
    "$_status_line" "$_ctype" "$_len" "$_body"
}

http_400() {
  send_json "HTTP/1.1 400 Bad Request" '{"error":"bad_request"}'
}

IFS= read -r req_line || {
  http_400
  exit 0
}
method=$(printf '%s' "$req_line" | awk '{print $1}' | tr -d '\r')
path=$(printf '%s' "$req_line" | awk '{print $2}' | tr -d '\r')
if [ -z "$path" ]; then
  http_400
  exit 0
fi

# Bounded header drain. Previously this loop had no limit, so a client that
# sent a request line and then streamed headers forever pinned a shell process
# for as long as it liked — one per connection, with socat forking unbounded.
_hcount=0
while [ "$_hcount" -lt "$MAX_HEADERS" ]; do
  IFS= read -r hdr || break
  hdr=$(printf '%s' "$hdr" | tr -d '\r')
  [ -z "$hdr" ] && break
  _hcount=$((_hcount + 1))
done

# Only GET/HEAD are meaningful here.
case "$method" in
  GET|HEAD) ;;
  *) send_json "HTTP/1.1 405 Method Not Allowed" '{"error":"method_not_allowed"}'; exit 0 ;;
esac

# Strip any query string so /ready?foo=1 still matches.
path=${path%%\?*}

# The supervisor publishes "<state> <endpoint> <epoch>". Reading it here means
# readiness cannot disagree with the supervisor about which tun interface is
# live — the previous version hardcoded tun0 while rotate_vpn.sh detects the
# interface dynamically, and `persist-tun` made "tun0 has an inet" true even
# while the tunnel was down.
read_state() {
  [ -r "$STATE_FILE" ] || { echo "unknown"; return; }
  awk 'NR == 1 { print $1 }' "$STATE_FILE" 2>/dev/null || echo "unknown"
}
read_endpoint() {
  [ -r "$STATE_FILE" ] || { echo ""; return; }
  awk 'NR == 1 { print $2 }' "$STATE_FILE" 2>/dev/null
}

case "$path" in
  /health)
    send_json "HTTP/1.1 200 OK" '{"status":"ok"}'
    ;;
  /ready)
    _st=$(read_state)
    _ep=$(read_endpoint)
    if [ "$_st" = "ready" ] && pgrep -x privoxy >/dev/null 2>&1; then
      send_json "HTTP/1.1 200 OK" "{\"status\":\"ready\",\"endpoint\":\"${_ep}\"}"
    else
      send_json "HTTP/1.1 503 Service Unavailable" \
        "{\"status\":\"not_ready\",\"state\":\"${_st}\",\"endpoint\":\"${_ep}\"}"
    fi
    ;;
  /metrics)
    if [ -r "$METRICS_FILE" ]; then
      send_text "HTTP/1.1 200 OK" "text/plain; version=0.0.4; charset=utf-8" "$(cat "$METRICS_FILE")"
    else
      send_text "HTTP/1.1 503 Service Unavailable" "text/plain; charset=utf-8" "# metrics not yet rendered"
    fi
    ;;
  *)
    send_json "HTTP/1.1 404 Not Found" '{"error":"not_found"}'
    ;;
esac
