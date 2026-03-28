#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="${DEEPSQL_COMPOSE_FILE:-$ROOT_DIR/docker-compose.yml}"
ENV_FILE="${DEEPSQL_ENV_FILE:-$ROOT_DIR/.env}"
PROJECT_NAME="${DEEPSQL_PROJECT_NAME:-deepsql-selfhost}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command '$1' is not installed." >&2
    exit 1
  fi
}

is_placeholder() {
  local value="${1:-}"
  [[ -z "$value" || "$value" == change-me-* || "$value" == replace-with-* || "$value" == your-* ]]
}

require_env_value() {
  local name="$1"
  local value="${!name:-}"
  if is_placeholder "$value"; then
    echo "Error: '$name' must be set in $ENV_FILE." >&2
    exit 1
  fi
}

ensure_local_image() {
  local image_ref="$1"
  if ! docker image inspect "$image_ref" >/dev/null 2>&1; then
    echo "Error: Docker image '$image_ref' is not present locally." >&2
    echo "Either load the image first or set DEEPSQL_SKIP_IMAGE_PULL=false." >&2
    exit 1
  fi
}

generate_secret() {
  local name="$1"
  local cmd="$2"
  local value="${!name:-}"
  if is_placeholder "$value"; then
    local generated
    generated="$(eval "$cmd")"
    sed_inplace "s|^${name}=.*|${name}=${generated}|" "$ENV_FILE"
    eval "export ${name}=${generated}"
    echo "Auto-generated $name."
  fi
}

prompt_env_value() {
  local name="$1"
  local label="$2"
  local value="${!name:-}"
  if is_placeholder "$value"; then
    printf '%s: ' "$label"
    read -r value
    if [[ -z "$value" ]]; then
      echo "Error: '$name' is required." >&2
      exit 1
    fi
    sed_inplace "s|^${name}=.*|${name}=${value}|" "$ENV_FILE"
    eval "export ${name}=${value}"
  fi
}

sed_inplace() {
  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

check_registry_access() {
  if [[ "${DEEPSQL_SKIP_IMAGE_PULL:-false}" == "true" ]]; then
    return 0
  fi
  local test_image="${DEEPSQL_BACKEND_IMAGE}"
  if ! docker manifest inspect "$test_image" >/dev/null 2>&1; then
    echo "Error: cannot access Docker images from the registry." >&2
    echo "Run:  echo '<YOUR_TOKEN>' | docker login ghcr.io -u <USERNAME> --password-stdin" >&2
    exit 1
  fi
}

wait_for_http() {
  local url="$1"
  local label="$2"
  local retries="${3:-90}"
  local delay="${4:-2}"
  for ((i=1; i<=retries; i++)); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      echo "$label is healthy: $url"
      return 0
    fi
    sleep "$delay"
  done
  echo "Error: timed out waiting for $label at $url" >&2
  return 1
}

ensure_scheduler_table() {
  local sql_file="$ROOT_DIR/docker/postgres/init/01_create_scheduled_tasks.sql"
  if [[ ! -f "$sql_file" ]]; then
    echo "Error: missing scheduler bootstrap SQL at $sql_file" >&2
    exit 1
  fi

  compose exec -T postgres psql -U postgres -d dba_agent -v ON_ERROR_STOP=1 < "$sql_file" >/dev/null
  echo "Ensured db-scheduler table exists in the vault database."
}

compose() {
  docker compose \
    --project-name "$PROJECT_NAME" \
    --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" \
    "$@"
}

bootstrap_admin() {
  if [[ "${SECURITY_ADMIN_BOOTSTRAP_ENABLED:-false}" != "true" ]]; then
    return 0
  fi

  if [[ -z "${ADMIN_BOOTSTRAP_SECRET:-}" || -z "${DEEPSQL_INITIAL_ADMIN_PASSWORD:-}" || -z "${DEEPSQL_INITIAL_ADMIN_EMAIL:-}" ]]; then
    echo "Admin bootstrap enabled, but DEEPSQL_INITIAL_ADMIN_EMAIL / DEEPSQL_INITIAL_ADMIN_PASSWORD / ADMIN_BOOTSTRAP_SECRET are not all set. Skipping bootstrap."
    return 0
  fi

  local payload
  payload="$(printf '{\"email\":\"%s\",\"password\":\"%s\"}' \
    "${DEEPSQL_INITIAL_ADMIN_EMAIL}" \
    "${DEEPSQL_INITIAL_ADMIN_PASSWORD}")"
  local response
  response="$(printf '%s' "$payload" | compose exec -T \
    -e ADMIN_BOOTSTRAP_SECRET="${ADMIN_BOOTSTRAP_SECRET}" \
    backend sh -lc \
    'curl -fsS -H "Content-Type: application/json" -H "X-Admin-Bootstrap-Secret: ${ADMIN_BOOTSTRAP_SECRET}" -X POST http://localhost:8080/api/users/admin/reset --data @-' || true)"

  if [[ "$response" == *"Admin reset successfully"* || "$response" == *"Admin created successfully"* ]]; then
    echo "Admin bootstrap complete. Login username: admin"
  else
    echo "Warning: admin bootstrap did not return a success message." >&2
    echo "$response" >&2
  fi
}

pull_application_images() {
  if [[ "${DEEPSQL_SKIP_IMAGE_PULL:-false}" == "true" ]]; then
    ensure_local_image "${DEEPSQL_BACKEND_IMAGE}"
    ensure_local_image "${DEEPSQL_FRONTEND_IMAGE}"
    echo "Skipping image pull because DEEPSQL_SKIP_IMAGE_PULL=true."
    return 0
  fi

  echo "Pulling DeepSQL application images..."
  compose pull backend frontend
}

require_command docker
require_command curl

docker compose version >/dev/null 2>&1 || {
  echo "Error: docker compose is required." >&2
  exit 1
}

if [[ ! -f "$ENV_FILE" ]]; then
  cp "$ROOT_DIR/.env.example" "$ENV_FILE"
  echo "Created $ENV_FILE from .env.example. Fill in the required values and rerun this script."
  exit 1
fi

# shellcheck disable=SC1090
set -a
source "$ENV_FILE"
set +a

# Auto-generate security secrets if still placeholders
generate_secret SECURITY_JWT_SECRET "openssl rand -base64 64 | tr -d '\n'"
generate_secret ENCRYPTION_KEY "openssl rand -base64 32 | tr -d '\n'"
generate_secret DB_PASSWORD "openssl rand -base64 16 | tr -d '\n'"

# Prompt for Azure keys if still placeholders
prompt_env_value AZURE_OPENAI_KEY "Azure OpenAI key"
prompt_env_value AZURE_OPENAI_ENDPOINT "Azure OpenAI endpoint (e.g. https://your-resource.cognitiveservices.azure.com/)"

: "${SPRING_PROFILES_ACTIVE:=prod}"
: "${DEEPSQL_FRONTEND_PORT:=3000}"
: "${DEEPSQL_BACKEND_PORT:=8080}"
: "${DEEPSQL_POSTGRES_PORT:=5432}"
: "${DEEPSQL_VALKEY_PORT:=6379}"
: "${DEEPSQL_SKIP_IMAGE_PULL:=false}"
: "${CORS_ALLOWED_ORIGINS:=http://localhost:${DEEPSQL_FRONTEND_PORT}}"

if [[ "${VECTOR_STORE_TYPE:-pgvector}" == "pgvector" && -z "${SPRING_AUTOCONFIGURE_EXCLUDE:-}" ]]; then
  SPRING_AUTOCONFIGURE_EXCLUDE="org.springframework.ai.vectorstore.azure.autoconfigure.AzureVectorStoreAutoConfiguration"
fi

export SPRING_PROFILES_ACTIVE
export DEEPSQL_FRONTEND_PORT
export DEEPSQL_BACKEND_PORT
export DEEPSQL_POSTGRES_PORT
export DEEPSQL_VALKEY_PORT
export DEEPSQL_SKIP_IMAGE_PULL
export CORS_ALLOWED_ORIGINS
export SPRING_AUTOCONFIGURE_EXCLUDE

require_env_value DEEPSQL_BACKEND_IMAGE
require_env_value DEEPSQL_FRONTEND_IMAGE
require_env_value SECURITY_JWT_SECRET
require_env_value ENCRYPTION_KEY
require_env_value ENCRYPTION_KEY_ID
require_env_value DB_PASSWORD
require_env_value AZURE_OPENAI_KEY
require_env_value AZURE_OPENAI_ENDPOINT

if [[ "${VECTOR_STORE_TYPE:-pgvector}" == "azure" || "${AZURE_SEARCH_ENABLED:-false}" == "true" ]]; then
  require_env_value AZURE_SEARCH_ENDPOINT
  require_env_value AZURE_SEARCH_API_KEY
  require_env_value AZURE_SEARCH_INDEX_NAME
fi

check_registry_access
echo "Starting DeepSQL self-hosted stack with project '$PROJECT_NAME'..."
pull_application_images
compose up -d

ensure_scheduler_table
wait_for_http "http://localhost:${DEEPSQL_BACKEND_PORT}/api/actuator/health" "Backend"
wait_for_http "http://localhost:${DEEPSQL_FRONTEND_PORT}" "Frontend"

bootstrap_admin

echo

echo "DeepSQL self-hosted stack is ready."
echo "Frontend: http://localhost:${DEEPSQL_FRONTEND_PORT}"
echo "Backend:  http://localhost:${DEEPSQL_BACKEND_PORT}/api"
echo "Project:  $PROJECT_NAME"
echo "Backend image:  ${DEEPSQL_BACKEND_IMAGE}"
echo "Frontend image: ${DEEPSQL_FRONTEND_IMAGE}"
echo

echo "Useful commands:"
echo "  ./scripts/status.sh"
echo "  ./scripts/smoke-test.sh"
echo "  ./scripts/uninstall.sh"
