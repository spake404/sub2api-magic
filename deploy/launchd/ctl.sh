#!/bin/bash
# Control only this deployment; independent proxies stay unmanaged by default.
set -euo pipefail

UID_NUM="$(id -u)"
DOMAIN="gui/${UID_NUM}"
LABEL_BACKEND="com.mrack.sub2api.backend"
LABEL_FRONTEND="com.mrack.sub2api.frontend"
LABEL_MIHOMO="com.mrack.sub2api.mihomo-codex"
LABEL_MOCK="com.mrack.sub2api.mock"
LABEL_CLASH="com.mrack.sub2api.clash"
SERVICES=("$LABEL_MIHOMO" "$LABEL_BACKEND" "$LABEL_FRONTEND")
if [[ "${SUB2_ENABLE_LEGACY_SERVICES:-0}" == 1 ]]; then
  SERVICES+=("$LABEL_MOCK" "$LABEL_CLASH")
fi
AGENTS_DIR="${HOME}/Library/LaunchAgents"

label_loaded() {
  launchctl print "${DOMAIN}/$1" >/dev/null 2>&1
}

plist_path() {
  printf '%s/%s.plist\n' "$AGENTS_DIR" "$1"
}

autostart_installed() {
  [[ -f "$(plist_path "$LABEL_BACKEND")" ]]
}

bootout_label() {
  if label_loaded "$1"; then
    launchctl bootout "${DOMAIN}/$1"
  fi
}

bootstrap_label() {
  local label="$1" plist
  plist="$(plist_path "$label")"
  if [[ ! -f "$plist" ]]; then
    echo "missing $plist" >&2
    return 1
  fi
  launchctl enable "${DOMAIN}/${label}" || return 1
  if ! label_loaded "$label"; then
    launchctl bootstrap "$DOMAIN" "$plist" || return 1
  fi
}

label_port() {
  case "$1" in
    "$LABEL_MIHOMO") printf '3101' ;;
    "$LABEL_BACKEND") printf '8080' ;;
    "$LABEL_FRONTEND") printf '3000' ;;
    "$LABEL_MOCK") printf '18765' ;;
    "$LABEL_CLASH") printf '7890' ;;
    *) return 1 ;;
  esac
}

port_listening() {
  nc -z -G 1 127.0.0.1 "$1" >/dev/null 2>&1
}

backend_healthy() {
  curl --noproxy '*' -fsS --connect-timeout 1 -m 2 \
    "http://127.0.0.1:8080/health" >/dev/null 2>&1
}

ensure_brew_deps() {
  export PATH="${HOME}/.local/go/bin:/opt/homebrew/opt/postgresql@16/bin:/opt/homebrew/bin:$PATH"
  brew services start postgresql@16 >/dev/null
  brew services start redis >/dev/null
}

cmd_status() {
  local label port
  echo "domain: $DOMAIN"
  if autostart_installed; then
    echo "autostart: installed"
  else
    echo "autostart: not installed"
  fi
  for label in "${SERVICES[@]}"; do
    if label_loaded "$label"; then
      echo "$label: loaded"
    else
      echo "$label: not loaded"
    fi
    port="$(label_port "$label")"
    if port_listening "$port"; then
      echo "${label##*.}: listen $port"
    else
      echo "${label##*.}: down ($port)"
    fi
  done
  if backend_healthy; then echo "health: ok"; else echo "health: fail"; fi
}

wait_port() {
  local i
  for i in $(seq 1 20); do
    if port_listening "$1"; then return 0; fi
    sleep 1
  done
  return 1
}

cmd_start() {
  ensure_brew_deps
  local label port failed=0
  for label in "${SERVICES[@]}"; do
    if ! bootstrap_label "$label"; then failed=1; fi
  done
  for label in "${SERVICES[@]}"; do
    port="$(label_port "$label")"
    if ! wait_port "$port"; then
      echo "$label not ready on $port; check its launchd log" >&2
      failed=1
    fi
  done
  if ! backend_healthy; then
    echo "backend health failed" >&2
    failed=1
  fi
  return "$failed"
}

cmd_stop() {
  local i failed=0
  for ((i=${#SERVICES[@]}-1; i>=0; i--)); do
    if ! bootout_label "${SERVICES[$i]}"; then failed=1; fi
  done
  return "$failed"
}

case "${1:-}" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  installed) autostart_installed ;;
  *) echo "usage: $0 {start|stop|status|installed}" >&2; exit 2 ;;
esac