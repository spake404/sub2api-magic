#!/bin/bash
set -euo pipefail
# launchd entry: wait for Homebrew Postgres/Redis, then exec the local binary.
. "$(dirname "$0")/common.sh"
sub2_prepare_env
sub2_wait_postgres_redis

if [[ ! -x "$DEPLOY/bin/server" ]]; then
  echo "[launchd] building backend" >&2
  mkdir -p "$DEPLOY/bin"
  GO_BIN="${GO_BIN:-$HOME/.local/go/bin/go}"
  (
    cd "$ROOT/backend"
    CGO_ENABLED=0 "$GO_BIN" build -ldflags="-s -w -X main.Version=local-dev" -trimpath -o "$DEPLOY/bin/server" ./cmd/server
  )
fi

cd "$DATA_DIR"
exec "$DEPLOY/bin/server"