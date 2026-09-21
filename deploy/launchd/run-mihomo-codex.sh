#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEPLOY="$ROOT/deploy"
DATA="${MIHOMO_CODEX_DATA:-$DEPLOY/data/mihomo-codex}"
BIN="${MIHOMO_CODEX_BIN:-$DEPLOY/bin/mihomo-codex}"
RENDER="$DEPLOY/launchd/render-mihomo-codex-config.py"

export PATH="${HOME}/.local/go/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export MIHOMO_CODEX_DATA="$DATA"
umask 077

if [[ ! -x "$BIN" ]]; then
  echo "missing mihomo binary: $BIN" >&2
  exit 1
fi
if [[ ! -f "$DATA/subscriptions.env" ]]; then
  echo "missing $DATA/subscriptions.env" >&2
  exit 1
fi
if [[ ! -f "$DATA/controller.secret" ]]; then
  echo "missing $DATA/controller.secret" >&2
  exit 1
fi

/usr/bin/python3 "$RENDER" >/dev/null
exec "$BIN" -d "$DATA" -f "$DATA/config.yaml"