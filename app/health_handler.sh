#!/bin/sh
# Handles one HTTP connection on stdin/stdout (invoked by socat via EXEC).
# GET /health   — liveness (always 200 while this process can run)
# GET /ready    — readiness, from the supervisor's published state
# GET /metrics  — Prometheus text exposition of endpoint latency/degradation

STATE_FILE="${STATE_FILE:-/var/lib/proxy/state}"
METRICS_FILE="${METRICS_FILE:-/var/lib/proxy/metrics.prom}"
MAX_HEADERS="${HEALTH_MAX_HEADERS:-64}"
# /ready fails if the supervisor has not refreshed its state within this many
# seconds. Must comfortably exceed VPN_WATCHDOG_INTERVAL (default 5s), since
# that is the refresh cadence; 60 tolerates a slow tick without masking a hang.
MAX_STATE_AGE="${HEALTH_MAX_STATE_AGE:-60}"

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
  awk 'NR == 1 { print ($2 == "-" ? "" : $2) }' "$STATE_FILE" 2>/dev/null
}
# Seconds since the supervisor last refreshed its state. The supervisor
# rewrites this every VPN_WATCHDOG_INTERVAL, so a growing age means the
# supervisor loop is wedged — the one failure mode where every other signal
# still looks healthy (privoxy up, tunnel up, last known state "ready").
state_age() {
  [ -r "$STATE_FILE" ] || { echo -1; return; }
  _sa_ts=$(awk 'NR == 1 { print $3 }' "$STATE_FILE" 2>/dev/null)
  case "$_sa_ts" in
    ''|*[!0-9]*) echo -1; return ;;
  esac
  echo $(( $(date +%s) - _sa_ts ))
}

case "$path" in
  /health)
    send_json "HTTP/1.1 200 OK" '{"status":"ok"}'
    ;;
  /ready)
    _st=$(read_state)
    _ep=$(read_endpoint)
    _age=$(state_age)
    if [ "$_st" != "ready" ]; then
      send_json "HTTP/1.1 503 Service Unavailable" \
        "{\"status\":\"not_ready\",\"reason\":\"state\",\"state\":\"${_st}\",\"endpoint\":\"${_ep}\",\"state_age_s\":${_age}}"
    elif ! pgrep -x privoxy >/dev/null 2>&1; then
      send_json "HTTP/1.1 503 Service Unavailable" \
        "{\"status\":\"not_ready\",\"reason\":\"privoxy_down\",\"state\":\"${_st}\",\"endpoint\":\"${_ep}\",\"state_age_s\":${_age}}"
    elif [ "$_age" -lt 0 ] || [ "$_age" -gt "$MAX_STATE_AGE" ]; then
      # State says ready but nothing has refreshed it. The supervisor loop is
      # wedged; serving traffic on that basis is exactly the silent failure
      # this endpoint exists to prevent.
      send_json "HTTP/1.1 503 Service Unavailable" \
        "{\"status\":\"not_ready\",\"reason\":\"stale_state\",\"state\":\"${_st}\",\"endpoint\":\"${_ep}\",\"state_age_s\":${_age},\"max_age_s\":${MAX_STATE_AGE}}"
    else
      send_json "HTTP/1.1 200 OK" \
        "{\"status\":\"ready\",\"endpoint\":\"${_ep}\",\"state_age_s\":${_age}}"
    fi
    ;;
  /metrics)
    # Staleness and readiness are computed at SCRAPE time, not render time —
    # baking them into the rendered file would make them describe the moment
    # the supervisor last ran, which is the very thing being measured.
    _age=$(state_age)
    _ready=0
    [ "$(read_state)" = "ready" ] && [ "$_age" -ge 0 ] && [ "$_age" -le "$MAX_STATE_AGE" ] \
      && pgrep -x privoxy >/dev/null 2>&1 && _ready=1
    _live="# HELP proxy_state_age_seconds Seconds since the supervisor refreshed its state.
# TYPE proxy_state_age_seconds gauge
proxy_state_age_seconds ${_age}
# HELP proxy_ready 1 when /ready would return 200.
# TYPE proxy_ready gauge
proxy_ready ${_ready}
# HELP proxy_up 1 whenever this endpoint can answer at all.
# TYPE proxy_up gauge
proxy_up 1"
    if [ -r "$METRICS_FILE" ]; then
      send_text "HTTP/1.1 200 OK" "text/plain; version=0.0.4; charset=utf-8" \
        "$(cat "$METRICS_FILE")
${_live}"
    else
      send_text "HTTP/1.1 200 OK" "text/plain; version=0.0.4; charset=utf-8" "${_live}"
    fi
    ;;
  *)
    send_json "HTTP/1.1 404 Not Found" '{"error":"not_found"}'
    ;;
esac
