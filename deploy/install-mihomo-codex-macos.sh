#!/usr/bin/env bash
# macOS user-level equivalent of deploy/install-mihomo-codex.sh
# Official Linux installer needs root, systemd, and linux-* assets.
# This keeps the same sidecar contract: 127.0.0.1:3101 + CODEX-ROTATE.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="$ROOT/deploy"
DATA="${MIHOMO_CODEX_DATA:-$DEPLOY/data/mihomo-codex}"
BIN="${MIHOMO_CODEX_BIN:-$DEPLOY/bin/mihomo-codex}"
MIHOMO_VERSION="${MIHOMO_VERSION:-v1.19.31}"
MIHOMO_CODEX_PORT="${MIHOMO_CODEX_PORT:-3101}"
MIHOMO_CODEX_CONTROLLER="${MIHOMO_CODEX_CONTROLLER:-127.0.0.1:9098}"
LABEL="com.mrack.sub2api.mihomo-codex"
DOMAIN="gui/$(id -u)"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
ASSET_URL="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/mihomo-darwin-arm64-${MIHOMO_VERSION}.gz"
CLASH_CORE="${HOME}/Library/Application Support/com.metacubex.ClashX.meta/.private_core/com.metacubex.ClashX.ProxyConfigHelper.meta"

die() { echo "ERROR: $*" >&2; exit 1; }

mkdir -p "$DATA/providers" "$DEPLOY/bin"
chmod 700 "$DATA" "$DATA/providers"

if [[ ! -f "$DATA/subscriptions.env" ]]; then
  [[ -n "${MIHOMO_CODEX_SUBSCRIPTION_URL:-}" ]] || die "MIHOMO_CODEX_SUBSCRIPTION_URL is required"
  umask 077
  {
    printf 'MIHOMO_CODEX_SUBSCRIPTION_URL=%s\n' "$MIHOMO_CODEX_SUBSCRIPTION_URL"
    if [[ -n "${MIHOMO_CODEX_SUBSCRIPTION_URL_2:-}" ]]; then
      printf 'MIHOMO_CODEX_SUBSCRIPTION_URL_2=%s\n' "$MIHOMO_CODEX_SUBSCRIPTION_URL_2"
    fi
    if [[ -n "${MIHOMO_CODEX_LOCAL_SOURCES:-}" ]]; then
      printf 'MIHOMO_CODEX_LOCAL_SOURCES=%s\n' "$MIHOMO_CODEX_LOCAL_SOURCES"
    fi
  } > "$DATA/subscriptions.env"
  chmod 600 "$DATA/subscriptions.env"
fi

if [[ ! -s "$DATA/controller.secret" ]]; then
  od -vAn -N24 -tx1 /dev/urandom | tr -d ' \n' > "$DATA/controller.secret"
  chmod 600 "$DATA/controller.secret"
fi

download_mihomo() {
  local tmp gz
  tmp="$(mktemp /tmp/mihomo-codex.XXXXXX)"
  gz="${tmp}.gz"
  if curl -fL --max-time 120 -x http://127.0.0.1:7890 -o "$gz" "$ASSET_URL" \
    || curl -fL --max-time 120 -o "$gz" "$ASSET_URL"; then
    gzip -dc "$gz" > "$tmp"
    rm -f "$gz"
    chmod 0755 "$tmp"
    mv "$tmp" "$BIN"
    return 0
  fi
  rm -f "$tmp" "$gz"
  return 1
}

if [[ ! -x "$BIN" ]]; then
  if ! download_mihomo; then
    [[ -x "$CLASH_CORE" ]] || die "failed to download mihomo ${MIHOMO_VERSION}"
    echo "WARN: using ClashX Meta core as mihomo fallback" >&2
    cp "$CLASH_CORE" "$BIN"
    chmod 0755 "$BIN"
  fi
fi

export MIHOMO_CODEX_DATA="$DATA"
export MIHOMO_CODEX_PORT
export MIHOMO_CODEX_CONTROLLER
/usr/bin/python3 "$DEPLOY/launchd/render-mihomo-codex-config.py"

"$BIN" -d "$DATA" -f "$DATA/config.yaml" -t >/tmp/mihomo-codex-test.out 2>&1 \
  || die "mihomo config test failed: $(tail -n 20 /tmp/mihomo-codex-test.out)"

chmod +x "$DEPLOY/launchd/run-mihomo-codex.sh"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>${DEPLOY}/launchd/run-mihomo-codex.sh</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>10</integer>
	<key>ProcessType</key>
	<string>Background</string>
	<key>LimitLoadToSessionType</key>
	<array>
		<string>Aqua</string>
	</array>
	<key>StandardOutPath</key>
	<string>${DEPLOY}/data/mihomo-codex.launchd.log</string>
	<key>StandardErrorPath</key>
	<string>${DEPLOY}/data/mihomo-codex.launchd.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>${HOME}/.local/go/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
		<key>LANG</key>
		<string>en_US.UTF-8</string>
		<key>LC_ALL</key>
		<string>en_US.UTF-8</string>
	</dict>
</dict>
</plist>
EOF
plutil -lint "$PLIST" >/dev/null

if launchctl print "${DOMAIN}/${LABEL}" >/dev/null 2>&1; then
  launchctl bootout "${DOMAIN}/${LABEL}" >/dev/null 2>&1 || true
fi
if ! launchctl bootstrap "$DOMAIN" "$PLIST"; then
  launchctl load -w "$PLIST" >/dev/null 2>&1 || true
fi
launchctl enable "${DOMAIN}/${LABEL}" >/dev/null 2>&1 || true
launchctl kickstart -k "${DOMAIN}/${LABEL}" >/dev/null 2>&1 || true

ok=0
for _ in $(seq 1 20); do
  if nc -z -G 1 127.0.0.1 "$MIHOMO_CODEX_PORT" >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 1
done
[[ "$ok" -eq 1 ]] || die "mihomo-codex did not listen on 127.0.0.1:${MIHOMO_CODEX_PORT}"
echo "Mihomo Codex sidecar is listening on http://127.0.0.1:${MIHOMO_CODEX_PORT}"
echo "Set Sub2API 292 harvest proxy to that URL (Mihomo/VPN kernel)."