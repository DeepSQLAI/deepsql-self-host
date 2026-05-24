#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="${DEEPSQL_COMPOSE_FILE:-$ROOT_DIR/docker-compose.yml}"
ENV_FILE="${DEEPSQL_ENV_FILE:-$ROOT_DIR/.env}"
PROJECT_NAME="${DEEPSQL_PROJECT_NAME:-deepsql-selfhost}"

# Default to purging volumes. The previous default (preserve) created a
# subtle footgun: uninstall + reinstall left old encrypted data in the
# Postgres volume that couldn't be decrypted with the new auto-generated
# ENCRYPTION_KEY, producing confusing login failures. Real users expect
# "uninstall" to mean "wipe everything DeepSQL touched".
PURGE_DATA=true

usage() {
  cat <<'EOF'
Usage: uninstall.sh [--keep-data | --purge-data]

  --keep-data    Stop containers but preserve Postgres + Valkey volumes.
                 Use this only if you plan to reinstall the SAME version
                 and want to keep your existing data.
  --purge-data   Default. Stop containers AND remove all DeepSQL volumes.
                 Required after any uninstall when you plan to reinstall.

Pass no arguments for the safe default (purge).
EOF
}

for arg in "$@"; do
  case "$arg" in
    --purge-data)
      PURGE_DATA=true
      ;;
    --keep-data)
      PURGE_DATA=false
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      usage >&2
      exit 1
      ;;
  esac
done

compose() {
  docker compose \
    --project-name "$PROJECT_NAME" \
    --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" \
    "$@"
}

INSTALL_DIR="${DEEPSQL_INSTALL_DIR:-$HOME/.deepsql}"

if [[ "$PURGE_DATA" == "true" ]]; then
  compose down --remove-orphans --volumes
  echo "DeepSQL self-hosted stack removed, including persisted Postgres / Valkey volumes."
  if [[ -d "$INSTALL_DIR" ]]; then
    rm -rf "$INSTALL_DIR"
    echo "Removed install directory: $INSTALL_DIR"
  fi
else
  compose down --remove-orphans
  echo "DeepSQL self-hosted stack stopped. Data volumes AND install directory"
  echo "preserved (--keep-data). Re-running install.sh will upgrade in place"
  echo "using the existing .env (secrets + admin credentials stay intact)."
fi
