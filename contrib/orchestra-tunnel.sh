#!/usr/bin/env bash
# orchestra-tunnel.sh — the board from another computer, over SSH.
#
# The board trusts loopback and nothing else: index.html sends no
# `Authorization` header, so a browser on a second machine cannot present a
# device token however many you mint. A forward sidesteps that without widening
# anything — `-L` makes the far end connect to its OWN 127.0.0.1, which is the
# address the board already trusts. docs/REMOTE-ACCESS.md argues the whole case.
#
#   ./contrib/orchestra-tunnel.sh up you@board-host.your-tailnet.ts.net
#   ./contrib/orchestra-tunnel.sh status
#   ./contrib/orchestra-tunnel.sh down
#
# The host may instead come from ORCHESTRA_SSH_HOST — what a shell alias sets so
# `up` takes no argument. Ports: ORCHESTRA_PORT (the board's, default 4242) and
# ORCHESTRA_LOCAL_PORT (this end, default: the same number).
#
# Nothing is needed on the board host beyond Remote Login and your key in its
# authorized_keys. No --tailnet, no --add-device, no config edit: the default
# 127.0.0.1 bind is exactly what the forward reaches.

set -uo pipefail

PORT="${ORCHESTRA_PORT:-4242}"
LPORT="${ORCHESTRA_LOCAL_PORT:-$PORT}"
HOST="${2:-${ORCHESTRA_SSH_HOST:-}}"

FORWARD="${LPORT}:localhost:${PORT}"
URL="http://localhost:${LPORT}"

usage() {
  cat >&2 <<EOF
usage: $(basename "$0") [up|down|restart|status] [user@board-host]

  up        open the forward (if needed) and the browser
  down      close it
  restart   down, then up
  status    board host, board, forward, dashboard

The host comes from the argument or \$ORCHESTRA_SSH_HOST.
EOF
}

need_host() {
  [ -n "$HOST" ] && return 0
  echo "No board host. Pass one, or set ORCHESTRA_SSH_HOST." >&2
  usage
  return 2
}

open_url() {
  if command -v open >/dev/null 2>&1; then open "$URL"
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$URL" >/dev/null 2>&1 &
  else echo "Open $URL"
  fi
}

# Asked over SSH rather than over the tailnet, because the tailnet address only
# answers under --tailnet while 127.0.0.1 answers under every configuration —
# and /api/health is one of the two routes that needs no token anyway.
board_running() {
  [ -n "$HOST" ] || return 1
  local code
  code=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST" \
           "curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:${PORT}/api/health" 2>/dev/null)
  [ "$code" = "200" ]
}

dashboard_up() {
  [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$URL" 2>/dev/null)" = "200" ]
}

# The escaped dash keeps the pattern from being read as an option.
tunnel_pids() { pgrep -f "\-L ${FORWARD}" 2>/dev/null; }

up() {
  if dashboard_up; then
    echo "Already up — ${URL}"
    open_url
    return 0
  fi

  # A forward whose dashboard does not answer is a corpse holding the local
  # port, and ExitOnForwardFailure would refuse the replacement. Clear it.
  local stale
  stale=$(tunnel_pids)
  if [ -n "$stale" ]; then
    echo "Clearing a forward that answers nothing (${stale//$'\n'/ })"
    kill $stale 2>/dev/null
    sleep 1
  fi

  need_host || return $?

  if ! board_running; then
    echo "No board on ${HOST}:${PORT} — or that host is unreachable." >&2
    echo "Start it there, then rerun:  python3 -m orchestra --root ~/code" >&2
    return 1
  fi

  echo "Forwarding ${URL} → ${HOST}:${PORT}"
  local ssh_opts=(-f -N
    -o ServerAliveInterval=30 -o ServerAliveCountMax=3
    -o ExitOnForwardFailure=yes
    -L "$FORWARD")

  # autossh rebuilds the forward after a sleep or a dropped link; -M 0 leaves
  # liveness to SSH's own keepalives instead of autossh's monitoring port.
  if command -v autossh >/dev/null 2>&1; then
    autossh -M 0 "${ssh_opts[@]}" "$HOST" || return 1
  else
    ssh "${ssh_opts[@]}" "$HOST" || return 1
  fi

  local i
  for i in $(seq 1 10); do
    if dashboard_up; then echo "Up — ${URL}"; open_url; return 0; fi
    sleep 1
  done

  echo "The forward started but ${URL} did not answer within 10 s." >&2
  return 1
}

down() {
  local pids
  pids=$(tunnel_pids)
  if [ -z "$pids" ]; then echo "Nothing to close."; return 0; fi
  kill $pids 2>/dev/null
  echo "Closed (${pids//$'\n'/ })"
}

status() {
  printf '%-14s %s\n' "board host" "${HOST:-unset — pass one or set ORCHESTRA_SSH_HOST}"

  printf '%-14s ' "board"
  if [ -z "$HOST" ]; then echo "unknown"
  elif board_running; then echo "listening on 127.0.0.1:${PORT} there"
  else echo "not answering"; fi

  printf '%-14s ' "forward"
  local pids; pids=$(tunnel_pids)
  if [ -n "$pids" ]; then echo "pid ${pids//$'\n'/ }"; else echo "down"; fi

  printf '%-14s ' "dashboard"
  if dashboard_up; then echo "${URL} — 200"; else echo "unreachable"; fi
}

case "${1:-up}" in
  up|"")     up ;;
  down|stop) down ;;
  restart)   down; sleep 1; up ;;
  status)    status ;;
  -h|--help|help) usage ;;
  *) usage; exit 2 ;;
esac
