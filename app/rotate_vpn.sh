#!/bin/sh
set -e
# set -x

echo "--- VPN Rotation Supervisor ---"

# --- CONFIGURATION ---
AUTH_FILE_PATH="/etc/openvpn/auth.txt"
OVPN_CONFIG_DIR="/etc/openvpn/configs"
PRIVOXY_CONFIG="/app/config"
OPENVPN_LOG="/tmp/openvpn_connect.log"
ROTATION_INTERVAL_SECONDS=${ROTATION_INTERVAL:-300}
VPN_CONNECT_TIMEOUT=${VPN_CONNECT_TIMEOUT:-45}
OVPN_FILE_PATTERN=${OVPN_FILE_PATTERN:-*.ovpn}

# --- ENDPOINT SCORING / DEGRADATION (see .env.example.txt) ---
ENDPOINT_SCORING_ENABLED=${ENDPOINT_SCORING_ENABLED:-1}
# Kill-switch cadence. Must stay fast and is independent of cycle length: it is
# the ONLY thing checking the tunnel, and at ROTATION_INTERVAL=86400 it is the
# difference between a 5-second leak and a 22-hour one.
VPN_WATCHDOG_INTERVAL=${VPN_WATCHDOG_INTERVAL:-5}
# Latency sampling cadence, deliberately decoupled from the watchdog. Sampling
# every 5s makes the EWMA span ~45s and the baseline ~8min, which on a long
# cycle means an evening traffic peak is measured against an afternoon baseline
# and reads as degradation. At 60s the baseline spans ~100min instead.
SAMPLE_INTERVAL=${SAMPLE_INTERVAL:-60}
PROBE_INTERVAL=${PROBE_INTERVAL:-60}
PASSIVE_RTT_ENABLED=${PASSIVE_RTT_ENABLED:-1}
PASSIVE_MIN_SOCKETS=${PASSIVE_MIN_SOCKETS:-2}
HALF_OPEN_INTERVAL=${HALF_OPEN_INTERVAL:-60}
DRAIN_GRACE=${DRAIN_GRACE:-10}
PROXY_PORT=${PROXY_PORT:-8100}
PROBE_TARGETS=${PROBE_TARGETS:-"http://ipv4.icanhazip.com/ http://ifconfig.me/ip"}
STATE_FILE=${STATE_FILE:-/var/lib/proxy/state}
DEBUG_LOG=${DEBUG_LOG:-0}

. /app/endpoint_stats.sh
. /app/probe_ttfb.sh

# Structured, timestamped logging. The previous unconditional DEBUG echoes are
# now gated on DEBUG_LOG so the rotation signal is not buried at 288 cycles/day.
ts()    { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
logi()  { echo "$(ts) INFO  $*"; }
logw()  { echo "$(ts) WARN  $*"; }
loge()  { echo "$(ts) ERROR $*"; }
logd()  { [ "$DEBUG_LOG" = "1" ] && echo "$(ts) DEBUG $*"; return 0; }

# Readiness is published as a file so the health handler does not have to
# re-derive it (and cannot disagree with the supervisor about the interface).
set_state() {
  mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
  printf '%s %s %s\n' "$1" "${2:-}" "$(date +%s)" > "${STATE_FILE}.tmp.$$" \
    && mv -f "${STATE_FILE}.tmp.$$" "$STATE_FILE"
}

# --- GLOBAL VARIABLES for file list ---
# OVPN_FILE_LIST will hold newline-separated, shuffled file paths
OVPN_FILE_LIST=""
# CURRENT_OVPN_FILE will hold the path for the current iteration
CURRENT_OVPN_FILE=""

# --- ENSURE /dev/net/tun EXISTS ---
if [ ! -c /dev/net/tun ]; then
  echo "FATAL: /dev/net/tun device not found."
  exit 1
fi

# --- ENSURE AUTH FILE EXISTS ---
if [ ! -f "$AUTH_FILE_PATH" ]; then
  echo "FATAL: OpenVPN auth file $AUTH_FILE_PATH not found."
  exit 1
fi

# --- FUNCTION TO LOAD AND SHUFFLE OVPN FILES into OVPN_FILE_LIST ---
load_and_shuffle_ovpn_files() {
  echo "DEBUG (func): Entered load_and_shuffle_ovpn_files."
  _old_ifs="$IFS"
  IFS=$'\n'
  echo "DEBUG (func): IFS set to newline."

  echo "DEBUG (func): Finding files in $OVPN_CONFIG_DIR (pattern: $OVPN_FILE_PATTERN)..."
  # OVPN_FILE_LIST is a global variable
  OVPN_FILE_LIST=$(find "$OVPN_CONFIG_DIR" -maxdepth 1 -type f -name "$OVPN_FILE_PATTERN" -print 2>/tmp/find_stderr.txt | shuf)
  _find_stderr=$(cat /tmp/find_stderr.txt)
  if [ -n "$_find_stderr" ]; then
    echo "DEBUG (func): find stderr: [$_find_stderr]"
  fi

  echo "DEBUG (func): OVPN_FILE_LIST is now: --START--\n$OVPN_FILE_LIST\n--END--"
  _list_len=$(echo -n "$OVPN_FILE_LIST" | wc -c)
  echo "DEBUG (func): OVPN_FILE_LIST character count (wc -c): $_list_len"

  IFS="$_old_ifs"
  echo "DEBUG (func): Restored IFS to [$_old_ifs]."

  if [ -z "$OVPN_FILE_LIST" ]; then
    echo "No .ovpn configuration files found in $OVPN_CONFIG_DIR"
    echo "DEBUG (func): OVPN_FILE_LIST is empty. Returning 1 (failure)."
    return 1
  fi

  _num_files=$(echo "$OVPN_FILE_LIST" | wc -l | awk '{$1=$1};1') # Count lines, trim whitespace
  echo "Found $_num_files OVPN configuration files in OVPN_FILE_LIST. Ready to cycle."
  echo "DEBUG (func): Returning 0 (success)."
  return 0
}

# --- FUNCTION to detect VPN interface name from log or system ---
detect_vpn_interface() {
  _iface=""
  if [ -f "$OPENVPN_LOG" ]; then
    _iface=$(sed -n 's/.*TUN\/TAP device \([^ ]*\).*/\1/p' "$OPENVPN_LOG" | head -n 1)
  fi
  if [ -z "$_iface" ]; then
    _iface=$(ip link show 2>/dev/null | awk -F': ' '/tun[0-9]+/ {sub(":", "", $2); print $2; exit}')
  fi
  echo "$_iface"
}

# --- FUNCTION to get the next file from OVPN_FILE_LIST ---
# Modifies OVPN_FILE_LIST (removes the first line)
# Sets CURRENT_OVPN_FILE
# Returns 0 if a file was retrieved, 1 if the list was empty
get_next_ovpn_file() {
  if [ -z "$OVPN_FILE_LIST" ]; then
    CURRENT_OVPN_FILE=""
    return 1 # List is empty
  fi

  _old_ifs="$IFS"
  IFS=$'\n' # Ensure we process line by line

  # Get the first line (next file)
  # Use `read` to get the first line, and `tail -n +2` to get the rest.
  # This is a bit more robust than direct string manipulation for multiline strings in sh.
  # However, simple string manipulation might be easier if read proves tricky with BusyBox sh.
  # Let's try with `expr` and `sed` first for simplicity, common in BusyBox.

  # Get first line
  CURRENT_OVPN_FILE=$(echo "$OVPN_FILE_LIST" | head -n 1)

  # Get rest of the lines (everything except the first)
  # `sed '1d'` deletes the first line
  OVPN_FILE_LIST=$(echo "$OVPN_FILE_LIST" | sed '1d')

  IFS="$_old_ifs"

  if [ -z "$CURRENT_OVPN_FILE" ]; then # Should not happen if OVPN_FILE_LIST was not empty
      return 1
  fi
  return 0
}


# --- GLOBAL VARIABLE FOR PRIVPROXY PID ---
privoxy_pid=""

# --- HEALTH HTTP (socat) PID ---
health_socat_pid=""

# --- SHUTDOWN FLAG ---
# Set by the INT/TERM handler; every wait point in the main loop polls it.
# The handler itself must be cheap and must NOT tear anything down: the actual
# teardown runs once, from the EXIT trap.
_shutdown=0
_cleanup_done=0

on_signal() {
  _shutdown=1
  logw "event=signal_received action=drain_and_exit"
  set_state draining ""
}

# --- FUNCTION TO CLEANUP PROCESSES ---
cleanup() {
  [ "$_cleanup_done" = "1" ] && return 0
  _cleanup_done=1
  echo "Caught signal or exiting, cleaning up..."
  set_state stopping ""
  # Let in-flight proxy requests finish before the listener dies.
  drain_privoxy
  if [ -n "$health_socat_pid" ] && kill -0 "$health_socat_pid" 2>/dev/null; then
    echo "Stopping health HTTP listener (PID: $health_socat_pid)..."
    kill "$health_socat_pid" 2>/dev/null || true
    _wait_count=0
    while kill -0 "$health_socat_pid" 2>/dev/null && [ $_wait_count -lt 5 ]; do
      sleep 0.5
      _wait_count=$((_wait_count + 1))
    done
    if kill -0 "$health_socat_pid" 2>/dev/null; then
      kill -9 "$health_socat_pid" 2>/dev/null || true
    fi
  fi
  health_socat_pid=""

  if [ -n "$privoxy_pid" ] && kill -0 "$privoxy_pid" 2>/dev/null; then
    echo "Stopping Privoxy (PID: $privoxy_pid)..."
    kill "$privoxy_pid"
    _wait_count=0
    while kill -0 "$privoxy_pid" 2>/dev/null && [ $_wait_count -lt 5 ]; do
        sleep 0.5
        _wait_count=$((_wait_count + 1))
    done
    if kill -0 "$privoxy_pid" 2>/dev/null; then
        echo "Privoxy (PID: $privoxy_pid) did not stop gracefully, forcing kill (SIGKILL)."
        kill -9 "$privoxy_pid"
    fi
  fi
  privoxy_pid=""

  if pgrep -x openvpn > /dev/null; then
    echo "Stopping OpenVPN..."
    pkill -TERM openvpn
    _wait_count=0
    while pgrep -x openvpn > /dev/null && [ $_wait_count -lt 10 ]; do
      sleep 0.5
      _wait_count=$((_wait_count + 1))
    done
    if pgrep -x openvpn > /dev/null; then
      echo "OpenVPN did not stop gracefully, forcing kill (SIGKILL)..."
      pkill -KILL openvpn
    fi
  fi
  echo "Cleanup complete."
}

# INT/TERM only flag; EXIT does the teardown. Keeping them separate avoids the
# re-entrancy bug where the signal handler tears down and then the EXIT trap
# tears down again over a half-dead process tree.
trap on_signal INT TERM
trap cleanup EXIT

############################################################################
#            CONNECTION DRAINING, TUNNEL WATCHDOG, CYCLE SUPERVISOR        #
############################################################################

# ---------------------------------------------------------------------------
# drain_privoxy
#
# Rotation used to SIGKILL-adjacent Privoxy while requests were in flight, so
# every CONNECT tunnel and keep-alive connection died mid-response. Now we
# stop accepting (SIGTERM) and then wait for established client sockets on the
# proxy port to fall to zero, bounded by DRAIN_GRACE.
#
# The socket count comes from `ss` rather than from Privoxy's own behaviour so
# the drain is verifiable without depending on Privoxy internals.
# ---------------------------------------------------------------------------
proxy_conn_count() {
  # `wc -l`, not `grep -c .`: grep prints 0 AND exits non-zero on no match, so
  # a `|| echo 0` fallback emits two lines and breaks the numeric comparison.
  ss -Htn state established "sport = :${PROXY_PORT}" 2>/dev/null | wc -l | tr -d ' '
}

drain_privoxy() {
  [ -n "$privoxy_pid" ] || return 0
  kill -0 "$privoxy_pid" 2>/dev/null || { privoxy_pid=""; return 0; }

  _dr_start_conns=$(proxy_conn_count)
  logi "event=drain_begin pid=$privoxy_pid inflight=$_dr_start_conns grace=${DRAIN_GRACE}s"
  kill -TERM "$privoxy_pid" 2>/dev/null || true

  _dr=0
  while [ "$_dr" -lt "$DRAIN_GRACE" ]; do
    kill -0 "$privoxy_pid" 2>/dev/null || break
    [ "$(proxy_conn_count)" -eq 0 ] && break
    sleep 1
    _dr=$((_dr + 1))
  done

  _dr_left=$(proxy_conn_count)
  if kill -0 "$privoxy_pid" 2>/dev/null; then
    [ "$_dr_left" -gt 0 ] && logw "event=drain_timeout aborted_connections=$_dr_left"
    kill -KILL "$privoxy_pid" 2>/dev/null || true
  fi
  wait "$privoxy_pid" 2>/dev/null || true
  logi "event=drain_end waited=${_dr}s aborted=$_dr_left"
  privoxy_pid=""
}

# ---------------------------------------------------------------------------
# vpn_tunnel_alive — the kill switch
#
# The .ovpn files ship `persist-tun`, so tun0 keeps its IPv4 address while the
# tunnel is DOWN and reconnecting. An "interface has an inet" check therefore
# proves nothing. Three things must all hold:
#   1. an openvpn process exists and is not a zombie
#   2. the tun interface still carries the default route
#   3. the interface is administratively up
# If any fails we rotate immediately rather than serve through a dead or
# leaking path.
# ---------------------------------------------------------------------------
openvpn_running() {
  # `pgrep` matches zombies; exclude them so a reaped-but-unwaited openvpn
  # cannot masquerade as a live tunnel.
  pgrep -x openvpn 2>/dev/null | while read -r _p; do
    _st=$(awk '{print $3}' "/proc/$_p/stat" 2>/dev/null)
    [ "$_st" = "Z" ] || { echo live; break; }
  done | grep -q live
}

vpn_tunnel_alive() {
  openvpn_running || { logd "tunnel_check=fail reason=no_openvpn"; return 1; }
  ip route show default 2>/dev/null | grep -q "dev $VPN_INTERFACE" \
    || { logd "tunnel_check=fail reason=default_route_not_on_$VPN_INTERFACE"; return 1; }
  ip link show "$VPN_INTERFACE" 2>/dev/null | grep -q "state UNKNOWN\|state UP\|UP," \
    || { logd "tunnel_check=fail reason=iface_down"; return 1; }
  return 0
}

# interruptible_sleep <seconds> — a bare `sleep` blocks trap delivery until it
# returns, which is why `docker stop` used to sit for its full grace period
# and then SIGKILL. Backgrounding it and using `wait` makes the shell
# interruptible, because POSIX `wait` is interrupted by a trapped signal.
interruptible_sleep() {
  sleep "$1" &
  _is_pid=$!
  wait "$_is_pid" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# run_cycle <endpoint_name> <duration_seconds>
#
# Replaces the old blocking `sleep $ROTATION_INTERVAL`. Every tick it:
#   1. checks the tunnel (kill switch)
#   2. takes a passive RTT sample from real proxied sockets
#   3. falls back to an in-path TTFB probe when traffic was too thin
#   4. re-evaluates the endpoint and trips it if it has degraded
#   5. re-renders metrics
#
# Exit status: 0 = interval completed normally, 1 = cut short (reason in
# $ROTATION_REASON).
# ---------------------------------------------------------------------------
ROTATION_REASON="scheduled"

run_cycle() {
  _rc_ep="$1"; _rc_dur="$2"
  _rc_elapsed=0
  _rc_since_probe=$PROBE_INTERVAL
  _rc_since_sample=$SAMPLE_INTERVAL
  _rc_target_idx=0
  ROTATION_REASON="scheduled"

  # shellcheck disable=SC2086
  set -- $PROBE_TARGETS
  _rc_ntargets=$#

  while [ "$_rc_elapsed" -lt "$_rc_dur" ]; do
    [ "$_shutdown" = "1" ] && { ROTATION_REASON="shutdown"; return 1; }

    if ! vpn_tunnel_alive; then
      loge "endpoint=$_rc_ep event=tunnel_down action=rotate_now"
      stats_record "$_rc_ep" 0 1
      ROTATION_REASON="vpn_down"
      return 1
    fi

    # The kill-switch check above runs every tick. Sampling and scoring run on
    # the slower SAMPLE_INTERVAL so the statistics describe the endpoint rather
    # than the last 45 seconds of it.
    _rc_since_sample=$((_rc_since_sample + VPN_WATCHDOG_INTERVAL))
    if [ "$ENDPOINT_SCORING_ENABLED" = "1" ] && [ "$_rc_since_sample" -ge "$SAMPLE_INTERVAL" ]; then
      _rc_since_sample=0
      _rc_got=0
      # Computed BEFORE recording: stats_record uses it to freeze the baseline
      # while a sample is already anomalous, so a sustained degradation cannot
      # teach the detector to treat itself as normal.
      _rc_fleet=$(stats_fleet_baseline)

      # Tier 1: passive, from live traffic.
      if [ "$PASSIVE_RTT_ENABLED" = "1" ]; then
        _rc_p=$(passive_rtt 2>/dev/null || echo "0 0")
        _rc_rtt=${_rc_p% *}; _rc_sock=${_rc_p#* }
        if [ "${_rc_sock:-0}" -ge "$PASSIVE_MIN_SOCKETS" ]; then
          stats_record "$_rc_ep" "$_rc_rtt" 0 "$_rc_fleet"
          _rc_got=1
          logd "endpoint=$_rc_ep sample=passive rtt_ms=$_rc_rtt sockets=$_rc_sock"
        fi
      fi

      # Tier 2: in-path probe, only when live traffic was too thin to judge.
      _rc_since_probe=$((_rc_since_probe + SAMPLE_INTERVAL))
      if [ "$_rc_got" -eq 0 ] && [ "$_rc_since_probe" -ge "$PROBE_INTERVAL" ] \
         && [ "$_rc_ntargets" -gt 0 ] && probe_clock_ok; then
        _rc_target_idx=$(( (_rc_target_idx % _rc_ntargets) + 1 ))
        eval "_rc_url=\${$_rc_target_idx}"
        _rc_r=$(probe_ttfb "$_rc_url" 2>/dev/null || echo "0 1")
        _rc_ttfb=${_rc_r% *}; _rc_err=${_rc_r#* }
        stats_record "$_rc_ep" "$_rc_ttfb" "$_rc_err" "$_rc_fleet"
        _rc_since_probe=0
        logd "endpoint=$_rc_ep sample=probe url=$_rc_url ttfb_ms=$_rc_ttfb err=$_rc_err"
      fi

      # Evaluate against the baseline as of AFTER this sample landed. A trip
      # cuts the cycle short so the bad exit stops carrying traffic now,
      # rather than at the end of the interval.
      _rc_fleet=$(stats_fleet_baseline)
      _rc_frozen=0
      stats_ejection_frozen && _rc_frozen=1
      _rc_decision=$(stats_evaluate "$_rc_ep" "$_rc_fleet")

      case "$_rc_decision" in
        TRIP_SLOW|TRIP_ERR)
          if [ "$_rc_frozen" = "1" ]; then
            logw "endpoint=$_rc_ep event=trip_suppressed reason=$_rc_decision cause=ejection_circuit_breaker_open"
          else
            logw "endpoint=$_rc_ep event=trip reason=$_rc_decision ewma_ms=$(stats_field "$_rc_ep" 2) baseline_ms=$(stats_field "$_rc_ep" 4) fleet_ms=${_rc_fleet:-na} err=$(stats_field "$_rc_ep" 5)"
            stats_trip "$_rc_ep" "$(stats_now)"
            ROTATION_REASON="tripped"
            stats_render_metrics "$_rc_ep" "$_rc_fleet" 0 "$_rc_frozen"
            return 1
          fi
          ;;
        RECOVER)
          if [ "$(stats_field "$_rc_ep" 7)" = "HALF_OPEN" ]; then
            logi "endpoint=$_rc_ep event=half_open_recovered ewma_ms=$(stats_field "$_rc_ep" 2) fleet_ms=${_rc_fleet:-na}"
            stats_set_state "$_rc_ep" OK 0
          fi
          ;;
      esac

      stats_render_metrics "$_rc_ep" "$_rc_fleet" "$ALL_DEGRADED" "$_rc_frozen"
    fi

    interruptible_sleep "$VPN_WATCHDOG_INTERVAL"
    _rc_elapsed=$((_rc_elapsed + VPN_WATCHDOG_INTERVAL))
  done

  return 0
}

# ---------------------------------------------------------------------------
# select_endpoint
#
# Pops candidates off the shuffled list until one is selectable. Never
# black-holes: if every candidate is ejected we take the least-bad one,
# force it half-open and flag ALL_DEGRADED.
# Sets CURRENT_OVPN_FILE, ENDPOINT_NAME, CYCLE_SECONDS, ALL_DEGRADED.
# ---------------------------------------------------------------------------
ALL_DEGRADED=0

select_endpoint() {
  stats_expire_cooldowns "$(stats_now)"
  ALL_DEGRADED=0
  _se_skipped=""

  while get_next_ovpn_file; do
    ENDPOINT_NAME=$(basename "$CURRENT_OVPN_FILE")
    stats_ensure "$ENDPOINT_NAME"

    if [ "$ENDPOINT_SCORING_ENABLED" != "1" ] || stats_selectable "$ENDPOINT_NAME"; then
      if [ "$(stats_field "$ENDPOINT_NAME" 7)" = "HALF_OPEN" ]; then
        CYCLE_SECONDS="$HALF_OPEN_INTERVAL"
        logi "endpoint=$ENDPOINT_NAME event=half_open_trial seconds=$CYCLE_SECONDS"
      else
        CYCLE_SECONDS="$ROTATION_INTERVAL_SECONDS"
      fi
      return 0
    fi

    logd "endpoint=$ENDPOINT_NAME event=skipped state=EJECTED until=$(stats_field "$ENDPOINT_NAME" 8)"
    _se_skipped="$_se_skipped $ENDPOINT_NAME"
  done

  # List exhausted. If we skipped anything, everything left is ejected.
  if [ -n "$_se_skipped" ]; then
    # shellcheck disable=SC2086
    _se_best=$(stats_least_bad $_se_skipped)
    if [ -n "$_se_best" ]; then
      ALL_DEGRADED=1
      CURRENT_OVPN_FILE="$OVPN_CONFIG_DIR/$_se_best"
      ENDPOINT_NAME="$_se_best"
      CYCLE_SECONDS="$HALF_OPEN_INTERVAL"
      stats_set_state "$_se_best" HALF_OPEN 0
      logw "event=all_endpoints_degraded action=forcing_least_bad endpoint=$_se_best ewma_ms=$(stats_field "$_se_best" 2)"
      return 0
    fi
  fi
  return 1
}

# --- ENDPOINT STATS STORE ---
stats_init
set_state starting ""
probe_clock_ok || logw "event=no_nanosecond_clock impact=in_path_ttfb_probe_disabled fix=install_coreutils"

# --- HEALTH / READY HTTP (separate from Privoxy proxy port) ---
if [ "${HEALTH_HTTP_ENABLED:-1}" != "0" ]; then
  HEALTH_PORT="${HEALTH_PORT:-8081}"
  HEALTH_LISTEN_ADDR="${HEALTH_LISTEN_ADDR:-0.0.0.0}"
  echo "Starting health HTTP listener on ${HEALTH_LISTEN_ADDR}:${HEALTH_PORT} (GET /health, GET /ready)..."
  /app/health_httpd.sh &
  health_socat_pid=$!
fi

# --- INITIAL LOAD OF OVPN FILES ---
logd "main: before initial call to load_and_shuffle_ovpn_files"
if ! load_and_shuffle_ovpn_files; then
  echo "FATAL: Could not load any OVPN files on initial startup."
  exit 1
fi
logd "main: initial load complete"

# --- MAIN ROTATION LOOP ---
while true; do
  [ "$_shutdown" = "1" ] && break
  logd "main loop: top of while"

  # select_endpoint pops candidates and skips ejected ones. It returns
  # non-zero only when the shuffled list is exhausted.
  if ! select_endpoint; then
    logd "main loop: candidate list exhausted, reshuffling"
    if ! load_and_shuffle_ovpn_files; then
      loge "event=reload_failed action=retry_in_60s"
      interruptible_sleep 60
      continue
    fi
    if ! select_endpoint; then
      echo "FATAL: No OVPN files available even after attempting reload. Exiting."
      exit 1
    fi
  fi

  PVPN_OVPN_FILE_PATH="$CURRENT_OVPN_FILE"
  logd "main loop: processing file [$PVPN_OVPN_FILE_PATH]"

  echo ""
  echo "----------------------------------------------------"
  logi "event=cycle_start endpoint=$ENDPOINT_NAME state=$(stats_field "$ENDPOINT_NAME" 7) seconds=$CYCLE_SECONDS all_degraded=$ALL_DEGRADED"
  echo "Full config path: $PVPN_OVPN_FILE_PATH"
  echo "----------------------------------------------------"

  # Remove rather than touch: detect_vpn_interface greps this log, and the
  # window between --daemon forking and OpenVPN truncating the file let the
  # PREVIOUS cycle's "TUN/TAP device" line be read as if it were this one.
  rm -f "$OPENVPN_LOG"
  touch "$OPENVPN_LOG"; chmod 600 "$OPENVPN_LOG"
  echo "Launching OpenVPN client in background..."
  # --ping/--ping-restart: the ProtonVPN .ovpn files ship no keepalive, so a
  # silently dead UDP tunnel was invisible to OpenVPN itself (persist-tun keeps
  # the interface and its IP up). Without these, a black-holed tunnel survived
  # until the rotation interval elapsed.
  openvpn \
    --config "$PVPN_OVPN_FILE_PATH" \
    --auth-user-pass "$AUTH_FILE_PATH" \
    --auth-nocache \
    --ping "${VPN_PING_INTERVAL:-10}" \
    --ping-restart "${VPN_PING_RESTART:-60}" \
    --pull-filter ignore "route-ipv6" \
    --pull-filter ignore "ifconfig-ipv6" \
    --redirect-gateway def1 bypass-dhcp \
    --log "$OPENVPN_LOG" \
    --script-security 2 \
    --up /etc/openvpn/update-resolv-conf \
    --down /etc/openvpn/update-resolv-conf \
    --daemon

  VPN_INTERFACE="tun0"
  TIMEOUT="$VPN_CONNECT_TIMEOUT"
  echo "Waiting up to $TIMEOUT seconds for VPN interface $VPN_INTERFACE to appear and get an IP..."
  counter=0
  vpn_ip_assigned=0
  while [ $counter -lt $TIMEOUT ]; do
    detected_iface=$(detect_vpn_interface)
    if [ -n "$detected_iface" ] && [ "$detected_iface" != "$VPN_INTERFACE" ]; then
      VPN_INTERFACE="$detected_iface"
      echo ""
      echo "Detected VPN interface from logs/system: $VPN_INTERFACE"
    fi
    if ip link show "$VPN_INTERFACE" > /dev/null 2>&1 && ip addr show "$VPN_INTERFACE" | grep -q "inet "; then
      echo ""
      echo "VPN interface $VPN_INTERFACE is UP and has an IP address."
      ip addr show "$VPN_INTERFACE"
      vpn_ip_assigned=1
      break
    fi
    echo -n "."
    sleep 1
    counter=$((counter + 1))
  done

  if [ "$vpn_ip_assigned" -eq 0 ]; then
    echo ""
    echo "Error: Timed out waiting for VPN interface $VPN_INTERFACE to initialize properly (get an IP)."
    echo "--- Last 20 lines of OpenVPN Log ($OPENVPN_LOG) ---"
    tail -n 20 "$OPENVPN_LOG" || echo "Log file $OPENVPN_LOG not found or unreadable."
    echo "----------------------------------------------------"
    if pgrep -x openvpn > /dev/null; then
      echo "OpenVPN process IS running, but interface check failed. Killing OpenVPN..."
      pkill -KILL openvpn
    else
      echo "OpenVPN process is NOT running!"
    fi
    echo "Skipping Privoxy start for this failed VPN. Trying next VPN server after a short delay..."
    # A connect failure is a failure sample for this endpoint: repeated
    # failures push err above ERR_TRIP_RATE and eject it from the rotation.
    stats_record "$ENDPOINT_NAME" 0 1
    logw "endpoint=$ENDPOINT_NAME event=connect_failed err=$(stats_field "$ENDPOINT_NAME" 5)"
    _cf_fleet=$(stats_fleet_baseline)
    case "$(stats_evaluate "$ENDPOINT_NAME" "$_cf_fleet")" in
      TRIP_ERR|TRIP_SLOW)
        if stats_ejection_frozen; then
          logw "endpoint=$ENDPOINT_NAME event=trip_suppressed cause=ejection_circuit_breaker_open"
        else
          logw "endpoint=$ENDPOINT_NAME event=trip reason=connect_failures"
          stats_trip "$ENDPOINT_NAME" "$(stats_now)"
        fi
        ;;
    esac
    set_state notready "$ENDPOINT_NAME"
    interruptible_sleep 5
  else
    if ! openvpn_running; then
        echo "Error: OpenVPN process is not running after successful interface check (unexpected). Skipping Privoxy."
        stats_record "$ENDPOINT_NAME" 0 1
        set_state notready "$ENDPOINT_NAME"
        interruptible_sleep 5
    else
      echo "OpenVPN process is running and interface is up."
      echo "Current /etc/resolv.conf (expected to be set by update-resolv-conf via VPN):"
      cat /etc/resolv.conf || echo "/etc/resolv.conf not found or unreadable"

      if [ -n "$DNS_SERVERS_OVERRIDE" ]; then
          echo "DNS_SERVERS_OVERRIDE is set ('$DNS_SERVERS_OVERRIDE'). Overriding /etc/resolv.conf..."
          _tmp_resolv="/tmp/resolv.conf.new.$$"
          echo "# Overridden by DNS_SERVERS_OVERRIDE in proton-privoxy entrypoint" > "$_tmp_resolv"
          echo "$DNS_SERVERS_OVERRIDE" | tr ',' '\n' | while IFS= read -r server; do
              server_trimmed=$(echo "$server" | awk '{$1=$1};1')
              if [ -n "$server_trimmed" ]; then
                  echo "nameserver $server_trimmed" >> "$_tmp_resolv"
              fi
          done
          if grep -q "nameserver" "$_tmp_resolv"; then
            cat "$_tmp_resolv" > /etc/resolv.conf
            echo "Updated /etc/resolv.conf with DNS_SERVERS_OVERRIDE. New contents:"
            cat /etc/resolv.conf
          else
            echo "Warning: DNS_SERVERS_OVERRIDE ('$DNS_SERVERS_OVERRIDE') was set but resulted in no valid nameserver entries."
          fi
          rm -f "$_tmp_resolv"
      fi

      echo "Starting Privoxy..."
      PRIVPROXY_LOGDIR="/var/log/privoxy"
      mkdir -p "$PRIVPROXY_LOGDIR"
      chown privoxy:privoxy "$PRIVPROXY_LOGDIR" 2>/dev/null || chown root:root "$PRIVPROXY_LOGDIR"
      privoxy --no-daemon "$PRIVOXY_CONFIG" &
      privoxy_pid=$!
      logi "event=privoxy_started pid=$privoxy_pid endpoint=$ENDPOINT_NAME"

      # Confirm Privoxy is actually listening before declaring readiness;
      # `&` only proves fork() succeeded, not that bind() did.
      _pw=0
      while [ "$_pw" -lt 10 ]; do
        ss -Hltn "sport = :${PROXY_PORT}" 2>/dev/null | grep -q . && break
        kill -0 "$privoxy_pid" 2>/dev/null || break
        sleep 1; _pw=$((_pw + 1))
      done
      if ! kill -0 "$privoxy_pid" 2>/dev/null; then
        loge "endpoint=$ENDPOINT_NAME event=privoxy_died_at_startup"
        stats_record "$ENDPOINT_NAME" 0 1
        privoxy_pid=""
        set_state notready "$ENDPOINT_NAME"
      else
        set_state ready "$ENDPOINT_NAME"
        echo "Attempting to get current external IP..."
        current_ip=$(wget -T 10 -qO- http://ipv4.icanhazip.com || wget -T 10 -qO- http://ifconfig.me/ip || echo "N/A")
        logi "event=exit_ip endpoint=$ENDPOINT_NAME ip=$current_ip"

        # Supervised cycle. Replaces the blocking `sleep $ROTATION_INTERVAL`,
        # which (a) made the container unresponsive to SIGTERM, (b) let a dead
        # tunnel keep serving for up to the full interval, and (c) collected
        # no evidence about how this endpoint was performing.
        if run_cycle "$ENDPOINT_NAME" "$CYCLE_SECONDS"; then
          stats_mark_clean_cycle "$ENDPOINT_NAME"
          ROTATION_REASON="scheduled"
        fi
        logi "event=cycle_end endpoint=$ENDPOINT_NAME reason=$ROTATION_REASON"

        # Half-open trial that neither tripped nor demonstrably recovered stays
        # half-open; it gets another short trial rather than full traffic.
        if [ "$(stats_field "$ENDPOINT_NAME" 7)" = "HALF_OPEN" ] && [ "$ROTATION_REASON" = "scheduled" ]; then
          _ho_fleet=$(stats_fleet_baseline)
          if [ "$(stats_evaluate "$ENDPOINT_NAME" "$_ho_fleet")" = "RECOVER" ]; then
            logi "endpoint=$ENDPOINT_NAME event=half_open_recovered"
            stats_set_state "$ENDPOINT_NAME" OK 0
          else
            logi "endpoint=$ENDPOINT_NAME event=half_open_inconclusive action=remain_half_open"
          fi
        fi
      fi

      set_state draining "$ENDPOINT_NAME"
      drain_privoxy
    fi
  fi

  # Tunnel teardown happens only AFTER the proxy has drained, so no request is
  # cut off by the routes disappearing underneath it.
  set_state notready "$ENDPOINT_NAME"
  if openvpn_running; then
    logi "event=openvpn_stop endpoint=$ENDPOINT_NAME"
    pkill -TERM openvpn
    _wait_count=0
    while openvpn_running && [ $_wait_count -lt 10 ]; do
      sleep 0.5
      _wait_count=$((_wait_count + 1))
    done
    if openvpn_running; then
      logw "event=openvpn_sigkill endpoint=$ENDPOINT_NAME reason=sigterm_timeout"
      pkill -KILL openvpn
    fi
  fi
  # Reap the daemonised OpenVPN that PID 1 inherited, so `pgrep -x openvpn`
  # on the next cycle cannot match a zombie. See also `init: true` in
  # docker-compose.yml, which handles this properly.
  wait 2>/dev/null || true
  # No 'shift' needed as we are managing OVPN_FILE_LIST and CURRENT_OVPN_FILE
done

logi "event=supervisor_exit reason=shutdown"

