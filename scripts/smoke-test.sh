#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${DEEPSQL_ENV_FILE:-$ROOT_DIR/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: missing env file $ENV_FILE" >&2
  exit 1
fi

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

load_env_file

: "${DEEPSQL_BACKEND_PORT:=9085}"
: "${DB_PASSWORD:=postgres}"
: "${DEEPSQL_INITIAL_ADMIN_EMAIL:=}"
: "${DEEPSQL_INITIAL_ADMIN_PASSWORD:=}"
: "${DEEPSQL_SMOKE_EMAIL:=${DEEPSQL_INITIAL_ADMIN_EMAIL}}"
: "${DEEPSQL_SMOKE_PASSWORD:=${DEEPSQL_INITIAL_ADMIN_PASSWORD}}"
: "${DEEPSQL_SMOKE_CONNECTION_NAME:=Self-Host Vault Postgres Smoke $(date +%s)}"

if [[ -z "$DEEPSQL_SMOKE_EMAIL" ]]; then
  echo "Error: set DEEPSQL_INITIAL_ADMIN_EMAIL or DEEPSQL_SMOKE_EMAIL in the environment." >&2
  exit 1
fi

if [[ -z "$DEEPSQL_SMOKE_PASSWORD" ]]; then
  echo "Error: set DEEPSQL_INITIAL_ADMIN_PASSWORD or DEEPSQL_SMOKE_PASSWORD in the environment." >&2
  exit 1
fi

base="http://localhost:${DEEPSQL_BACKEND_PORT}/api"
cookie_jar="$(mktemp)"
trap 'rm -f "$cookie_jar"' EXIT

login_json="$(curl -fsS -c "$cookie_jar" -H 'Content-Type: application/json' -X POST "$base/auth/login" -d "{\"email\":\"${DEEPSQL_SMOKE_EMAIL}\",\"password\":\"${DEEPSQL_SMOKE_PASSWORD}\"}")"

if [[ "$login_json" != *'"username":"admin"'* ]]; then
  echo "Error: login failed during smoke test." >&2
  echo "$login_json" >&2
  exit 1
fi

payload=$(cat <<JSON
{
  "connectionName": "${DEEPSQL_SMOKE_CONNECTION_NAME}",
  "dbType": "postgres",
  "host": "postgres",
  "port": 5432,
  "database": "dba_agent",
  "username": "postgres",
  "password": "${DB_PASSWORD}",
  "cloudProvider": "self-hosted",
  "ssl": false,
  "sslMode": "none",
  "sshEnabled": false
}
JSON
)

save_json="$(curl -fsS -b "$cookie_jar" -H 'Content-Type: application/json' -X POST "$base/connections" -d "$payload")"
connection_id="$(printf '%s' "$save_json" | sed -n 's/.*"connectionId":"\([^"]*\)".*/\1/p')"

if [[ -z "$connection_id" ]]; then
  echo "Error: failed to create smoke-test connection." >&2
  echo "$save_json" >&2
  exit 1
fi

connections_json="$(curl -fsS -b "$cookie_jar" "$base/connections")"
if [[ "$connections_json" != *"${DEEPSQL_SMOKE_CONNECTION_NAME}"* ]]; then
  echo "Error: connection list does not contain the smoke-test connection." >&2
  exit 1
fi

schema_json="$(curl -fsS -b "$cookie_jar" "$base/connections/${connection_id}/schema")"
if [[ "$schema_json" != *'"success":true'* ]]; then
  echo "Error: schema introspection failed for smoke-test connection." >&2
  echo "$schema_json" >&2
  exit 1
fi

echo "Smoke test passed."
echo "Connection ID: ${connection_id}"
