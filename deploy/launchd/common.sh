# shellcheck shell=bash
# Shared helpers for launchd wrappers. Sourced by run-*.sh; $0 remains the caller.

sub2_repo_root() {
  cd "$(dirname "$0")/../.." && pwd
}

sub2_prepare_env() {
  ROOT="$(sub2_repo_root)"
  DEPLOY="$ROOT/deploy"
  ENV_FILE="$DEPLOY/.env"
  umask 077
  export PATH="${HOME}/.local/go/bin:/opt/homebrew/opt/postgresql@16/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"
  export GOSUMDB="${GOSUMDB:-sum.golang.google.cn}"
  export LANG="${LANG:-en_US.UTF-8}"
  export LC_ALL="${LC_ALL:-en_US.UTF-8}"

  if [[ ! -f "$ENV_FILE" ]]; then
    echo "missing $ENV_FILE" >&2
    exit 1
  fi

  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a

  DATA_DIR="${DATA_DIR:-$DEPLOY/data}"
  export DATA_DIR ROOT DEPLOY
  mkdir -p "$DATA_DIR"
}

sub2_wait_postgres_redis() {
  local i
  local pg_port="${DATABASE_PORT:-5432}"
  local redis_port="${REDIS_PORT:-6379}"
  for i in $(seq 1 90); do
    if pg_isready -h 127.0.0.1 -p "$pg_port" >/dev/null 2>&1 \
      && redis-cli -h 127.0.0.1 -p "$redis_port" ping >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "postgres/redis not ready after 90s" >&2
  return 1
}

sub2_wait_health() {
  local url="$1"
  local i
  for i in $(seq 1 60); do
    if curl -fsS -m 1 "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}