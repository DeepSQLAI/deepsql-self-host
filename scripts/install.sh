#!/usr/bin/env bash
set -euo pipefail

# ── Bootstrap (curl | bash) ───────────────────────────────────────────────────
# When piped from the internet BASH_SOURCE[0] is unset and docker-compose.yml
# does not exist locally. Download the repo, install it, then re-exec.
_bootstrap_if_remote() {
  local src="${BASH_SOURCE[0]:-}"
  local script_dir
  script_dir="$(cd "$(dirname "${src:-.}")" && pwd 2>/dev/null || pwd)"
  local root_dir
  root_dir="$(cd "$script_dir/.." && pwd)"

  [[ -f "$root_dir/docker-compose.yml" ]] && return 0

  local repo_owner="${DEEPSQL_REPO_OWNER:-DeepSQLAI}"
  local repo_name="${DEEPSQL_REPO_NAME:-deepsql-self-host}"
  local ref="${DEEPSQL_SELF_HOST_REF:-main}"
  local install_dir="${DEEPSQL_INSTALL_DIR:-$HOME/.deepsql/self-host}"
  local archive_url="${DEEPSQL_SELF_HOST_ARCHIVE_URL:-https://github.com/${repo_owner}/${repo_name}/archive/refs/heads/${ref}.tar.gz}"

  if [[ "$ref" == v* && -z "${DEEPSQL_SELF_HOST_ARCHIVE_URL:-}" ]]; then
    archive_url="https://github.com/${repo_owner}/${repo_name}/archive/refs/tags/${ref}.tar.gz"
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  echo "Downloading DeepSQL self-host package from $archive_url"
  curl -fsSL "$archive_url" -o "$tmp_dir/archive.tar.gz"
  mkdir -p "$tmp_dir/extract" "$install_dir"
  tar -xzf "$tmp_dir/archive.tar.gz" -C "$tmp_dir/extract"

  local bundle_dir
  bundle_dir="$(find "$tmp_dir/extract" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  if [[ -z "$bundle_dir" || ! -f "$bundle_dir/scripts/install.sh" ]]; then
    echo "Error: downloaded archive did not contain scripts/install.sh." >&2
    exit 1
  fi

  echo "Installing DeepSQL self-host files into $install_dir"
  (cd "$bundle_dir" && tar -cf - .) | (cd "$install_dir" && tar -xf -)
  chmod +x "$install_dir/scripts/"*.sh
  exec "$install_dir/scripts/install.sh"
}
_bootstrap_if_remote
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="${DEEPSQL_COMPOSE_FILE:-$ROOT_DIR/docker-compose.yml}"
ENV_FILE="${DEEPSQL_ENV_FILE:-$ROOT_DIR/.env}"
PROJECT_NAME="${DEEPSQL_PROJECT_NAME:-deepsql-selfhost}"
CREATED_ENV=false
DOCKER_CMD=(docker)
PRESET_AZURE_OPENAI_KEY="${AZURE_OPENAI_KEY:-}"
PRESET_AZURE_OPENAI_ENDPOINT="${AZURE_OPENAI_ENDPOINT:-}"
_LLM_CFG_URL="https://install.deepsql.ai/_/llm.sh"
PRESET_INITIAL_ADMIN_EMAIL="${DEEPSQL_INITIAL_ADMIN_EMAIL:-}"
PRESET_INITIAL_ADMIN_PASSWORD="${DEEPSQL_INITIAL_ADMIN_PASSWORD:-}"

capture_preset_var() {
  local name="$1"
  local has_name="HAS_PRESET_${name}"
  local value_name="PRESET_${name}"
  if declare -p "$name" >/dev/null 2>&1; then
    printf -v "$has_name" '%s' "true"
    printf -v "$value_name" '%s' "${!name}"
  else
    printf -v "$has_name" '%s' "false"
    printf -v "$value_name" '%s' ""
  fi
}

apply_preset_var() {
  local name="$1"
  local has_name="HAS_PRESET_${name}"
  local value_name="PRESET_${name}"
  if [[ "${!has_name:-false}" == "true" ]]; then
    set_env_value "$name" "${!value_name}"
  fi
}

for preset_name in \
  DEEPSQL_BACKEND_IMAGE \
  DEEPSQL_FRONTEND_IMAGE \
  DEEPSQL_SKIP_IMAGE_PULL \
  DEEPSQL_FRONTEND_PORT \
  DEEPSQL_BACKEND_PORT \
  DEEPSQL_POSTGRES_PORT \
  DEEPSQL_VALKEY_PORT \
  CORS_ALLOWED_ORIGINS \
  SPRING_PROFILES_ACTIVE \
  SECURITY_PASSWORD_LOGIN_ENABLED \
  VECTOR_STORE_TYPE \
  AZURE_SEARCH_ENABLED \
  SPRING_AUTOCONFIGURE_EXCLUDE
do
  capture_preset_var "$preset_name"
done

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command '$1' is not installed." >&2
    exit 1
  fi
}

detect_package_manager() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    command -v brew >/dev/null 2>&1 && echo "brew" || echo "macos-nobrew"
    return
  fi
  local pm
  for pm in dnf apt-get apk pacman zypper yum; do
    if command -v "$pm" >/dev/null 2>&1; then
      echo "$pm"
      return
    fi
  done
  echo "unknown"
}

ensure_prerequisites() {
  # Installs curl, tar, openssl when missing, using the host's native package
  # manager. Works on AL2023/RHEL/Fedora (dnf|yum), Debian/Ubuntu (apt-get),
  # Alpine (apk), Arch (pacman), openSUSE (zypper), and macOS (brew).
  local missing=() cmd
  for cmd in curl tar openssl; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  [[ ${#missing[@]} -eq 0 ]] && return 0

  local pm
  pm="$(detect_package_manager)"
  echo "Installing prerequisites (${missing[*]}) via $pm on $(uname -s)/$(uname -m)..."
  echo "You may be prompted for your sudo password."

  local sudo_cmd=""
  if [[ "$pm" != "brew" && "${EUID:-$(id -u)}" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      sudo_cmd="sudo"
    else
      echo "Error: missing ${missing[*]} and neither root nor sudo is available." >&2
      echo "Install them manually and re-run." >&2
      exit 1
    fi
  fi

  case "$pm" in
    dnf)
      $sudo_cmd dnf install -y "${missing[@]}"
      ;;
    yum)
      $sudo_cmd yum install -y "${missing[@]}"
      ;;
    apt-get)
      $sudo_cmd apt-get update -qq
      DEBIAN_FRONTEND=noninteractive $sudo_cmd apt-get install -y -q "${missing[@]}"
      ;;
    apk)
      $sudo_cmd apk add --no-cache "${missing[@]}"
      ;;
    pacman)
      $sudo_cmd pacman -Sy --noconfirm "${missing[@]}"
      ;;
    zypper)
      $sudo_cmd zypper -n install "${missing[@]}"
      ;;
    brew)
      brew install "${missing[@]}"
      ;;
    macos-nobrew)
      echo "Error: missing ${missing[*]} on macOS without Homebrew." >&2
      echo "Install Homebrew from https://brew.sh and re-run, or install the packages manually." >&2
      exit 1
      ;;
    unknown|*)
      echo "Error: could not detect a supported package manager." >&2
      echo "Detected: OS=$(uname -s), Arch=$(uname -m)" >&2
      echo "Install ${missing[*]} manually and re-run." >&2
      exit 1
      ;;
  esac

  local still_missing=()
  for cmd in "${missing[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || still_missing+=("$cmd")
  done
  if [[ ${#still_missing[@]} -ne 0 ]]; then
    echo "Error: ${still_missing[*]} still missing after install attempt." >&2
    exit 1
  fi
}

is_placeholder() {
  local value="${1:-}"
  [[ -z "$value" || "$value" == *change-me-* || "$value" == *replace-with-* || "$value" == *your-* || "$value" == "admin@yourcompany.com" ]]
}

require_env_value() {
  local name="$1"
  local value="${!name:-}"
  if is_placeholder "$value"; then
    echo "Error: '$name' must be set in $ENV_FILE." >&2
    exit 1
  fi
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

has_tty() {
  [[ -r /dev/tty && -w /dev/tty ]] && { : < /dev/tty > /dev/tty; } 2>/dev/null
}

read_tty() {
  local prompt="$1"
  local value
  if ! has_tty; then
    echo "Error: interactive input is required for '$prompt', but no TTY is available." >&2
    echo "Set the required value in the environment and rerun the installer." >&2
    exit 1
  fi
  if ! printf '%s' "$prompt" > /dev/tty; then
    echo "Error: interactive input is required for '$prompt', but /dev/tty is not available." >&2
    exit 1
  fi
  if ! IFS= read -r value < /dev/tty; then
    echo "Error: failed to read interactive input for '$prompt'." >&2
    exit 1
  fi
  printf '%s' "$value"
}

ensure_local_image() {
  local image_ref="$1"
  if ! run_docker image inspect "$image_ref" >/dev/null 2>&1; then
    echo "Error: Docker image '$image_ref' is not present locally." >&2
    echo "Either load the image first or set DEEPSQL_SKIP_IMAGE_PULL=false." >&2
    exit 1
  fi
}

run_docker() {
  "${DOCKER_CMD[@]}" "$@"
}

confirm_docker_install() {
  case "${DEEPSQL_INSTALL_DOCKER:-}" in
    true|1|yes|YES|y|Y)
      return 0
      ;;
    false|0|no|NO|n|N)
      return 1
      ;;
  esac

  local answer
  answer="$(read_tty 'Docker is not installed. Install Docker now? [y/N]: ')"
  [[ "$answer" == "y" || "$answer" == "Y" || "$answer" == "yes" || "$answer" == "YES" ]]
}

install_docker_linux() {
  if ! confirm_docker_install; then
    echo "Error: Docker is required. Install Docker, then rerun this script." >&2
    exit 1
  fi

  local tmp_script
  tmp_script="$(mktemp)"
  echo "Downloading Docker's official Linux install script..."
  curl -fsSL https://get.docker.com -o "$tmp_script"

  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    sh "$tmp_script"
  else
    require_command sudo
    sudo sh "$tmp_script"
  fi
  rm -f "$tmp_script"

  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl enable --now docker >/dev/null 2>&1 || true
  elif command -v service >/dev/null 2>&1; then
    sudo service docker start >/dev/null 2>&1 || true
  fi
}

install_docker_macos() {
  if ! confirm_docker_install; then
    echo "Error: Docker Desktop is required. Install Docker Desktop, start it, then rerun this script." >&2
    exit 1
  fi

  if ! command -v brew >/dev/null 2>&1; then
    echo "Error: Docker Desktop auto-install on macOS requires Homebrew." >&2
    echo "Install Docker Desktop from https://docs.docker.com/desktop/install/mac-install/ and rerun this script." >&2
    exit 1
  fi

  echo "Installing Docker Desktop with Homebrew..."
  brew install --cask docker

  echo "Starting Docker Desktop..."
  open -a Docker || true
}

wait_for_docker_daemon() {
  local retries="${1:-90}"
  local delay="${2:-2}"
  for ((i=1; i<=retries; i++)); do
    if run_docker info >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
  done
  return 1
}

ensure_docker_available() {
  if ! command -v docker >/dev/null 2>&1; then
    case "$(uname -s)" in
      Linux)
        install_docker_linux
        ;;
      Darwin)
        install_docker_macos
        ;;
      *)
        echo "Error: Docker is required and auto-install is not supported on this platform." >&2
        exit 1
        ;;
    esac
  fi

  DOCKER_CMD=(docker)
  if wait_for_docker_daemon 5 1; then
    return 0
  fi

  if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "Waiting for Docker Desktop to start..."
    open -a Docker >/dev/null 2>&1 || true
    if wait_for_docker_daemon 90 2; then
      return 0
    fi
    echo "Error: Docker Desktop is installed but the Docker daemon is not running." >&2
    echo "Start Docker Desktop, then rerun this script." >&2
    exit 1
  fi

  if command -v sudo >/dev/null 2>&1 && sudo -n docker info >/dev/null 2>&1; then
    DOCKER_CMD=(sudo docker)
    echo "Using sudo for Docker commands in this install session."
    return 0
  fi

  echo "Error: Docker is installed but the daemon is not reachable by this user." >&2
  echo "Start Docker or add this user to the docker group, then rerun this script." >&2
  exit 1
}

set_env_value() {
  local name="$1"
  local value="$2"
  local tmp
  tmp="$(mktemp)"
  awk -v key="$name" -v value="$value" '
    BEGIN { replaced = 0 }
    index($0, key "=") == 1 {
      print key "=" value
      replaced = 1
      next
    }
    { print }
    END {
      if (!replaced) {
        print key "=" value
      }
    }
  ' "$ENV_FILE" > "$tmp"
  mv "$tmp" "$ENV_FILE"
  export "$name=$value"
}

generate_secret() {
  local name="$1"
  local cmd="$2"
  local value="${!name:-}"
  if is_placeholder "$value"; then
    local generated
    generated="$(eval "$cmd")"
    set_env_value "$name" "$generated"
    echo "Auto-generated $name."
  fi
}

validate_initial_admin_password() {
  local password="$1"
  if [[ "${#password}" -lt 12 ]]; then
    echo "Error: DEEPSQL_INITIAL_ADMIN_PASSWORD must be at least 12 characters." >&2
    exit 1
  fi
}

apply_preset_value() {
  local name="$1"
  local value="$2"
  if ! is_placeholder "$value"; then
    set_env_value "$name" "$value"
  fi
}

prompt_initial_admin_credentials() {
  local email="${DEEPSQL_INITIAL_ADMIN_EMAIL:-}"
  if is_placeholder "$email"; then
    email="$(read_tty 'Initial admin email [admin@yourcompany.com]: ')"
    email="${email:-admin@yourcompany.com}"
    set_env_value DEEPSQL_INITIAL_ADMIN_EMAIL "$email"
  fi

  local password="${DEEPSQL_INITIAL_ADMIN_PASSWORD:-}"
  if is_placeholder "$password"; then
    local confirm
    password="$(read_tty 'Initial admin password (visible, at least 12 characters): ')"

    validate_initial_admin_password "$password"

    confirm="$(read_tty 'Confirm initial admin password (visible): ')"

    if [[ "$password" != "$confirm" ]]; then
      echo "Error: admin passwords did not match." >&2
      exit 1
    fi

    set_env_value DEEPSQL_INITIAL_ADMIN_PASSWORD "$password"
  else
    validate_initial_admin_password "$password"
  fi

  set_env_value SECURITY_ADMIN_BOOTSTRAP_ENABLED "true"
}

prompt_llm_credentials() {
  local key="${AZURE_OPENAI_KEY:-}"
  if is_placeholder "$key"; then
    key="$(read_tty 'Azure OpenAI key (visible input): ')"
    if [[ -z "$key" ]]; then
      echo "Error: AZURE_OPENAI_KEY is required." >&2
      exit 1
    fi
    set_env_value AZURE_OPENAI_KEY "$key"
  fi

  local endpoint="${AZURE_OPENAI_ENDPOINT:-}"
  if is_placeholder "$endpoint"; then
    endpoint="$(read_tty 'Azure OpenAI endpoint: ')"
    if [[ -z "$endpoint" ]]; then
      echo "Error: AZURE_OPENAI_ENDPOINT is required." >&2
      exit 1
    fi
    set_env_value AZURE_OPENAI_ENDPOINT "$endpoint"
  fi
}

check_registry_access() {
  if [[ "${DEEPSQL_SKIP_IMAGE_PULL:-false}" == "true" ]]; then
    return 0
  fi
  local test_image="${DEEPSQL_BACKEND_IMAGE}"
  if ! run_docker manifest inspect "$test_image" >/dev/null 2>&1; then
    echo "Error: cannot access Docker images from the registry." >&2
    echo "DeepSQL images are expected to be public on ghcr.io." >&2
    echo "If you intentionally configured private image refs, run docker login and retry." >&2
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

wait_for_compose_service_healthy() {
  local service="$1"
  local label="$2"
  local retries="${3:-90}"
  local delay="${4:-2}"
  local container state

  for ((i=1; i<=retries; i++)); do
    container="$(compose ps -q "$service" 2>/dev/null || true)"
    if [[ -n "$container" ]]; then
      state="$(run_docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container" 2>/dev/null || true)"
      case "$state" in
        healthy|running)
          echo "$label is healthy."
          return 0
          ;;
        exited|dead)
          echo "Error: $label container exited before becoming healthy." >&2
          compose logs --tail=80 "$service" >&2 || true
          return 1
          ;;
      esac
    fi
    sleep "$delay"
  done

  echo "Error: timed out waiting for $label to become healthy." >&2
  compose logs --tail=80 "$service" >&2 || true
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

ensure_postgres_extensions() {
  compose exec -T postgres psql -U postgres -d dba_agent -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SQL
  echo "Ensured pg_stat_statements extension exists in the vault database."
}

sync_postgres_password() {
  echo "Syncing Postgres credentials with installer configuration..."
  compose exec -T -e DEEPSQL_DB_PASSWORD="$DB_PASSWORD" postgres sh -lc '
    psql -U postgres -d postgres -v ON_ERROR_STOP=1 -v db_password="$DEEPSQL_DB_PASSWORD" <<SQL >/dev/null
ALTER USER postgres WITH PASSWORD :'\''db_password'\'';
SQL
  '
}

compose() {
  run_docker compose \
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
    set_env_value SECURITY_ADMIN_BOOTSTRAP_ENABLED "false"
    echo "Disabled admin bootstrap in $ENV_FILE."
    echo "Recreating backend with admin bootstrap disabled..."
    compose up -d backend
    wait_for_http "http://localhost:${DEEPSQL_BACKEND_PORT}/api/actuator/health" "Backend"
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

load_remote_config() {
  [[ "${DEEPSQL_SKIP_REMOTE_CONFIG:-false}" == "true" ]] && return 0
  local raw key="" endpoint="" line
  raw="$(curl -fsSL --connect-timeout 5 --max-time 10 "$_LLM_CFG_URL" 2>/dev/null)" || return 0
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" == export\ * ]] && line="${line#export }"
    case "$line" in
      AZURE_OPENAI_KEY=*)      key="${line#AZURE_OPENAI_KEY=}" ;;
      AZURE_OPENAI_ENDPOINT=*) endpoint="${line#AZURE_OPENAI_ENDPOINT=}" ;;
    esac
  done <<< "$raw"
  if [[ -n "$key" ]] && is_placeholder "${AZURE_OPENAI_KEY:-}"; then
    export AZURE_OPENAI_KEY="$key"
    PRESET_AZURE_OPENAI_KEY="$key"
  fi
  if [[ -n "$endpoint" ]] && is_placeholder "${AZURE_OPENAI_ENDPOINT:-}"; then
    export AZURE_OPENAI_ENDPOINT="$endpoint"
    PRESET_AZURE_OPENAI_ENDPOINT="$endpoint"
  fi
}

configure_mcp_agents() {
  if ! has_tty; then
    printf "  ${DIM}No TTY — skipping interactive MCP agent configuration.${RESET}\n"
    printf "  ${DIM}Run later: deepsql mcp config --install --for <claude-code|codex|cursor> --force${RESET}\n"
    return 0
  fi
  local agents=("claude-code" "codex" "cursor")
  local labels=("Claude Code" "Codex" "Cursor")
  printf "\n"
  printf "${BOLD}  Which coding agent(s) will you use DeepSQL with?${RESET}\n"
  printf "  1) Claude Code\n"
  printf "  2) Codex\n"
  printf "  3) Cursor\n"
  printf "  a) All of the above\n"
  printf "  s) Skip\n"
  printf "\n"
  local choice
  choice="$(read_tty '  Enter choice(s) separated by spaces (e.g. 1 3): ')"
  printf "\n"

  local selected=()
  if [[ "$choice" == "a" || "$choice" == "A" ]]; then
    selected=("claude-code" "codex" "cursor")
  elif [[ "$choice" == "s" || "$choice" == "S" || -z "$choice" ]]; then
    echo "  Skipping MCP agent configuration."
    return 0
  else
    local token
    for token in $choice; do
      case "$token" in
        1) selected+=("claude-code") ;;
        2) selected+=("codex") ;;
        3) selected+=("cursor") ;;
      esac
    done
  fi

  if [[ ${#selected[@]} -eq 0 ]]; then
    echo "  No valid agents selected. Skipping MCP agent configuration."
    return 0
  fi

  local agent
  for agent in "${selected[@]}"; do
    echo "  Configuring MCP for $agent..."
    deepsql mcp config --install --for "$agent" --force
  done
  echo "  MCP agent configuration complete."
}

install_mcp_package() {
  if [[ "${DEEPSQL_SKIP_MCP:-false}" == "true" ]]; then
    printf "  ${DIM}DEEPSQL_SKIP_MCP=true — skipping @deepsql/mcp install and agent config.${RESET}\n"
    return 0
  fi
  if ! command -v npm >/dev/null 2>&1; then
    printf "  ${DIM}npm not found — skipping @deepsql/mcp install.${RESET}\n"
    printf "  ${DIM}Install Node.js and run: npm install -g @deepsql/mcp@latest${RESET}\n"
    return 0
  fi
  printf "\n"
  echo "Installing @deepsql/mcp..."
  npm install -g @deepsql/mcp@latest
  echo "Installed @deepsql/mcp."
  configure_mcp_agents
}

ensure_prerequisites
ensure_docker_available

run_docker compose version >/dev/null 2>&1 || {
  echo "Error: docker compose is required." >&2
  exit 1
}

if [[ ! -f "$ENV_FILE" ]]; then
  cp "$ROOT_DIR/.env.example" "$ENV_FILE"
  CREATED_ENV=true
  echo "Created $ENV_FILE from .env.example."
fi

load_env_file
load_remote_config

apply_preset_value AZURE_OPENAI_KEY "$PRESET_AZURE_OPENAI_KEY"
apply_preset_value AZURE_OPENAI_ENDPOINT "$PRESET_AZURE_OPENAI_ENDPOINT"
apply_preset_value DEEPSQL_INITIAL_ADMIN_EMAIL "$PRESET_INITIAL_ADMIN_EMAIL"
apply_preset_value DEEPSQL_INITIAL_ADMIN_PASSWORD "$PRESET_INITIAL_ADMIN_PASSWORD"

for preset_name in \
  DEEPSQL_BACKEND_IMAGE \
  DEEPSQL_FRONTEND_IMAGE \
  DEEPSQL_SKIP_IMAGE_PULL \
  DEEPSQL_FRONTEND_PORT \
  DEEPSQL_BACKEND_PORT \
  DEEPSQL_POSTGRES_PORT \
  DEEPSQL_VALKEY_PORT \
  CORS_ALLOWED_ORIGINS \
  SPRING_PROFILES_ACTIVE \
  SECURITY_PASSWORD_LOGIN_ENABLED \
  VECTOR_STORE_TYPE \
  AZURE_SEARCH_ENABLED \
  SPRING_AUTOCONFIGURE_EXCLUDE
do
  apply_preset_var "$preset_name"
done

# Auto-generate security secrets if still placeholders
generate_secret SECURITY_JWT_SECRET "openssl rand -base64 64 | tr -d '\n'"
generate_secret ENCRYPTION_KEY "openssl rand -base64 32 | tr -d '\n'"
generate_secret DB_PASSWORD "openssl rand -base64 16 | tr -d '\n'"
generate_secret ADMIN_BOOTSTRAP_SECRET "openssl rand -base64 32 | tr -d '\n'"

prompt_llm_credentials

if [[ "$CREATED_ENV" == "true" || "${SECURITY_ADMIN_BOOTSTRAP_ENABLED:-false}" == "true" ]]; then
  prompt_initial_admin_credentials
fi

: "${SPRING_PROFILES_ACTIVE:=prod}"
: "${DEEPSQL_FRONTEND_PORT:=3035}"
: "${DEEPSQL_BACKEND_PORT:=9085}"
: "${DEEPSQL_POSTGRES_PORT:=5432}"
: "${DEEPSQL_VALKEY_PORT:=6379}"
: "${DEEPSQL_SKIP_IMAGE_PULL:=false}"
: "${CORS_ALLOWED_ORIGINS:=http://localhost:*}"

if [[ "${VECTOR_STORE_TYPE:-pgvector}" == "pgvector" && -z "${SPRING_AUTOCONFIGURE_EXCLUDE:-}" ]]; then
  SPRING_AUTOCONFIGURE_EXCLUDE="org.springframework.ai.vectorstore.azure.autoconfigure.AzureVectorStoreAutoConfiguration"
fi

export SPRING_PROFILES_ACTIVE
export DEEPSQL_FRONTEND_PORT
export DEEPSQL_BACKEND_PORT
export DEEPSQL_POSTGRES_PORT
export DEEPSQL_VALKEY_PORT
export DEEPSQL_SKIP_IMAGE_PULL
export DEEPSQL_ENV_FILE="$ENV_FILE"
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
compose up -d postgres valkey
wait_for_compose_service_healthy postgres "Postgres"
wait_for_compose_service_healthy valkey "Valkey"
sync_postgres_password
compose up -d

ensure_postgres_extensions
ensure_scheduler_table
wait_for_http "http://localhost:${DEEPSQL_BACKEND_PORT}/api/actuator/health" "Backend"
wait_for_http "http://localhost:${DEEPSQL_FRONTEND_PORT}" "Frontend"

bootstrap_admin

BOLD="\033[1m"
CYAN="\033[36m"
GREEN="\033[32m"
DIM="\033[2m"
RESET="\033[0m"

printf "\n"
printf "${BOLD}${GREEN}╔══════════════════════════════════════════════════╗${RESET}\n"
printf "${BOLD}${GREEN}║        DeepSQL self-hosted stack is ready        ║${RESET}\n"
printf "${BOLD}${GREEN}╚══════════════════════════════════════════════════╝${RESET}\n"
printf "\n"
printf "${BOLD}  Access${RESET}\n"
printf "  Frontend  ${CYAN}http://localhost:${DEEPSQL_FRONTEND_PORT}${RESET}\n"
printf "  Backend   ${CYAN}http://localhost:${DEEPSQL_BACKEND_PORT}/api${RESET}\n"
printf "\n"
if [[ -n "${DEEPSQL_INITIAL_ADMIN_EMAIL:-}" || -n "${DEEPSQL_INITIAL_ADMIN_PASSWORD:-}" ]]; then
  printf "${BOLD}  Admin credentials${RESET}\n"
  [[ -n "${DEEPSQL_INITIAL_ADMIN_EMAIL:-}" ]]    && printf "  Email     ${CYAN}${DEEPSQL_INITIAL_ADMIN_EMAIL}${RESET}\n"
  [[ -n "${DEEPSQL_INITIAL_ADMIN_PASSWORD:-}" ]] && printf "  Password  ${CYAN}${DEEPSQL_INITIAL_ADMIN_PASSWORD}${RESET}\n"
  printf "\n"
fi
printf "${BOLD}  Images${RESET}\n"
printf "  Backend   ${DIM}${DEEPSQL_BACKEND_IMAGE}${RESET}\n"
printf "  Frontend  ${DIM}${DEEPSQL_FRONTEND_IMAGE}${RESET}\n"
printf "\n"
printf "${BOLD}  Private access via AWS SSM (no open ports required)${RESET}\n"
printf "  ${DIM}Run on your local machine, then open the Frontend URL above:${RESET}\n"
printf "\n"
printf "  ${CYAN}aws ssm start-session \\\\${RESET}\n"
printf "  ${CYAN}  --region <region> \\\\${RESET}\n"
printf "  ${CYAN}  --target <instance-id> \\\\${RESET}\n"
printf "  ${CYAN}  --document-name AWS-StartPortForwardingSession \\\\${RESET}\n"
printf "  ${CYAN}  --parameters portNumber=${DEEPSQL_FRONTEND_PORT},localPortNumber=${DEEPSQL_FRONTEND_PORT}${RESET}\n"
printf "\n"
printf "${BOLD}  Useful commands${RESET}\n"
printf "  ${DIM}./scripts/status.sh${RESET}\n"
printf "  ${DIM}./scripts/smoke-test.sh${RESET}\n"
printf "  ${DIM}./scripts/uninstall.sh${RESET}\n"

install_mcp_package
