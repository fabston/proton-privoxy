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
#   t0 - immediately before the request is issued
#   t1 - immediately after the response completes
#
# This is total request time, NOT strictly time-to-first-byte. That is a
# deliberate retreat. The original implementation drove socat by hand to catch
# the first response byte, and it failed 100% of the time in this container for
# reasons two rounds of fixes did not settle — every probe returned a failure
# sample, which quietly inflated the error EWMA of perfectly healthy endpoints.
# wget is the tool that demonstrably works here: it is what produces the
# event=exit_ip line on every cycle.
#
# The accuracy cost is near zero for the intended targets. TTFB was chosen over
# total time to stop payload size and origin bandwidth from dominating the
# signal; with a ~15-byte response body those terms are microseconds. Keep
# PROBE_TARGETS small and plain-HTTP and the two measures are equivalent.
#
# Plain HTTP by design: a CONNECT+TLS probe would fold handshake variance and
# origin TLS config into a number meant to grade the exit path.
# ---------------------------------------------------------------------------
probe_ttfb() {
  _pt_url="$1"

  probe_clock_ok || { echo "0 1"; return 0; }
  _pt_t0=$(date +%s%N 2>/dev/null)

  # -t 1: one attempt. Without it a failure costs tries x timeout and the
  #       sample is charged the whole thing.
  # -O /dev/null: we time the request, we do not want the body.
  if http_proxy="http://${PROBE_PROXY_HOST}:${PROBE_PROXY_PORT}" \
     wget -q -t 1 -T "$PROBE_TIMEOUT" -O /dev/null \
          --user-agent="$PROBE_UA" "$_pt_url" 2>/dev/null
  then
    _pt_t1=$(date +%s%N 2>/dev/null)
    awk -v a="$_pt_t0" -v b="$_pt_t1" 'BEGIN { printf "%.3f 0\n", (b - a) / 1000000 }'
  else
    echo "0 1"
  fi
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
