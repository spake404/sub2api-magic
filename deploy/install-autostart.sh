#!/bin/bash
# Install user LaunchAgents so local sub2api comes back after login/reboot.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="$ROOT/deploy"
LAUNCHD="$DEPLOY/launchd"
AGENTS_DIR="${HOME}/Library/LaunchAgents"
UID_NUM="$(id -u)"
DOMAIN="gui/${UID_NUM}"

LABEL_BACKEND="com.mrack.sub2api.backend"
LABEL_FRONTEND="com.mrack.sub2api.frontend"
LABEL_MIHOMO="com.mrack.sub2api.mihomo-codex"
LABEL_MOCK="com.mrack.sub2api.mock"
LABEL_CLASH="com.mrack.sub2api.clash"

chmod +x "$LAUNCHD"/run-*.sh "$LAUNCHD/ctl.sh"

mkdir -p "$AGENTS_DIR" "$DEPLOY/data"

write_plist() {
  local label="$1"
  local script="$2"
  local stdout="$3"
  local stderr="$4"
  local keepalive="$5"
  local dest="${AGENTS_DIR}/${label}.plist"
  # Preserve locally customized agents and leave running processes alone.
  if [[ -f "$dest" ]]; then
    plutil -lint "$dest" >/dev/null
    return
  fi
  cat >"$dest" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>${script}</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	${keepalive}
	<key>ThrottleInterval</key>
	<integer>10</integer>
	<key>ProcessType</key>
	<string>Background</string>
	<key>LimitLoadToSessionType</key>
	<array>
		<string>Aqua</string>
	</array>
	<key>StandardOutPath</key>
	<string>${stdout}</string>
	<key>StandardErrorPath</key>
	<string>${stderr}</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>${HOME}/.local/go/bin:/opt/homebrew/opt/postgresql@16/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
		<key>LANG</key>
		<string>en_US.UTF-8</string>
		<key>LC_ALL</key>
		<string>en_US.UTF-8</string>
	</dict>
</dict>
</plist>
EOF
  plutil -lint "$dest" >/dev/null
}

KEEPALIVE_TRUE="<true/>"
KEEPALIVE_FALSE="<false/>"

write_plist "$LABEL_BACKEND" "$LAUNCHD/run-backend.sh" \
  "$DEPLOY/data/backend.launchd.log" "$DEPLOY/data/backend.launchd.log" \
  "$KEEPALIVE_TRUE"
write_plist "$LABEL_FRONTEND" "$LAUNCHD/run-frontend.sh" \
  "$DEPLOY/data/frontend.launchd.log" "$DEPLOY/data/frontend.launchd.log" \
  "$KEEPALIVE_TRUE"
write_plist "$LABEL_MIHOMO" "$LAUNCHD/run-mihomo-codex.sh" \
  "$DEPLOY/data/mihomo-codex.launchd.log" "$DEPLOY/data/mihomo-codex.launchd.log" \
  "$KEEPALIVE_TRUE"
if [[ "${SUB2_ENABLE_LEGACY_SERVICES:-0}" == 1 ]]; then
  write_plist "$LABEL_MOCK" "$LAUNCHD/run-mock.sh" \
    "$DEPLOY/data/mock-openai.launchd.log" "$DEPLOY/data/mock-openai.launchd.log" \
    "$KEEPALIVE_TRUE"
  write_plist "$LABEL_CLASH" "$LAUNCHD/run-clash.sh" \
    "$DEPLOY/data/clash.launchd.log" "$DEPLOY/data/clash.launchd.log" \
    "$KEEPALIVE_FALSE"
fi

echo "[autostart] installing LaunchAgents for uid ${UID_NUM}"
# Start is idempotent: no PID-file or port-based kills of unrelated processes.
bash "$LAUNCHD/ctl.sh" start

echo "[autostart] waiting for health"
ok=0
for _ in $(seq 1 60); do
  if curl --noproxy '*' -fsS --connect-timeout 1 -m 2 "http://127.0.0.1:8080/health" >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 1
done
if [[ "$ok" -ne 1 ]]; then
  echo "[autostart] backend health failed; last log:" >&2
  tail -n 40 "$DEPLOY/data/backend.launchd.log" >&2 || true
  launchctl print "${DOMAIN}/${LABEL_BACKEND}" 2>&1 | tail -n 40 >&2 || true
  exit 1
fi

for _ in $(seq 1 30); do
  if lsof -nP -iTCP:3000 -sTCP:LISTEN >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

echo "[autostart] installed"
echo "  UI:      http://127.0.0.1:3000"
echo "  API:     http://127.0.0.1:8080"
echo "  health:  http://127.0.0.1:8080/health"
bash "$LAUNCHD/ctl.sh" status
echo "[autostart] reboot/login will load these agents automatically"
printf '[autostart] stop this session only: bash "%s/ctl.sh" stop\n' "$LAUNCHD"
printf '[autostart] start again:            bash "%s/ctl.sh" start\n' "$LAUNCHD"