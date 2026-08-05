#!/bin/sh
############################################################################
#  Endpoint (ProtonVPN exit) latency statistics + degradation state machine #
############################################################################
#
# Sourced by rotate_vpn.sh. POSIX sh only; all floating-point math goes
# through awk because sh has integer arithmetic only.
#
# An "endpoint" here is one .ovpn file = one ProtonVPN exit server. Only one
# is active at a time (see rotate_vpn.sh main loop), so every sample taken
# during a cycle is attributed to the endpoint that cycle is running.
#
# Record schema, one space-separated line per endpoint in $STATS_FILE:
#   1  name        basename of the .ovpn file
#   2  ewma        fast EWMA of TTFB in ms   (alpha=EWMA_ALPHA)    "right now"
#   3  bvar        slow EW variance of TTFB around `base`          "its spread"
#   4  base        slow EWMA of TTFB in ms   (alpha=BASELINE_ALPHA) "its normal"
#   5  err         EWMA of the failure indicator, 0..1
#   6  n           total samples recorded (successes + failures)
#   7  state       OK | EJECTED | HALF_OPEN
#   8  until       epoch seconds; cooldown deadline while EJECTED
#   9  trips       consecutive trips, drives exponential backoff
#  10  ok_cycles   clean cycles since the last trip, decays `trips`
#
# Only ONE process writes this file (the rotation supervisor). Readers get
# consistency because every write is a write-temp-then-mv.

# --- TUNABLES (see .env.example.txt for the documented surface) ---
STATS_DIR="${STATS_DIR:-/var/lib/proxy}"
STATS_FILE="${STATS_FILE:-$STATS_DIR/endpoint_stats}"
METRICS_FILE="${METRICS_FILE:-$STATS_DIR/metrics.prom}"

EWMA_ALPHA="${EWMA_ALPHA:-0.2}"
# 0.005 (~400 samples = ~6.6h at SAMPLE_INTERVAL=60). Paired with the 86400
# ROTATION_INTERVAL default: a baseline shorter than the diurnal cycle makes a
# genuine evening traffic peak read as degradation, which is the most likely
# source of false ejections. Raise toward 0.02 only if you also shorten the
# rotation interval — these two must move together.
BASELINE_ALPHA="${BASELINE_ALPHA:-0.005}"
# ERR_ALPHA vs ERR_TRIP_RATE are coupled: with alpha=0.3 a SINGLE failure puts
# the EWMA at 0.30, which already exceeded a 0.25 threshold — one transient
# error ejected an endpoint for 15 minutes. At alpha=0.10 it takes three
# consecutive failures (0.10, 0.19, 0.271) to cross 0.20, while a sustained
# 25% failure rate still converges above it.
ERR_ALPHA="${ERR_ALPHA:-0.1}"

MIN_SAMPLES="${MIN_SAMPLES:-20}"
HALF_OPEN_MIN_SAMPLES="${HALF_OPEN_MIN_SAMPLES:-8}"

SLOW_TRIP_RATIO="${SLOW_TRIP_RATIO:-2.5}"
SLOW_RECOVER_RATIO="${SLOW_RECOVER_RATIO:-1.5}"
SLOW_SIGMA="${SLOW_SIGMA:-3.0}"
SIGMA_FLOOR_FRAC="${SIGMA_FLOOR_FRAC:-0.15}"
SIGMA_CEIL_FRAC="${SIGMA_CEIL_FRAC:-0.5}"
SLOW_FLOOR_MS="${SLOW_FLOOR_MS:-150}"

ERR_TRIP_RATE="${ERR_TRIP_RATE:-0.20}"
ERR_RECOVER_RATE="${ERR_RECOVER_RATE:-0.05}"

EJECT_COOLDOWN="${EJECT_COOLDOWN:-900}"
EJECT_COOLDOWN_MAX="${EJECT_COOLDOWN_MAX:-14400}"
TRIP_DECAY_CYCLES="${TRIP_DECAY_CYCLES:-3}"
MAX_EJECT_FRACTION="${MAX_EJECT_FRACTION:-0.5}"

# --- INTERNAL ---
_ejection_frozen=0

stats_init() {
  mkdir -p "$STATS_DIR" 2>/dev/null || true
  [ -f "$STATS_FILE" ] || : > "$STATS_FILE"
}

# stats_now — epoch seconds
stats_now() { date +%s; }

# _stats_write <tmpfile> — atomically replace the stats file
_stats_write() {
  mv -f "$1" "$STATS_FILE"
}

# stats_field <name> <field-index> — echo one field, empty if no record
stats_field() {
  awk -v n="$1" -v f="$2" '$1 == n { print $f; found=1; exit } END { if (!found) print "" }' "$STATS_FILE"
}

# stats_seen <name> — 0 if the endpoint has a record
stats_seen() {
  awk -v n="$1" '$1 == n { found=1; exit } END { exit !found }' "$STATS_FILE"
}

# stats_ensure <name> — create an unjudged record if absent
stats_ensure() {
  stats_seen "$1" && return 0
  printf '%s 0 0 0 0 0 OK 0 0 0\n' "$1" >> "$STATS_FILE"
}

# ---------------------------------------------------------------------------
# stats_record <name> <ttfb_ms> <err> [fleet_baseline_ms]
#
# `err` is 1 for a failed/timed-out sample, 0 for a success.
#
# A failed sample deliberately does NOT feed the latency EWMAs: a timeout
# would pin `ewma` at PROBE_TIMEOUT and destroy resolution for the ratio test.
# Failures are carried entirely by the `err` EWMA, which trips on its own and
# trips faster. Both signals still increment `n`.
#
# `fleet_baseline_ms` (optional) enables BASELINE FREEZING. While a sample is
# already above the trip ratio relative to the fleet, `base` and `bvar` are
# left untouched and only the fast `ewma` moves. Without this the baseline
# chases the degradation and a sustained slowdown becomes the new "normal" —
# measured behaviour was that an endpoint stuck at 2.6x fleet tripped only
# between roughly the 15th and 20th degraded sample and then went quiet.
# Freezing makes a sustained degradation trip and STAY tripped, while a
# genuinely relocated endpoint still re-baselines once it is back under the
# ratio. Omit the argument during bootstrap (no fleet median yet).
# ---------------------------------------------------------------------------
stats_record() {
  _sr_name="$1"; _sr_ttfb="$2"; _sr_err="$3"; _sr_fleet="${4:-0}"
  _sr_tmp="${STATS_FILE}.tmp.$$"

  awk -v name="$_sr_name" -v ttfb="$_sr_ttfb" -v err="$_sr_err" \
      -v fleet="${_sr_fleet:-0}" -v trip="$SLOW_TRIP_RATIO" \
      -v a="$EWMA_ALPHA" -v ba="$BASELINE_ALPHA" -v ea="$ERR_ALPHA" \
      -v sg="$SLOW_SIGMA" -v sf="$SIGMA_FLOOR_FRAC" -v sc="$SIGMA_CEIL_FRAC" \
      -v minsamp="$MIN_SAMPLES" '
    $1 == name {
      ewma = $2 + 0; bvar = $3 + 0; base = $4 + 0; erate = $5 + 0; n = $6 + 0

      if (err + 0 == 0) {
        if (n == 0 || base <= 0) {          # first successful sample seeds both
          ewma = ttfb; base = ttfb; bvar = 0
        } else if (n < minsamp) {
          # WARM-UP: plain incremental mean and variance until there is enough
          # history to trust. Seeding the baseline from a single observation
          # and then winsorizing made a bad first sample self-protecting — the
          # wide initial spread clipped every later correction, so a 5000ms
          # cold-start reading left the baseline near 2500 even after forty
          # healthy 120ms samples. Averaging first makes the seed forgettable.
          ewma = a * ttfb + (1 - a) * ewma
          base = base + (ttfb - base) / (n + 1)
          d    = ttfb - base
          bvar = bvar + (d * d - bvar) / (n + 1)
        } else {
          # Fast EWMA tracks the raw sample: it must be free to shoot up.
          ewma = a * ttfb + (1 - a) * ewma

          # Freeze the model while the sample is already anomalous vs the
          # fleet, so a degradation cannot teach the detector to accept it.
          #
          # Only once there is enough history to freeze: otherwise a single bad
          # first observation (cold start, one-off packet loss) would be frozen
          # in as the baseline forever and make the endpoint permanently
          # untrippable. Below minsamp we always learn, and MIN_SAMPLES of
          # winsorized averaging is what makes that first baseline trustworthy.
          frozen = (fleet > 0 && ttfb > trip * fleet && n >= minsamp)

          if (!frozen) {
            # Baseline and variance describe the NORMAL regime of this
            # endpoint, so outliers are winsorized first. Without this the
            # variance inflates quadratically during a degradation and the
            # "3 sigma above its own baseline" test can never fire — the
            # anomaly silently widens the band meant to catch it.
            sd = (bvar > 0) ? sqrt(bvar) : 0
            if (sd < sf * base) sd = sf * base
            if (sc > 0 && sd > sc * base) sd = sc * base   # break the sd -> lim -> sd feedback loop
            lim = sg * sd
            x = ttfb
            if (x > base + lim) x = base + lim
            else if (x < base - lim) x = base - lim

            base = ba * x + (1 - ba) * base
            d    = x - base
            bvar = ba * d * d + (1 - ba) * bvar
          }
        }
      }
      erate = ea * (err + 0) + (1 - ea) * erate

      printf "%s %.3f %.3f %.3f %.5f %d %s %d %d %d\n", \
             $1, ewma, bvar, base, erate, n + 1, $7, $8, $9, $10
      found = 1; next
    }
    { print }
    END {
      if (!found) {
        if (err + 0 == 0)
          printf "%s %.3f %.3f %.3f %.5f %d %s %d %d %d\n", name, ttfb, 0, ttfb, 0, 1, "OK", 0, 0, 0
        else
          printf "%s %.3f %.3f %.3f %.5f %d %s %d %d %d\n", name, 0, 0, 0, 1, 1, "OK", 0, 0, 0
      }
    }
  ' "$STATS_FILE" > "$_sr_tmp" && _stats_write "$_sr_tmp"
}

# ---------------------------------------------------------------------------
# stats_fleet_baseline
#
# Median of the per-endpoint fast EWMA across endpoints that have enough
# samples and are not currently ejected.
#
# Median, not mean: one catastrophically slow exit must not drag the baseline
# up far enough to hide itself.
#
# Excluding EJECTED endpoints biases the baseline down, which makes further
# ejections marginally easier. That is deliberate — but it is also exactly how
# an ejection storm starts, so stats_ejection_frozen() below is the brake.
# ---------------------------------------------------------------------------
stats_fleet_baseline() {
  awk -v min="$MIN_SAMPLES" \
      '$6 + 0 >= min && $2 + 0 > 0 && ($7 == "OK" || $7 == "HALF_OPEN") { print $2 }' "$STATS_FILE" \
    | sort -n \
    | awk '{ v[NR] = $1 }
           END {
             if (NR == 0) { print ""; exit }
             if (NR % 2) printf "%.3f\n", v[int((NR + 1) / 2)]
             else        printf "%.3f\n", (v[NR / 2] + v[NR / 2 + 1]) / 2
           }'
}

# stats_count <state|any> — number of records in that state
stats_count() {
  awk -v s="$1" '$1 != "" { if (s == "any" || $7 == s) c++ } END { print c + 0 }' "$STATS_FILE"
}

# ---------------------------------------------------------------------------
# stats_ejection_frozen
#
# Circuit breaker. If more than MAX_EJECT_FRACTION of the fleet is ejected,
# the likeliest explanation is a problem on THIS host (uplink, DNS, ProtonVPN
# account-wide) rather than half of ProtonVPN's fleet failing at once.
# Returns 0 (frozen) when new ejections should be suppressed.
# ---------------------------------------------------------------------------
stats_ejection_frozen() {
  _ef_total=$(stats_count any)
  [ "$_ef_total" -eq 0 ] && return 1
  _ef_ej=$(stats_count EJECTED)
  awk -v e="$_ef_ej" -v t="$_ef_total" -v f="$MAX_EJECT_FRACTION" \
      'BEGIN { exit !(t > 0 && e / t > f) }'
}

# ---------------------------------------------------------------------------
# stats_evaluate <name> <fleet_baseline>
#
# Prints one decision token: TRIP_SLOW | TRIP_ERR | RECOVER | HOLD | UNJUDGED
# Pure function — does not mutate state.
#
# Trip on latency requires ALL of:
#   n >= min samples          — do not eject on two unlucky probes
#   ewma > SLOW_FLOOR_MS      — ratios are meaningless at small absolute values
#   ewma > RATIO * fleet      — bad relative to the alternatives
#   ewma > base + SIGMA*sd    — bad relative to ITSELF
#
# The last clause is what stops geography being mistaken for degradation: a
# consistently-distant 400ms exit has ewma ~= base, so it never trips, while
# that same exit going to 1200ms does (base moves 10x slower than ewma).
# ---------------------------------------------------------------------------
stats_evaluate() {
  _se_name="$1"; _se_fleet="$2"
  # An empty fleet baseline (cold start, or a long ROTATION_INTERVAL where it
  # takes N days to observe N endpoints) suppresses only the RELATIVE latency
  # test. The error-rate test needs no fleet comparison to be meaningful, so it
  # must still run — otherwise a brand-new deployment cannot eject an endpoint
  # that is failing every single request.
  [ -z "$_se_fleet" ] && _se_fleet=0

  awk -v name="$_se_name" -v fleet="$_se_fleet" \
      -v minok="$MIN_SAMPLES" -v minho="$HALF_OPEN_MIN_SAMPLES" \
      -v trip="$SLOW_TRIP_RATIO" -v rec="$SLOW_RECOVER_RATIO" \
      -v sig="$SLOW_SIGMA" -v sigfloor="$SIGMA_FLOOR_FRAC" -v sigceil="$SIGMA_CEIL_FRAC" \
      -v floorms="$SLOW_FLOOR_MS" \
      -v etrip="$ERR_TRIP_RATE" -v erec="$ERR_RECOVER_RATE" '
    $1 == name {
      ewma = $2 + 0; bvar = $3 + 0; base = $4 + 0; erate = $5 + 0; n = $6 + 0; st = $7
      need = (st == "HALF_OPEN") ? minho : minok
      if (n < need) { print "UNJUDGED"; found = 1; exit }

      # Never trust a spread tighter than SIGMA_FLOOR_FRAC of the baseline;
      # a perfectly stable endpoint would otherwise trip on any blip. And
      # never wider than SIGMA_CEIL_FRAC, or a noisy endpoint becomes
      # untrippable no matter how far it drifts.
      sd = (bvar > 0) ? sqrt(bvar) : 0
      if (sd < sigfloor * base) sd = sigfloor * base
      if (sigceil > 0 && sd > sigceil * base) sd = sigceil * base

      if (erate > etrip)                     { print "TRIP_ERR";  found = 1; exit }

      # Without a fleet baseline there is nothing to be slow RELATIVE TO, so
      # the latency tests are skipped rather than guessed at. Error state above
      # has already been decided.
      if (fleet <= 0)                        { print "UNJUDGED";  found = 1; exit }

      if (ewma > floorms && ewma > trip * fleet && ewma > base + sig * sd) \
                                             { print "TRIP_SLOW"; found = 1; exit }
      if (ewma > 0 && ewma <= rec * fleet && erate <= erec) \
                                             { print "RECOVER";   found = 1; exit }
      print "HOLD"; found = 1; exit
    }
    END { if (!found) print "UNJUDGED" }
  ' "$STATS_FILE"
}

# ---------------------------------------------------------------------------
# stats_trip <name> <now>
#
# Move an endpoint to EJECTED with exponential backoff on the cooldown.
# A genuinely broken exit is retried once every few hours, not every 15
# minutes — that exponential term is the real anti-flap mechanism.
# ---------------------------------------------------------------------------
stats_trip() {
  _st_name="$1"; _st_now="$2"
  _st_tmp="${STATS_FILE}.tmp.$$"
  awk -v name="$_st_name" -v now="$_st_now" \
      -v cd="$EJECT_COOLDOWN" -v cdmax="$EJECT_COOLDOWN_MAX" '
    $1 == name {
      trips = $9 + 1
      mult = 1
      for (i = 1; i < trips; i++) { mult = mult * 2; if (mult * cd > cdmax) break }
      wait = cd * mult
      if (wait > cdmax) wait = cdmax
      printf "%s %s %s %s %s %s %s %d %d %d\n", \
             $1, $2, $3, $4, $5, $6, "EJECTED", now + wait, trips, 0
      next
    }
    { print }
  ' "$STATS_FILE" > "$_st_tmp" && _stats_write "$_st_tmp"
}

# stats_set_state <name> <state> [until] — direct transition
stats_set_state() {
  _ss_tmp="${STATS_FILE}.tmp.$$"
  awk -v name="$1" -v st="$2" -v until="${3:-0}" '
    $1 == name { printf "%s %s %s %s %s %s %s %d %d %d\n", $1, $2, $3, $4, $5, $6, st, until, $9, $10; next }
    { print }
  ' "$STATS_FILE" > "$_ss_tmp" && _stats_write "$_ss_tmp"
}

# ---------------------------------------------------------------------------
# stats_mark_clean_cycle <name>
#
# Called when an endpoint completes a cycle without tripping. After
# TRIP_DECAY_CYCLES clean cycles the backoff exponent resets, so one bad
# afternoon does not penalise a server for the rest of the week.
# ---------------------------------------------------------------------------
stats_mark_clean_cycle() {
  _mc_tmp="${STATS_FILE}.tmp.$$"
  awk -v name="$1" -v decay="$TRIP_DECAY_CYCLES" '
    $1 == name {
      ok = $10 + 1; trips = $9
      if (ok >= decay) { trips = 0; ok = 0 }
      printf "%s %s %s %s %s %s %s %s %d %d\n", $1, $2, $3, $4, $5, $6, $7, $8, trips, ok
      next
    }
    { print }
  ' "$STATS_FILE" > "$_mc_tmp" && _stats_write "$_mc_tmp"
}

# ---------------------------------------------------------------------------
# stats_expire_cooldowns <now>
#
# EJECTED endpoints past their cooldown become HALF_OPEN: eligible for
# selection again, but they will be given a short trial cycle rather than a
# full one (see HALF_OPEN_INTERVAL in rotate_vpn.sh).
# ---------------------------------------------------------------------------
stats_expire_cooldowns() {
  _ec_tmp="${STATS_FILE}.tmp.$$"
  awk -v now="$1" '
    $7 == "EJECTED" && $8 + 0 <= now {
      printf "%s %s %s %s %s %s %s %d %s %s\n", $1, $2, $3, $4, $5, $6, "HALF_OPEN", 0, $9, $10
      next
    }
    { print }
  ' "$STATS_FILE" > "$_ec_tmp" && _stats_write "$_ec_tmp"
}

# stats_selectable <name> — 0 if the endpoint may take traffic now
stats_selectable() {
  _sl_state=$(stats_field "$1" 7)
  case "$_sl_state" in
    ""|OK|HALF_OPEN) return 0 ;;
    *)               return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# stats_least_bad <name...>
#
# All-degraded fallback: never black-hole. Given the candidate names, print
# the ejected one with the lowest EWMA — the best of a bad fleet. Endpoints
# with no latency history at all sort last (we know nothing about them, but
# an unknown is preferable to a known-bad only if nothing else exists).
# ---------------------------------------------------------------------------
stats_least_bad() {
  for _lb_n in "$@"; do
    awk -v n="$_lb_n" '$1 == n { printf "%.3f %s\n", ($2 + 0 > 0 ? $2 : 999999), $1 }' "$STATS_FILE"
  done | sort -n | awk 'NR == 1 { print $2 }'
}

# ---------------------------------------------------------------------------
# stats_render_metrics <active_endpoint> <fleet_baseline> <all_degraded> <frozen>
#
# Prometheus text format, written atomically for the /metrics handler to cat.
# ---------------------------------------------------------------------------
stats_render_metrics() {
  _rm_active="$1"; _rm_fleet="$2"; _rm_alldeg="$3"; _rm_frozen="$4"
  _rm_tmp="${METRICS_FILE}.tmp.$$"
  {
    echo "# HELP proxy_endpoint_ttfb_ewma_ms Fast EWMA of TTFB per exit endpoint."
    echo "# TYPE proxy_endpoint_ttfb_ewma_ms gauge"
    awk '{ printf "proxy_endpoint_ttfb_ewma_ms{endpoint=\"%s\"} %s\n", $1, $2 }' "$STATS_FILE"
    echo "# HELP proxy_endpoint_ttfb_baseline_ms Slow EWMA of TTFB (the endpoint's own normal)."
    echo "# TYPE proxy_endpoint_ttfb_baseline_ms gauge"
    awk '{ printf "proxy_endpoint_ttfb_baseline_ms{endpoint=\"%s\"} %s\n", $1, $4 }' "$STATS_FILE"
    echo "# HELP proxy_endpoint_error_ratio EWMA of the per-sample failure indicator."
    echo "# TYPE proxy_endpoint_error_ratio gauge"
    awk '{ printf "proxy_endpoint_error_ratio{endpoint=\"%s\"} %s\n", $1, $5 }' "$STATS_FILE"
    echo "# HELP proxy_endpoint_samples_total Samples recorded per endpoint."
    echo "# TYPE proxy_endpoint_samples_total counter"
    awk '{ printf "proxy_endpoint_samples_total{endpoint=\"%s\"} %s\n", $1, $6 }' "$STATS_FILE"
    echo "# HELP proxy_endpoint_trips_total Consecutive trips (drives eject backoff)."
    echo "# TYPE proxy_endpoint_trips_total gauge"
    awk '{ printf "proxy_endpoint_trips_total{endpoint=\"%s\"} %s\n", $1, $9 }' "$STATS_FILE"
    echo "# HELP proxy_endpoint_state Endpoint state, 1 for the active state."
    echo "# TYPE proxy_endpoint_state gauge"
    awk '{
      split("OK EJECTED HALF_OPEN", s, " ")
      for (i = 1; i <= 3; i++)
        printf "proxy_endpoint_state{endpoint=\"%s\",state=\"%s\"} %d\n", $1, s[i], ($7 == s[i] ? 1 : 0)
    }' "$STATS_FILE"
    echo "# HELP proxy_fleet_baseline_ms Median EWMA across eligible endpoints."
    echo "# TYPE proxy_fleet_baseline_ms gauge"
    echo "proxy_fleet_baseline_ms ${_rm_fleet:-0}"
    echo "# HELP proxy_fleet_endpoints_total Endpoints with a record, by state."
    echo "# TYPE proxy_fleet_endpoints_total gauge"
    echo "proxy_fleet_endpoints_total{state=\"any\"} $(stats_count any)"
    echo "proxy_fleet_endpoints_total{state=\"OK\"} $(stats_count OK)"
    echo "proxy_fleet_endpoints_total{state=\"EJECTED\"} $(stats_count EJECTED)"
    echo "proxy_fleet_endpoints_total{state=\"HALF_OPEN\"} $(stats_count HALF_OPEN)"
    echo "# HELP proxy_all_degraded 1 when traffic is being forced through an ejected endpoint."
    echo "# TYPE proxy_all_degraded gauge"
    echo "proxy_all_degraded ${_rm_alldeg:-0}"
    echo "# HELP proxy_ejection_frozen 1 when the ejection circuit breaker is open."
    echo "# TYPE proxy_ejection_frozen gauge"
    echo "proxy_ejection_frozen ${_rm_frozen:-0}"
    if [ -n "$_rm_active" ]; then
      echo "# HELP proxy_active_endpoint The exit currently carrying traffic."
      echo "# TYPE proxy_active_endpoint gauge"
      echo "proxy_active_endpoint{endpoint=\"$_rm_active\"} 1"
    fi
  } > "$_rm_tmp" 2>/dev/null && mv -f "$_rm_tmp" "$METRICS_FILE"
}
