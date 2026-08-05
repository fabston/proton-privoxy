#!/bin/sh
# Read-only health verification for proton-privoxy. Safe to run any time,
# including against a live proxy — it starts no VPN sessions and kills nothing.
#
#   ./verify.sh
#
# Exit status 0 = all checks passed, 1 = at least one FAIL.
# WARN means "look at it", not "broken".

CONTAINER="${CONTAINER:-proton_privoxy_service}"
HEALTH="${HEALTH:-127.0.0.1:8081}"
PROXY="${PROXY:-127.0.0.1:8100}"

_fail=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; _fail=1; }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

dex() { docker exec "$CONTAINER" "$@" 2>/dev/null; }

head_ "1. Container"
if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  fail "$CONTAINER is not running"
  echo; echo "Nothing else can be checked. Try: docker compose up -d"; exit 1
fi
pass "running"
_hs=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER" 2>/dev/null)
case "$_hs" in
  healthy)   pass "docker healthcheck: healthy" ;;
  starting)  warn "docker healthcheck: starting (first VPN connect can take ~45s)" ;;
  none)      fail "no healthcheck defined — a dead tunnel would look fine to Docker" ;;
  *)         fail "docker healthcheck: $_hs" ;;
esac
_up=$(docker inspect --format '{{.State.StartedAt}}' "$CONTAINER" 2>/dev/null)
[ -n "$_up" ] && echo "        started $_up"

# Privoxy only starts AFTER the tunnel is up, so everything below fails
# spuriously if we look during startup. Wait it out rather than cry wolf.
_w=0
while [ "$_w" -lt "${WAIT_READY:-90}" ]; do
  case "$(curl -s -m 5 "http://$HEALTH/ready" 2>/dev/null)" in *'"ready"'*) break ;; esac
  [ "$_w" -eq 0 ] && printf '        waiting for readiness (first VPN connect takes ~5-45s)'
  printf '.'
  sleep 3; _w=$((_w + 3))
done
[ "$_w" -gt 0 ] && echo
if [ "$_w" -ge "${WAIT_READY:-90}" ]; then
  warn "still not ready after ${WAIT_READY:-90}s — checks below may reflect a mid-rotation state"
fi

head_ "2. Processes"
if dex pgrep -x privoxy >/dev/null; then pass "privoxy running"; else fail "privoxy NOT running"; fi
if dex pgrep -x openvpn >/dev/null; then pass "openvpn running"; else fail "openvpn NOT running"; fi
_z=$(dex ps -eo stat,comm | awk '$1 ~ /^Z/' | wc -l | tr -d ' ')
if [ "${_z:-0}" -eq 0 ]; then pass "no zombie processes"; else warn "$_z zombies — is init:true set in docker-compose.yml?"; fi

head_ "3. Egress path (the leak check)"
_iface=$(dex ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
case "$_iface" in
  tun*) pass "traffic egresses via $_iface" ;;
  "")   fail "no route to the internet at all" ;;
  *)    fail "traffic egresses via $_iface — NOT the tunnel. This is a leak." ;;
esac

_host_ip=$(curl -sS -m 10 https://ipv4.icanhazip.com 2>/dev/null | tr -d '\r\n')
_prox_ip=$(curl -sS -m 20 -x "http://$PROXY" http://ipv4.icanhazip.com 2>/dev/null | tr -d '\r\n')
if [ -z "$_prox_ip" ]; then
  fail "proxy returned nothing — not serving"
elif [ -z "$_host_ip" ]; then
  warn "could not determine host IP to compare; proxy exit IP is $_prox_ip"
elif [ "$_prox_ip" = "$_host_ip" ]; then
  fail "proxy exit IP == host IP ($_prox_ip) — TRAFFIC IS NOT GOING THROUGH THE VPN"
else
  pass "proxy works, exit IP $_prox_ip (host is $_host_ip)"
fi

head_ "4. Health endpoints"
_h=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$HEALTH/health" 2>/dev/null)
[ "$_h" = "200" ] && pass "/health 200" || fail "/health returned ${_h:-nothing}"
_r=$(curl -s -m 5 "http://$HEALTH/ready" 2>/dev/null)
case "$_r" in
  *'"ready"'*) pass "/ready 200 — $_r" ;;
  "")          fail "/ready returned nothing" ;;
  *)           warn "/ready not ready — $_r (normal during a rotation)" ;;
esac
_mtx=$(curl -s -m 5 "http://$HEALTH/metrics" 2>/dev/null)
_m=$(printf '%s\n' "$_mtx" | grep -c '^proxy_')
if [ "${_m:-0}" -gt 0 ]; then pass "/metrics exposing $_m series"; else fail "/metrics empty"; fi

# Supervisor heartbeat: the failure mode where every other signal looks fine.
_age=$(printf '%s\n' "$_mtx" | awk '/^proxy_state_age_seconds/{print $2}')
if [ -z "$_age" ]; then
  warn "no proxy_state_age_seconds — old image?"
elif [ "$_age" -lt 0 ]; then
  fail "supervisor state file unreadable"
elif [ "$_age" -gt 60 ]; then
  fail "supervisor heartbeat ${_age}s old — the rotation loop is wedged"
else
  pass "supervisor heartbeat ${_age}s old"
fi

_rot=$(printf '%s\n' "$_mtx" | grep '^proxy_rotations_total' | sed 's/proxy_rotations_total//')
if [ -n "$_rot" ]; then
  echo "        rotations by reason:"
  printf '%s\n' "$_rot" | sed 's/^/          /'
fi
_conns=$(printf '%s\n' "$_mtx" | awk '/^proxy_client_connections/{print $2}')
[ -n "$_conns" ] && echo "        client connections right now: $_conns"

head_ "5. Privoxy config"
if docker logs "$CONTAINER" 2>&1 | grep -q "unrecognized directive"; then
  fail "privoxy rejected a directive:"
  docker logs "$CONTAINER" 2>&1 | grep "unrecognized directive" | tail -3 | sed 's/^/        /'
else
  pass "no rejected directives"
fi
if dex grep -q '^permit-access' /app/config; then
  pass "ACLs present in config"
  dex grep '^permit-access' /app/config | sed 's/^/        /'
else
  warn "no permit-access lines — proxy is open to anything that can reach it"
fi

head_ "6. Endpoint scoring"
_se=$(dex printenv ENDPOINT_SCORING_ENABLED)
if [ "$_se" = "0" ]; then
  warn "scoring DISABLED (ENDPOINT_SCORING_ENABLED=0) — kill switch and drain still active"
else
  pass "scoring enabled${_se:+ (=$_se)}${_se:-  (default)}"
  _stats=$(dex cat /var/lib/proxy/endpoint_stats 2>/dev/null)
  if [ -z "$_stats" ]; then
    warn "no stats yet — expected on a fresh volume"
  else
    _n=$(printf '%s\n' "$_stats" | grep -c .)
    _ej=$(printf '%s\n' "$_stats" | awk '$7=="EJECTED"' | wc -l | tr -d ' ')
    pass "$_n endpoint(s) tracked, $_ej ejected"
    printf '%s\n' "$_stats" | awk '{printf "        %-34s ewma=%-9s base=%-9s err=%-8s n=%-5s %s\n",$1,$2,$4,$5,$6,$7}'
    _fleet=$(curl -s -m 5 "http://$HEALTH/metrics" 2>/dev/null | awk '/^proxy_fleet_baseline_ms/{print $2}')
    [ -n "$_fleet" ] && [ "$_fleet" != "0" ] \
      && echo "        fleet baseline: ${_fleet}ms" \
      || echo "        fleet baseline: not yet established (needs MIN_SAMPLES on 2+ endpoints)"
  fi
fi

head_ "7. Recent events"
docker logs --tail 300 "$CONTAINER" 2>&1 | grep -oE 'event=[a-z_]+' | sort | uniq -c | sort -rn | head -10 | sed 's/^/      /'
_td=$(docker logs --tail 300 "$CONTAINER" 2>&1 | grep -c 'event=tunnel_down')
if [ "${_td:-0}" -gt 3 ]; then
  fail "$_td tunnel_down events in recent logs — possible rotation storm"
elif [ "${_td:-0}" -gt 0 ]; then
  warn "$_td tunnel_down event(s) recently — fine if you tested the kill switch"
else
  pass "no unexpected tunnel drops"
fi

echo
if [ "$_fail" -eq 0 ]; then
  printf '\033[32mAll checks passed.\033[0m\n'
else
  printf '\033[31mOne or more checks FAILED (see above).\033[0m\n'
fi
echo
echo "Not covered here (needs a disruptive test):"
echo "  - kill switch:        docker exec $CONTAINER pkill -KILL openvpn   (want tunnel_down <5s)"
echo "  - graceful shutdown:  time docker stop $CONTAINER                  (want <10s + supervisor_exit)"
exit "$_fail"
