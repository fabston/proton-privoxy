#!/bin/sh
############################################################################
#                        Latency samplers (two tiers)                       #
############################################################################
#
#   probe_ttfb.sh rtt          -> "<median_rtt_ms> <socket_count>"  (passive)
#   probe_ttfb.sh ttfb <url>   -> "<ttfb_ms> <err>"                 (in-path)
#
# TIER 1 (passive, preferred): `rtt` reads the kernel's own smoothed RTT for
# the TCP sockets that REAL proxied traffic is already using. Zero added
# packets. This is transport RTT to the origin over the tunnel — it captures
# exactly what we want to grade (the exit path) and deliberately excludes
# origin-side think time, which is not the exit's fault.
#
# TIER 2 (in-path probe, fallback): `ttfb` issues a real proxied GET through
# the LOCAL Privoxy listener and times the first response byte. It runs only
# when tier 1 produced too few samples (a cycle with little client traffic),
# so the system never depends on synthetic checks alone. It probes the actual
# data path (client -> Privoxy -> tunnel -> origin), not a side channel.
#
# We grade on TTFB, not total transfer time: total is dominated by payload
# size and origin bandwidth, whereas TTFB is dominated by the path itself
# (tunnel RTT + connect + origin first byte). TTFB is the signal that moves
# when an exit congests.

PROBE_PROXY_HOST="${PROBE_PROXY_HOST:-127.0.0.1}"
PROBE_PROXY_PORT="${PROBE_PROXY_PORT:-8100}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-8}"
PROBE_UA="${PROBE_UA:-proton-privoxy-probe/1}"

# --- nanosecond clock support (coreutils date; BusyBox date lacks %N) ---
probe_clock_ok() {
  _pc=$(date +%N 2>/dev/null)
  case "$_pc" in
    ''|*[!0-9]*) return 1 ;;
    *)           return 0 ;;
  esac
}

# ---------------------------------------------------------------------------
# passive_rtt — median kernel RTT (ms) across established non-loopback sockets
#
# `ss -tin` emits an address line followed by an indented info line carrying
# rtt:<srtt>/<mdev>. We pair them so loopback sockets (the probe itself, the
# health listener) can be excluded. Local/peer are taken as the last two
# fields so this survives the State column being present or absent.
#
# Fails OPEN: on any parse surprise it emits no samples rather than bogus
# ones, and the caller falls back to the tier-2 probe.
# ---------------------------------------------------------------------------
passive_rtt() {
  ss -tin state established 2>/dev/null | awk -v hp="${HEALTH_PORT:-8081}" -v pp="$PROBE_PROXY_PORT" '
    # Address lines start at column 0; info lines are indented.
    /^[^ \t]/ {
      keep = 0
      if (NF >= 2) {
        local = $(NF - 1); peer = $NF
        if (local !~ /^127\./ && peer !~ /^127\./ &&
            local !~ /^\[?::1\]?:/ && peer !~ /^\[?::1\]?:/ &&
            local !~ (":" hp "$") && local !~ (":" pp "$"))
          keep = 1
      }
      next
    }
    keep && match($0, /rtt:[0-9]+\.?[0-9]*/) {
      print substr($0, RSTART + 4, RLENGTH - 4)
    }
  ' | sort -n | awk '
    { v[NR] = $1 }
    END {
      if (NR == 0) { print "0 0"; exit }
      if (NR % 2) m = v[int((NR + 1) / 2)]
      else        m = (v[NR / 2] + v[NR / 2 + 1]) / 2
      printf "%.3f %d\n", m, NR
    }'
}

# ---------------------------------------------------------------------------
# probe_ttfb <absolute-http-url>
#
# Timestamps measured:
#   t0 - immediately before connect() to the local Privoxy listener
#   t1 - immediately after the FIRST response byte is readable
# TTFB = t1 - t0. It therefore includes Privoxy's own accept+parse and the
# loopback hop; both are sub-millisecond and, more importantly, CONSTANT
# across endpoints, so they cancel in the relative comparison we actually use.
#
# `head -c 1` returns as soon as one byte lands and closes the pipe, which
# tears socat down — that is what makes this first-byte and not total time.
#
# Plain HTTP by design: a CONNECT+TLS probe would fold handshake variance and
# origin TLS config into a number meant to grade the exit path.
# ---------------------------------------------------------------------------
probe_ttfb() {
  _pt_url="$1"
  _pt_rest="${_pt_url#http://}"
  case "$_pt_rest" in
    */*) _pt_host="${_pt_rest%%/*}" ;;
    *)   _pt_host="$_pt_rest" ;;
  esac

  _pt_t0=$(date +%s%N 2>/dev/null) || { echo "0 1"; return 0; }

  _pt_n=$(
    printf 'GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: %s\r\nAccept: */*\r\nConnection: close\r\n\r\n' \
      "$_pt_url" "$_pt_host" "$PROBE_UA" \
    | socat -T "$PROBE_TIMEOUT" - \
        "TCP:${PROBE_PROXY_HOST}:${PROBE_PROXY_PORT},connect-timeout=${PROBE_TIMEOUT}" 2>/dev/null \
    | head -c 1 | wc -c | tr -d ' '
  )

  _pt_t1=$(date +%s%N 2>/dev/null)

  if [ "${_pt_n:-0}" -lt 1 ]; then
    echo "0 1"          # no first byte within the timeout => failure sample
    return 0
  fi

  awk -v a="$_pt_t0" -v b="$_pt_t1" 'BEGIN { printf "%.3f 0\n", (b - a) / 1000000 }'
}

# --- CLI dispatch, skipped when sourced as a library by rotate_vpn.sh ---
case "$0" in
  *probe_ttfb.sh)
    case "${1:-}" in
      rtt)  passive_rtt ;;
      ttfb) [ -n "${2:-}" ] || { echo "0 1"; exit 0; }; probe_ttfb "$2" ;;
      *)    echo "usage: $0 {rtt|ttfb <absolute-http-url>}" >&2; exit 2 ;;
    esac
    ;;
esac
