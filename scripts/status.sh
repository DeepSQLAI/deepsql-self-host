#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="${DEEPSQL_COMPOSE_FILE:-$ROOT_DIR/docker-compose.yml}"
ENV_FILE="${DEEPSQL_ENV_FILE:-$ROOT_DIR/.env}"
PROJECT_NAME="${DEEPSQL_PROJECT_NAME:-deepsql-selfhost}"

compose() {
  docker compose \
    --project-name "$PROJECT_NAME" \
    --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" \
    "$@"
}

load_env_file() {
  local line name value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

    if [[ "$line" == export\ * ]]; then
      line="${line#export }"
    fi

    [[ "$line" == *=* ]] || continue
    name="${line%%=*}"
    value="${line#*=}"

    if [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      export "$name=$value"
    fi
  done < "$ENV_FILE"
}

if [[ -f "$ENV_FILE" ]]; then
  load_env_file
fi

: "${DEEPSQL_FRONTEND_PORT:=3000}"
: "${DEEPSQL_BACKEND_PORT:=8080}"

echo "Compose services:"
compose ps

echo
printf 'Backend health: '
if curl -fsS "http://localhost:${DEEPSQL_BACKEND_PORT}/api/actuator/health"; then
  printf '\n'
else
  echo "unreachable"
fi

printf 'Frontend health: '
if curl -fsS "http://localhost:${DEEPSQL_FRONTEND_PORT}" >/dev/null 2>&1; then
  echo "ok"
else
  echo "unreachable"
fi
