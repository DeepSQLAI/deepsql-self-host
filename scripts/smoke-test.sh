#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${DEEPSQL_ENV_FILE:-$ROOT_DIR/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: missing env file $ENV_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a
source "$ENV_FILE"
set +a

: "${DEEPSQL_BACKEND_PORT:=8080}"
: "${DB_PASSWORD:=postgres}"
: "${DEEPSQL_INITIAL_ADMIN_PASSWORD:=}"
: "${DEEPSQL_SMOKE_USERNAME:=admin}"
: "${DEEPSQL_SMOKE_PASSWORD:=${DEEPSQL_INITIAL_ADMIN_PASSWORD}}"
: "${DEEPSQL_SMOKE_CONNECTION_NAME:=Self-Host Vault Postgres Smoke $(date +%s)}"

if [[ -z "$DEEPSQL_SMOKE_PASSWORD" ]]; then
  echo "Error: set DEEPSQL_INITIAL_ADMIN_PASSWORD or DEEPSQL_SMOKE_PASSWORD in the environment." >&2
  exit 1
fi

base="http://localhost:${DEEPSQL_BACKEND_PORT}/api"
login_json="$(curl -fsS -H 'Content-Type: application/json' -X POST "$base/auth/login" -d "{\"username\":\"${DEEPSQL_SMOKE_USERNAME}\",\"password\":\"${DEEPSQL_SMOKE_PASSWORD}\"}")"
token="$(printf '%s' "$login_json" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"

if [[ -z "$token" ]]; then
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

save_json="$(curl -fsS -H 'Content-Type: application/json' -H "Authorization: Bearer ${token}" -X POST "$base/connections" -d "$payload")"
connection_id="$(printf '%s' "$save_json" | sed -n 's/.*"connectionId":"\([^"]*\)".*/\1/p')"

if [[ -z "$connection_id" ]]; then
  echo "Error: failed to create smoke-test connection." >&2
  echo "$save_json" >&2
  exit 1
fi

connections_json="$(curl -fsS -H "Authorization: Bearer ${token}" "$base/connections")"
if [[ "$connections_json" != *"${DEEPSQL_SMOKE_CONNECTION_NAME}"* ]]; then
  echo "Error: connection list does not contain the smoke-test connection." >&2
  exit 1
fi

schema_json="$(curl -fsS -H "Authorization: Bearer ${token}" "$base/connections/${connection_id}/schema")"
if [[ "$schema_json" != *'"success":true'* ]]; then
  echo "Error: schema introspection failed for smoke-test connection." >&2
  echo "$schema_json" >&2
  exit 1
fi

echo "Smoke test passed."
echo "Connection ID: ${connection_id}"
