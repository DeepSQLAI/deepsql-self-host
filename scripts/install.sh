#!/usr/bin/env bash
set -euo pipefail

# UserData / SSM / CI often invoke this with HOME unset. The bootstrap and
# install_dir defaults below reference $HOME and would explode under `set -u`
# without this. Fall back to the OS-recorded home for the current uid, then
# /root as a final guard.
if [[ -z "${HOME:-}" ]]; then
  HOME="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 || true)"
  [[ -z "$HOME" ]] && HOME=/root
  export HOME
fi

# -- Bootstrap (curl | bash) ---------------------------------------------------
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
  # Default ref resolution order:
  #   1. DEEPSQL_SELF_HOST_REF env override (explicit pin: e.g. v1.0.0 or main)
  #   2. Latest GitHub release tag (so customers default to a stable version)
  #   3. main (fallback if the GitHub API is unreachable or there are no releases yet)
  local ref="${DEEPSQL_SELF_HOST_REF:-}"
  if [[ -z "$ref" ]]; then
    ref="$(curl -fsSL --connect-timeout 5 --max-time 10 \
      "https://api.github.com/repos/${repo_owner}/${repo_name}/releases/latest" 2>/dev/null \
      | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -1 | cut -d'"' -f4)"
    [[ -z "$ref" ]] && ref="main"
  fi
  local install_dir="${DEEPSQL_INSTALL_DIR:-$HOME/.deepsql/self-host}"
  local archive_url="${DEEPSQL_SELF_HOST_ARCHIVE_URL:-https://github.com/${repo_owner}/${repo_name}/archive/refs/heads/${ref}.tar.gz}"

  if [[ "$ref" == v* && -z "${DEEPSQL_SELF_HOST_ARCHIVE_URL:-}" ]]; then
    archive_url="https://github.com/${repo_owner}/${repo_name}/archive/refs/tags/${ref}.tar.gz"
  fi

  echo "Installing DeepSQL self-host ref: $ref"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  echo "Downloading DeepSQL self-host package from $archive_url"
  curl -fsSL "$archive_url" -o "$tmp_dir/archive.tar.gz"
  # Verify the gzip stream is intact before trusting anything inside it. A
  # truncated download passes curl (it exits 0 on a short read of a 200) but
  # produces a corrupt archive; catching it here turns a later cryptic bash
  # crash into a clear, actionable message.
  if ! gzip -t "$tmp_dir/archive.tar.gz" 2>/dev/null; then
    echo "Error: downloaded archive is corrupt (failed gzip integrity check)." >&2
    echo "This is usually a transient network issue. Please re-run the installer." >&2
    exit 1
  fi
  mkdir -p "$tmp_dir/extract" "$install_dir"
  tar -xzf "$tmp_dir/archive.tar.gz" -C "$tmp_dir/extract"

  local bundle_dir
  bundle_dir="$(find "$tmp_dir/extract" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  if [[ -z "$bundle_dir" || ! -f "$bundle_dir/scripts/install.sh" ]]; then
    echo "Error: downloaded archive did not contain scripts/install.sh." >&2
    exit 1
  fi

  echo "Installing DeepSQL self-host files into $install_dir"
  # Copy with cp -R rather than a `tar -cf - | tar -xf -` pipe. The pipe can
  # silently truncate the destination if the read side dies (SIGPIPE) on a
  # constrained host, yielding a half-written install.sh that bash then
  # exec's and crashes on (the `xrealloc: cannot allocate ...` failure mode).
  cp -R "$bundle_dir/." "$install_dir/"
  chmod +x "$install_dir/scripts/"*.sh

  # Final guard: never exec a script we cannot parse. If the on-disk install.sh
  # is somehow corrupt (partial write, bad filesystem, truncated copy), fail
  # loudly with guidance instead of exec'ing garbage and emitting an opaque
  # bash allocator error.
  if ! bash -n "$install_dir/scripts/install.sh" 2>/dev/null; then
    echo "Error: installed script failed an integrity (syntax) check at" >&2
    echo "  $install_dir/scripts/install.sh" >&2
    echo "The copy may be corrupt. Remove $install_dir and re-run the installer." >&2
    exit 1
  fi
  exec "$install_dir/scripts/install.sh"
}
_bootstrap_if_remote
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="${DEEPSQL_COMPOSE_FILE:-$ROOT_DIR/docker-compose.yml}"
ENV_FILE="${DEEPSQL_ENV_FILE:-$ROOT_DIR/.env}"
# Hardcoded, NOT read from the environment. A leaked DEEPSQL_PROJECT_NAME (or
# anything that made Compose derive the name from the directory basename) was
# the root cause of upgrade-time container/volume drift. The compose file now
# also declares `name: deepsql-selfhost`, so this and that agree as a single
# source of truth. To intentionally run a differently-named stack, pass
# `--project-name` to docker compose directly; install.sh no longer offers it
# as a tunable to avoid the footgun.
PROJECT_NAME="deepsql-selfhost"
CREATED_ENV=false
# Set to true by load_remote_config() when it injects DeepSQL's managed
# (shared) Azure OpenAI key, so the final summary can print a privacy note.
USED_MANAGED_LLM_KEY=false
DOCKER_CMD=(docker)
# Project names that reclaim_stale_project_stacks() positively identified as
# OUR stacks (full service set on DeepSQL images) and stopped. Their prefixed
# volumes are therefore our data; migrate_prefixed_volumes_if_needed() treats
# them as additional, already-vetted source prefixes so a reclaimed stack's
# data is always carried forward (never stranded behind an empty volume).
RECLAIMED_PROJECTS=""
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
  DEEPSQL_AGENT_IMAGE \
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

install_docker_compose_plugin() {
  # Docker Compose v2 ships as a CLI plugin. AL2023 doesn't have it packaged
  # under any name we can dnf-install, so we fetch the static binary from
  # the official GitHub release into the system-wide cli-plugins dir.
  local sudo_cmd="$1"
  if docker compose version >/dev/null 2>&1; then
    return 0
  fi
  echo "Installing Docker Compose v2 plugin..."
  local arch
  case "$(uname -m)" in
    aarch64|arm64) arch="aarch64" ;;
    x86_64|amd64)  arch="x86_64" ;;
    *) echo "Error: unsupported arch $(uname -m) for Compose plugin install." >&2; exit 1 ;;
  esac
  local plugin_dir="/usr/local/lib/docker/cli-plugins"
  $sudo_cmd mkdir -p "$plugin_dir"
  $sudo_cmd curl -fsSL \
    "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$arch" \
    -o "$plugin_dir/docker-compose"
  $sudo_cmd chmod +x "$plugin_dir/docker-compose"
}

install_docker_linux() {
  if ! confirm_docker_install; then
    echo "Error: Docker is required. Install Docker, then rerun this script." >&2
    exit 1
  fi

  local distro=""
  [[ -f /etc/os-release ]] && distro="$(. /etc/os-release; echo "${ID:-}")"

  local sudo_cmd=""
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    require_command sudo
    sudo_cmd="sudo"
  fi

  case "$distro" in
    amzn)
      # get.docker.com does not support Amazon Linux. Use AL2023's native
      # docker package and add the Compose plugin manually.
      echo "Installing Docker via Amazon Linux 2023 package..."
      $sudo_cmd dnf -y install docker
      if command -v systemctl >/dev/null 2>&1; then
        $sudo_cmd systemctl enable --now docker >/dev/null 2>&1 || true
      fi
      install_docker_compose_plugin "$sudo_cmd"
      ;;
    *)
      local tmp_script
      tmp_script="$(mktemp)"
      echo "Downloading Docker's official Linux install script..."
      curl -fsSL https://get.docker.com -o "$tmp_script"
      $sudo_cmd sh "$tmp_script"
      rm -f "$tmp_script"
      if command -v systemctl >/dev/null 2>&1; then
        $sudo_cmd systemctl enable --now docker >/dev/null 2>&1 || true
      elif command -v service >/dev/null 2>&1; then
        $sudo_cmd service docker start >/dev/null 2>&1 || true
      fi
      # get.docker.com bundles compose v2, but verify and install if missing
      install_docker_compose_plugin "$sudo_cmd"
      ;;
  esac
}

install_docker_macos() {
  if ! confirm_docker_install; then
    echo "Error: Docker Desktop is required. Install Docker Desktop, start it, then rerun this script." >&2
    exit 1
  fi

  if ! command -v brew >/dev/null 2>&1; then
    echo "Error: Docker Desktop auto-install on macOS requires Homebrew." >&2
    echo "Options to get a Docker runtime, then rerun this script:" >&2
    echo "  - Docker Desktop (GUI): https://docs.docker.com/desktop/install/mac-install/" >&2
    echo "  - Colima (no GUI, no license): brew install colima docker docker-compose && colima start" >&2
    echo "    (install Homebrew first from https://brew.sh)" >&2
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

ensure_compose_available() {
  # This installer drives Compose v2 via the `docker compose` subcommand
  # (see compose()). The legacy standalone `docker-compose` (v1) binary is a
  # different tool and is NOT supported. A bare "is required" error here is a
  # dead-end for someone who has v1 installed, so we try to self-heal on Linux
  # and otherwise print exact, copy-pasteable install steps.
  if run_docker compose version >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$(uname -s)" == "Linux" ]]; then
    echo "Docker Compose v2 plugin not found - attempting to install it..."
    local sudo_cmd=""
    if [[ "${EUID:-$(id -u)}" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
      sudo_cmd="sudo"
    fi
    install_docker_compose_plugin "$sudo_cmd" || true
    if run_docker compose version >/dev/null 2>&1; then
      return 0
    fi
  fi

  echo "Error: the Docker Compose v2 plugin ('docker compose') is required but not available." >&2
  echo >&2
  if command -v docker-compose >/dev/null 2>&1; then
    echo "Note: you have the legacy standalone 'docker-compose' (v1), which this" >&2
    echo "installer does NOT use. You need the v2 plugin invoked as 'docker compose'." >&2
    echo >&2
  fi
  case "$(uname -s)" in
    Darwin)
      echo "Fix: install/upgrade Docker Desktop (it bundles Compose v2):" >&2
      echo "  https://docs.docker.com/desktop/install/mac-install/" >&2
      echo "Or with Colima: brew install docker-compose && colima start" >&2
      ;;
    Linux)
      echo "Fix: install the Compose v2 plugin into your user plugin dir:" >&2
      echo "  mkdir -p ~/.docker/cli-plugins" >&2
      echo "  curl -fsSL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-\$(uname -m) \\" >&2
      echo "    -o ~/.docker/cli-plugins/docker-compose && chmod +x ~/.docker/cli-plugins/docker-compose" >&2
      echo "Docs: https://docs.docker.com/compose/install/linux/" >&2
      ;;
    *)
      echo "Fix: install the Docker Compose v2 plugin. Docs: https://docs.docker.com/compose/install/" >&2
      ;;
  esac
  exit 1
}

# Validate non-interactive inputs (env / .env / CFN / CI) BEFORE the heavy
# Docker install and image-pull steps, so a bad value fails fast instead of
# "mid-install" after Docker Desktop has already been installed and started.
# Interactive entry is validated at the prompt itself (prompt_initial_admin_*).
preflight_validate_inputs() {
  local pw="${PRESET_INITIAL_ADMIN_PASSWORD:-}"
  if ! is_placeholder "$pw"; then
    validate_initial_admin_password "$pw"
  fi
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

# Optional - labels this install in DeepSQL analytics and support views.
# If blank the backend derives company_name from the admin email domain
# (skipping freemail providers like gmail/yahoo), then falls back to
# the sentinel "unknown". Operators can edit the value in .env later
# and restart to update - but it's immutable in the backend's identity
# row, so a manual UPDATE is needed for an already-bootstrapped install.
prompt_optional_company_name() {
  local current="${DEEPSQL_COMPANY_NAME:-}"
  # If already provided non-interactively (env var, CFN, CI), persist it to
  # .env so compose passes it through to the backend container.
  if [[ -n "$current" ]]; then
    set_env_value DEEPSQL_COMPANY_NAME "$current"
    return 0
  fi
  # Optional + non-interactive-safe: skip prompt if no usable TTY (e.g. when
  # invoked via `curl | bash`). Use the same check read_tty itself uses so
  # behaviour stays consistent. Backend's email-domain fallback then derives
  # company_name automatically; operator can override later by editing .env.
  if ! has_tty; then
    return 0
  fi
  local value
  value="$(read_tty 'Company / organization name (optional, press Enter to skip): ')"
  if [[ -n "$value" ]]; then
    set_env_value DEEPSQL_COMPANY_NAME "$value"
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

# Auto-bump the image-pin lines in .env to match whatever .env.example pins to
# in the freshly-extracted release archive. Makes `curl ... | bash` a single-
# command upgrade - operators no longer have to manually sed their .env when
# moving from v1.0.x -> v1.2.x. Customer secrets, admin credentials, and
# everything else in .env are left untouched.
# Read the value of KEY=... from a file, returning empty (status 0) if the
# key is absent. CRITICAL: this must never propagate grep's no-match exit (1).
# Under `set -euo pipefail`, a bare `v="$(grep ... )"` that finds nothing
# aborts the entire installer at the assignment. The keys we promote below are
# by definition absent from the .env we promote INTO, so the naive form killed
# the installer before it could do any promotion - silently, with no output.
env_value_for() {
  local key="$1" file="$2"
  [[ -f "$file" ]] || { printf '%s' ""; return 0; }
  # `|| true` neutralizes grep's exit 1; head/cut never fail on empty input.
  grep -E "^${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2- || true
}

bump_image_pins_from_release() {
  if [[ ! -f "$ENV_FILE" || ! -f "$ROOT_DIR/.env.example" ]]; then
    return 0
  fi
  local var current target
  for var in DEEPSQL_BACKEND_IMAGE DEEPSQL_FRONTEND_IMAGE DEEPSQL_AGENT_IMAGE; do
    current="$(env_value_for "$var" "$ENV_FILE")"
    target="$(env_value_for "$var" "$ROOT_DIR/.env.example")"
    if [[ -n "$current" && -n "$target" && "$current" != "$target" ]]; then
      echo "> Upgrading ${var}: ${current} -> ${target}"
      set_env_value "$var" "$target"
    fi
  done

  # Promote new DeepSQL-managed defaults from .env.example only when the
  # customer hasn't already set their own value. Used for keys that were
  # commented-out in older releases (so existing installs predate the line)
  # and are now uncommented as a default. Skips if the .env line is present
  # and non-empty so we never clobber customer overrides.
  for var in DEEPSQL_TELEMETRY_POSTHOG_PROJECT_KEY DEEPSQL_RELEASE DEEPSQL_AGENT_IMAGE; do
    current="$(env_value_for "$var" "$ENV_FILE")"
    target="$(env_value_for "$var" "$ROOT_DIR/.env.example")"
    if [[ -n "$current" ]]; then
      echo "> ${var}: already set in .env, leaving alone"
    elif [[ -z "$target" ]]; then
      echo "> ${var}: not present in .env.example, nothing to promote"
    else
      echo "> Promoting ${var} from release default"
      set_env_value "$var" "$target"
    fi
  done
}

# Reclaim host ports held by a STALE DeepSQL stack running under a different
# Compose project name. This is the #1 cause of upgrade-time "port already
# allocated" failures: an OLD install.sh let Compose derive the project name
# from the install-dir basename ("self-host") before we pinned
# `name: deepsql-selfhost` in the compose file, so the legacy stack and the
# new one fight over the same host ports (3035/9085/5432/6379).
#
# SAFETY - we only AUTO-RECLAIM a project we can positively identify as a
# stale DeepSQL stack: it must contain the FULL service set
# (backend+frontend+postgres+valkey) AND its backend/frontend containers must
# run DeepSQL images (ref contains "deepsql-self-host"). Reclaiming removes
# that project's CONTAINERS ONLY (never `-v`, never `docker volume rm`), which
# releases the port bindings while leaving every named volume intact;
# migrate_prefixed_volumes_if_needed() then carries the data forward. A
# foreign project that touches our service names but does NOT fully match
# (e.g. an unrelated stack that merely has a service called "postgres") is
# only WARNED about and never touched - that false-positive risk is exactly
# why the previous revision was warn-only.
reclaim_stale_project_stacks() {
  local classified
  classified="$(docker ps -a \
    --filter "label=com.docker.compose.project" \
    --format '{{.Label "com.docker.compose.project"}}\t{{.Label "com.docker.compose.service"}}\t{{.Image}}' 2>/dev/null \
    | awk -v keep="$PROJECT_NAME" -F'\t' '
        $1 != "" && $1 != keep {
          proj=$1; svc=$2; img=$3
          if (svc ~ /^(backend|frontend|postgres|valkey)$/) {
            touch[proj]=1
            svcs[proj]=svcs[proj] " " svc " "
            if ((svc == "backend" || svc == "frontend") && index(img, "deepsql-self-host") > 0)
              ours[proj]=ours[proj] " " svc " "
          }
        }
        END {
          for (p in touch) {
            s=svcs[p]; o=ours[p]
            full = (index(s, " backend ") && index(s, " frontend ") && index(s, " postgres ") && index(s, " valkey "))
            mine = (index(o, " backend ") && index(o, " frontend "))
            print p "\t" ((full && mine) ? "reclaim" : "warn")
          }
        }')"

  [[ -z "$classified" ]] && return 0

  local project verdict ids
  while IFS=$'\t' read -r project verdict; do
    [[ -z "$project" ]] && continue
    if [[ "$verdict" == "reclaim" ]]; then
      echo
      echo ">> Reclaiming stale DeepSQL stack under project '${project}' to free host ports."
      echo "   Removing its containers only - named volumes (your data) are preserved."
      ids="$(docker ps -aq --filter "label=com.docker.compose.project=${project}" 2>/dev/null || true)"
      if [[ -z "$ids" ]]; then
        continue
      fi
      # DATA SAFETY - two deliberate properties here:
      #   1. GRACEFUL stop first. `docker stop` sends the image's STOPSIGNAL
      #      (SIGINT for the Postgres image = fast, clean shutdown that
      #      checkpoints and flushes) with a 30s grace period before any
      #      SIGKILL. So Postgres exits consistently BEFORE the subsequent
      #      migrate_prefixed_volumes_if_needed() may tar-copy its data dir -
      #      we never copy a volume out from under a live writer.
      #   2. CONTAINERS ONLY. We remove containers to release the host ports
      #      and names; we never pass `-v` and never run `docker volume rm`,
      #      so the named dba-agent-* volumes (the customer's data) are left
      #      fully intact. Word-split $ids deliberately (one id per line).
      # shellcheck disable=SC2086
      docker stop --time 30 $ids >/dev/null 2>&1 || true
      # shellcheck disable=SC2086
      if docker rm $ids >/dev/null 2>&1; then
        echo "   OK reclaimed project '${project}' (volumes preserved)."
        RECLAIMED_PROJECTS="${RECLAIMED_PROJECTS} ${project}"
      # Fallback: if a plain remove is refused, force-remove the now-stopped
      # containers. Still no `-v`, so volumes remain untouched.
      # shellcheck disable=SC2086
      elif docker rm -f $ids >/dev/null 2>&1; then
        echo "   OK reclaimed project '${project}' (forced; volumes preserved)."
        RECLAIMED_PROJECTS="${RECLAIMED_PROJECTS} ${project}"
      else
        echo "   !! Could not remove some containers of '${project}'." >&2
        echo "      Free the ports manually, then re-run:" >&2
        echo "        docker compose -p '${project}' down --remove-orphans" >&2
      fi
    else
      echo
      echo "!!  Found containers from a different Compose project '${project}' that use"
      echo "    our service names but do NOT look like a full DeepSQL stack on our images."
      echo "    Leaving them untouched. If \`compose up\` fails on a port collision, stop"
      echo "    them manually: docker compose -p '${project}' down --remove-orphans"
    fi
  done <<< "$classified"
  echo
}

# True (exit 0) if the named Docker volume contains real content - anything
# beyond an empty dir or a bare lost+found. Used to tell "already-populated"
# volumes (never clobber) from "exists but empty" ones (safe to fill). Mounts
# read-only, so it can never alter the volume it inspects.
volume_has_data() {
  local vol="$1" content
  content="$(docker run --rm -v "${vol}:/v:ro" alpine \
    sh -c 'ls -A /v 2>/dev/null | grep -v "^lost+found$" | head -1' 2>/dev/null || true)"
  [[ -n "$content" ]]
}

# Is this logical volume irreplaceable user data (vs. reconstructable cache or
# logs)? Only the Postgres volume holds the relational database - user config,
# slow-log sources, everything. A fork there is fatal; cache/log forks are not.
is_precious_volume() { [[ "$1" == "dba-agent-postgres" ]]; }

# Human-readable size of a named volume (read-only mount; never alters it).
volume_size_human() {
  docker run --rm -v "${1}:/v:ro" alpine sh -c 'du -sh /v 2>/dev/null | cut -f1' 2>/dev/null || echo "?"
}

# Classify the legacy migration source for one logical volume. Emits one of:
#   none\t                 - no populated legacy candidate
#   single\t<volume>       - exactly one populated candidate, OR an explicit
#                            override via DEEPSQL_VOLUME_SOURCE_<logical>
#   fork\t<v1>,<v2>,...     - TWO OR MORE populated candidates. Ambiguous: the
#                            caller must NOT auto-pick. You cannot merge two
#                            Postgres clusters, so silently choosing one drops
#                            the other - the exact data-loss this guards against
#                            (a client lost slow_log_source_config this way when
#                            both deepsql-selfhost_* and self-host_* were full).
#   badoverride\t<volume>  - an override was set but names a missing/empty vol
# Candidates: the canonical project name, this install dir's basename, and any
# project reclaim_stale_project_stacks() stopped (RECLAIMED_PROJECTS) - the only
# names our own stack could have produced.
classify_migration_source() {
  local logical_name="$1"
  local install_basename override_var override
  install_basename="$(basename "$ROOT_DIR")"

  # Explicit operator override resolves a fork deterministically.
  override_var="DEEPSQL_VOLUME_SOURCE_${logical_name//-/_}"
  override="${!override_var:-}"
  if [[ -n "$override" ]]; then
    if docker volume inspect "$override" >/dev/null 2>&1 && volume_has_data "$override"; then
      printf 'single\t%s\n' "$override"
    else
      printf 'badoverride\t%s\n' "$override"
    fi
    return 0
  fi

  local -a prefixes=("$PROJECT_NAME" "$install_basename")
  local rp
  for rp in $RECLAIMED_PROJECTS; do
    prefixes+=("$rp")
  done

  local -a populated=()
  local candidate seen=""
  for candidate in "${prefixes[@]/%/_${logical_name}}"; do
    [[ "$candidate" == "${logical_name}" ]] && continue          # guard if a prefix were empty
    case ",${seen}," in *",${candidate},"*) continue ;; esac     # dedup repeated prefixes
    seen="${seen:+${seen},}${candidate}"
    if docker volume inspect "$candidate" >/dev/null 2>&1 && volume_has_data "$candidate"; then
      populated+=("$candidate")
    fi
  done

  case ${#populated[@]} in
    0) printf 'none\t\n' ;;
    1) printf 'single\t%s\n' "${populated[0]}" ;;
    *) local IFS=','; printf 'fork\t%s\n' "${populated[*]}" ;;
  esac
}

# One-shot migration from Compose-prefixed volumes (legacy) to absolute
# volume names (current). v1.3.3+ docker-compose.yml declares
#   dba-agent-postgres / dba-agent-valkey / dba-agent-logs
# as absolute volume names so customer data survives project-name drift.
# Customers upgrading from <=1.3.2 have prefixed volumes like
# deepsql-selfhost_dba-agent-postgres holding their real data, and an empty
# new absolute volume would otherwise look like a fresh install. Copy the
# contents over once (old volume is preserved read-only as a safety net).
migrate_prefixed_volumes_if_needed() {
  # Only ever migrate from volumes belonging to THIS install - i.e. prefixed
  # with the canonical project name or with this install dir's basename (the
  # only two names that have ever been used for our stack). A broad
  # "*_dba-agent-postgres" search is dangerous: it can grab an unrelated
  # Compose project that happens to use the same logical volume name and copy
  # the wrong stack's data into ours.
  local logical_name decision verdict source_volume v
  for logical_name in dba-agent-postgres dba-agent-valkey dba-agent-logs; do
    # Decide whether the absolute (destination) volume can receive data:
    #   exists + HAS DATA -> already migrated, or a real current install.
    #                        Never clobber it. But if populated LEGACY volumes
    #                        also exist they were NOT merged in - surface them
    #                        so an operator on an already-forked install isn't
    #                        left thinking data vanished.
    #   exists + EMPTY    -> a stray/auto-created blank volume that would
    #                        otherwise SHADOW legacy data and make the upgraded
    #                        stack look like a fresh (empty) install. Drop it,
    #                        then populate from the legacy source below.
    #   absent            -> create + populate.
    if docker volume inspect "$logical_name" >/dev/null 2>&1; then
      if volume_has_data "$logical_name"; then
        decision="$(classify_migration_source "$logical_name")"
        case "${decision%%$'\t'*}" in
          single|fork)
            echo
            echo "!! ${logical_name} already has data and was kept as-is, but populated"
            echo "   legacy volume(s) also exist and were NOT merged: ${decision#*$'\t'}"
            echo "   Nothing was deleted. If data looks missing, inspect those volumes and"
            echo "   copy what you need - Compose data dirs cannot be auto-merged."
            ;;
        esac
        continue
      fi
      echo
      echo "> Absolute volume ${logical_name} exists but is EMPTY - it would"
      echo "  otherwise shadow legacy data and look like a fresh install."
      # Drop the empty volume so the fresh copy below is created clean (avoids a
      # noisy "created for project X (expected Y)" Compose warning). Safe:
      # volume_has_data() just confirmed it holds nothing.
      docker volume rm "$logical_name" >/dev/null 2>&1 || true
    fi

    decision="$(classify_migration_source "$logical_name")"
    verdict="${decision%%$'\t'*}"
    source_volume="${decision#*$'\t'}"

    if [[ "$verdict" == "none" ]]; then
      continue
    fi

    if [[ "$verdict" == "badoverride" ]]; then
      echo >&2
      echo "XX DEEPSQL_VOLUME_SOURCE_${logical_name//-/_} names '${source_volume}'," >&2
      echo "   but that volume is missing or empty. Fix the override and re-run." >&2
      exit 1
    fi

    if [[ "$verdict" == "fork" ]]; then
      # TWO+ populated legacy volumes. We refuse to silently pick one and drop
      # the rest - that is the data-loss a client hit. List them so the operator
      # can choose.
      echo >&2
      echo "XX Found MULTIPLE populated legacy volumes for ${logical_name}:" >&2
      # shellcheck disable=SC2086
      for v in ${source_volume//,/ }; do
        printf '      %-46s %s\n' "$v" "$(volume_size_human "$v")" >&2
      done
      if is_precious_volume "$logical_name"; then
        echo "   Refusing to auto-pick one and discard the rest - that would lose data" >&2
        echo "   (Postgres data dirs cannot be merged). Re-run with the authoritative" >&2
        echo "   source pinned, e.g.:" >&2
        echo >&2
        echo "     DEEPSQL_VOLUME_SOURCE_${logical_name//-/_}='<chosen-volume>' \\" >&2
        echo "       curl -fsSL https://install.deepsql.ai/install.sh | bash" >&2
        echo >&2
        echo "   No volume was modified or deleted." >&2
        exit 1
      fi
      # Cache/log volume: a fork is low-stakes (reconstructable). Use the
      # canonical-priority candidate (first listed) and continue.
      source_volume="${source_volume%%,*}"
      echo "   ${logical_name} is a cache/log volume; using ${source_volume} (low risk)." >&2
    fi

    # verdict is "single", or a resolved non-precious fork: copy the source.
    echo
    echo "> Migrating volume data: ${source_volume} -> ${logical_name}"
    echo "  (old volume preserved untouched as a rollback safety net)"
    docker volume create "$logical_name" >/dev/null
    if ! docker run --rm \
        -v "${source_volume}:/from:ro" \
        -v "${logical_name}:/to" \
        alpine sh -c 'cd /from && tar cf - . | (cd /to && tar xf -)' 2>&1; then
      echo "  XX Volume copy failed. Aborting before \`compose up\` to avoid"
      echo "     attaching an inconsistent volume. Remove the partial copy with:"
      echo "       docker volume rm ${logical_name}"
      echo "     The original ${source_volume} is intact."
      exit 1
    fi
    echo "  OK ${logical_name} now mirrors ${source_volume}"
  done
}

# Print a clear final status if install.sh exits non-zero AFTER we already
# bumped image pins or promoted telemetry defaults. Without this, a customer
# whose post-pin step fails (transient network blip on docker pull, health
# probe timeout, etc.) is left with mismatched .env vs running containers
# and no clear signal that the upgrade was partial.
_INSTALL_PROGRESS="pre-bump"
on_install_exit() {
  local code=$?
  if [[ $code -ne 0 && "$_INSTALL_PROGRESS" == "post-bump" ]]; then
    echo
    echo "XX Upgrade exited with code ${code} AFTER .env image pins were bumped."
    echo "   .env now references the new images but containers may not have"
    echo "   been restarted. Recover with:"
    echo
    echo "     cd '$ROOT_DIR' && docker compose --project-name '$PROJECT_NAME' \\"
    echo "       --env-file '$ENV_FILE' up -d"
    echo
    echo "   Or re-run \`curl -fsSL https://install.deepsql.ai/install.sh | bash\`."
    echo
  fi
  exit $code
}
trap on_install_exit EXIT

pull_application_images() {
  if [[ "${DEEPSQL_SKIP_IMAGE_PULL:-false}" == "true" ]]; then
    ensure_local_image "${DEEPSQL_BACKEND_IMAGE}"
    ensure_local_image "${DEEPSQL_FRONTEND_IMAGE}"
    ensure_local_image "${DEEPSQL_AGENT_IMAGE}"
    echo "Skipping image pull because DEEPSQL_SKIP_IMAGE_PULL=true."
    return 0
  fi

  echo "Pulling DeepSQL application images..."
  compose pull backend frontend deepsql-agent
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
    USED_MANAGED_LLM_KEY=true
  fi
  if [[ -n "$endpoint" ]] && is_placeholder "${AZURE_OPENAI_ENDPOINT:-}"; then
    export AZURE_OPENAI_ENDPOINT="$endpoint"
    PRESET_AZURE_OPENAI_ENDPOINT="$endpoint"
  fi
}

auto_install_for_detected_agents() {
  # Headless path: detect which coding agents are installed on the host and
  # install the DeepSQL MCP config + DBA-consult skill for each. Used when
  # there's no TTY to drive the interactive picker (curl|bash from a script,
  # CFN UserData with a developer host, etc.). Idempotent - does nothing for
  # agents that aren't present.
  local installed=()
  [[ -f "$HOME/.claude.json" || -d "$HOME/.claude" ]] && installed+=("claude-code")
  [[ -d "$HOME/.codex" ]]  && installed+=("codex")
  [[ -d "$HOME/.cursor" ]] && installed+=("cursor")

  if [[ ${#installed[@]} -eq 0 ]]; then
    printf "  ${DIM}No coding agents detected on host - skipping MCP config + skill install.${RESET}\n"
    printf "  ${DIM}After installing an agent, run: deepsql mcp config --install --for <agent> --force${RESET}\n"
    return 0
  fi

  printf "  Detected coding agents: %s\n" "${installed[*]}"
  printf "  Installing DeepSQL MCP config + DBA-consult skill for each...\n"
  local agent
  for agent in "${installed[@]}"; do
    if deepsql mcp config --install --for "$agent" --force; then
      echo "  OK $agent configured"
    else
      printf "  ${DIM}  $agent config failed - run manually: deepsql mcp config --install --for $agent --force${RESET}\n"
    fi
  done
}

configure_mcp_agents() {
  if ! has_tty; then
    auto_install_for_detected_agents
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

login_deepsql_cli() {
  # Authorizes the global `deepsql` CLI with the local self-host instance
  # using the admin credentials we just bootstrapped. Persists a long-lived
  # MCP token to ~/.config/deepsql so subsequent `deepsql mcp` invocations
  # (run by Claude Code / Codex / Cursor) work without re-auth.
  #
  # Skipped quietly if admin creds aren't available in env (e.g. a re-run
  # where the user already cleared them) - they can always re-run manually.
  if [[ -z "${DEEPSQL_INITIAL_ADMIN_EMAIL:-}" || -z "${DEEPSQL_INITIAL_ADMIN_PASSWORD:-}" ]]; then
    printf "  ${DIM}Admin email/password not in env - skipping deepsql CLI login.${RESET}\n"
    printf "  ${DIM}Run manually: deepsql login --password --email <admin-email> --url http://localhost:${DEEPSQL_BACKEND_PORT}${RESET}\n"
    return 0
  fi
  local label url
  label="self-host-$(hostname -s 2>/dev/null || echo local)"
  url="http://localhost:${DEEPSQL_BACKEND_PORT}"
  echo "Authorizing the deepsql CLI against the local instance..."
  if printf '%s' "${DEEPSQL_INITIAL_ADMIN_PASSWORD}" | deepsql login \
      --password \
      --email "${DEEPSQL_INITIAL_ADMIN_EMAIL}" \
      --password-stdin \
      --url "$url" \
      --label "$label"; then
    # Pin this self-host instance as the CLI's default profile. `deepsql login`
    # only auto-defaults when NO profile exists yet, so on a machine that
    # already has another profile (e.g. a prior cloud login) the new local one
    # is saved but every subsequent `deepsql`/MCP call keeps talking to the old
    # default. Make the freshly-installed instance the active profile so the
    # customer is logged in and pointed at it without any manual step.
    if deepsql config set-default "$url" >/dev/null 2>&1; then
      echo "Logged in. This instance is now the default deepsql profile."
    else
      echo "Logged in. CLI is ready for MCP use."
      printf "  ${DIM}If deepsql targets another instance, run: deepsql config set-default ${url}${RESET}\n"
    fi
  else
    printf "  ${DIM}deepsql login failed - re-run manually if needed.${RESET}\n"
    printf "  ${DIM}deepsql login --password --email ${DEEPSQL_INITIAL_ADMIN_EMAIL} --url ${url}${RESET}\n"
  fi
}

install_mcp_package() {
  if [[ "${DEEPSQL_SKIP_MCP:-false}" == "true" ]]; then
    printf "  ${DIM}DEEPSQL_SKIP_MCP=true - skipping @deepsql/mcp install and agent config.${RESET}\n"
    return 0
  fi
  if ! command -v npm >/dev/null 2>&1; then
    printf "  ${DIM}npm not found - skipping @deepsql/mcp install.${RESET}\n"
    printf "  ${DIM}Install Node.js and run: npm install -g @deepsql/mcp@latest${RESET}\n"
    return 0
  fi
  printf "\n"
  echo "Installing @deepsql/mcp..."
  npm install -g @deepsql/mcp@latest
  echo "Installed @deepsql/mcp."
  login_deepsql_cli
  configure_mcp_agents
}

preflight_validate_inputs
ensure_prerequisites
ensure_docker_available
ensure_compose_available

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
  DEEPSQL_AGENT_IMAGE \
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
# Shared secret between the backend and the DeepSQL Agent. REQUIRED for the
# agent to function: it gates the agent's per-user provisioner, which the
# backend calls (on Agent-tab open / channel use) to mint a per-user MCP token
# and provision that user's isolated Hermes profile. Without it the agent loads
# but every deepsql tool call 401s (the profile carries no DeepSQL token).
generate_secret AGENT_PROVISION_SECRET "openssl rand -base64 32 | tr -d '\n'"

prompt_llm_credentials

if [[ "$CREATED_ENV" == "true" || "${SECURITY_ADMIN_BOOTSTRAP_ENABLED:-false}" == "true" ]]; then
  prompt_initial_admin_credentials
fi

prompt_optional_company_name

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

# Promote newly-introduced release defaults (e.g. a freshly-added
# DEEPSQL_AGENT_IMAGE) and bump image pins from .env.example BEFORE the
# required-var validation below — otherwise a brand-new required key that an
# older install's .env predates fails validation before it can be promoted.
# (Regression: pre-1.4.0 -> 1.4.0 upgrades aborted on DEEPSQL_AGENT_IMAGE.)
# Re-load so the promoted/bumped values are visible to require_env_value.
bump_image_pins_from_release
load_env_file

require_env_value DEEPSQL_BACKEND_IMAGE
require_env_value DEEPSQL_FRONTEND_IMAGE
require_env_value DEEPSQL_AGENT_IMAGE
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
# Reclaim stale-project ports BEFORE migrating volumes: this quiesces the old
# stack's containers so the volume copy reads a volume with no live writer,
# and frees the host ports the canonical `compose up` below needs to bind.
reclaim_stale_project_stacks
migrate_prefixed_volumes_if_needed
# bump_image_pins_from_release now runs earlier, before require_env_value (above).
_INSTALL_PROGRESS="post-bump"
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
printf "${BOLD}${GREEN}+==================================================+${RESET}\n"
printf "${BOLD}${GREEN}|        DeepSQL self-hosted stack is ready        |${RESET}\n"
printf "${BOLD}${GREEN}+==================================================+${RESET}\n"
printf "\n"
printf "${BOLD}  Access${RESET}\n"
printf "  Frontend  ${CYAN}http://localhost:${DEEPSQL_FRONTEND_PORT}${RESET}\n"
printf "  Backend   ${CYAN}http://localhost:${DEEPSQL_BACKEND_PORT}${RESET}\n"
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
printf "  Agent     ${DIM}${DEEPSQL_AGENT_IMAGE}${RESET}\n"
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
printf "${BOLD}  Next steps${RESET}\n"
printf "  ${DIM}Diagnostics (index suggestions, anti-patterns, digest) accumulate on a${RESET}\n"
printf "  ${DIM}schedule and are empty right after install. To see results immediately${RESET}\n"
printf "  ${DIM}once you've connected a database, run: ${RESET}${CYAN}deepsql indexes refresh${RESET}\n"
printf "\n"
if [[ "${USED_MANAGED_LLM_KEY}" == "true" ]]; then
  printf "${BOLD}  LLM privacy${RESET}\n"
  printf "  ${DIM}This install is using DeepSQL's shared managed Azure OpenAI key, so your${RESET}\n"
  printf "  ${DIM}schema and queries are processed through DeepSQL's shared LLM resource.${RESET}\n"
  printf "  ${DIM}To use your own key: set AZURE_OPENAI_KEY and AZURE_OPENAI_ENDPOINT in${RESET}\n"
  printf "  ${DIM}${ENV_FILE} and re-run ./scripts/install.sh.${RESET}\n"
  printf "\n"
fi
printf "${BOLD}  Useful commands${RESET}\n"
printf "  ${DIM}./scripts/status.sh${RESET}\n"
printf "  ${DIM}./scripts/smoke-test.sh${RESET}\n"
printf "  ${DIM}./scripts/uninstall.sh${RESET}\n"

install_mcp_package
