#!/bin/bash
set -euo pipefail
# launchd entry: Vite admin UI, proxying /api /v1 /health to the local backend.
. "$(dirname "$0")/common.sh"
sub2_prepare_env

VITE_BIN="$ROOT/frontend/node_modules/.bin/vite"
if [[ ! -x "$VITE_BIN" ]]; then
  echo "missing $VITE_BIN (run npm install in frontend)" >&2
  exit 1
fi

# Vite can start before the API, but the panel is useless until /health is up.
sub2_wait_health "http://127.0.0.1:${SERVER_PORT:-8080}/health" || true

cd "$ROOT/frontend"
export VITE_DEV_PROXY_TARGET="http://127.0.0.1:${SERVER_PORT:-8080}"
exec "$VITE_BIN" --host 127.0.0.1 --port "${VITE_DEV_PORT:-3000}"