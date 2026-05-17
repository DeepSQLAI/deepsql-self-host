#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="${DEEPSQL_REPO_OWNER:-DeepSQLAI}"
REPO_NAME="${DEEPSQL_REPO_NAME:-deepsql-self-host}"
# Default: explicit env override -> latest GitHub release tag -> main fallback.
REF="${DEEPSQL_SELF_HOST_REF:-}"
if [[ -z "$REF" ]]; then
  REF="$(curl -fsSL --connect-timeout 5 --max-time 10 \
    "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest" 2>/dev/null \
    | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -1 | cut -d'"' -f4)"
  [[ -z "$REF" ]] && REF="main"
fi
INSTALL_DIR="${DEEPSQL_INSTALL_DIR:-$HOME/.deepsql/self-host}"
ARCHIVE_URL="${DEEPSQL_SELF_HOST_ARCHIVE_URL:-https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/heads/${REF}.tar.gz}"

if [[ "$REF" == v* && -z "${DEEPSQL_SELF_HOST_ARCHIVE_URL:-}" ]]; then
  ARCHIVE_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/tags/${REF}.tar.gz"
fi

echo "Installing DeepSQL self-host ref: $REF"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command '$1' is not installed." >&2
    exit 1
  fi
}

run_local_installer_if_present() {
  local script_path="${BASH_SOURCE[0]:-}"
  if [[ -n "$script_path" && -f "$script_path" ]]; then
    local script_dir
    script_dir="$(cd "$(dirname "$script_path")" && pwd)"
    if [[ -f "$script_dir/docker-compose.yml" && -x "$script_dir/scripts/install.sh" ]]; then
      "$script_dir/scripts/install.sh"
      exit 0
    fi
  fi
}

run_local_installer_if_present

require_command curl
require_command tar

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

archive_path="$tmp_dir/deepsql-self-host.tar.gz"
extract_dir="$tmp_dir/extract"
mkdir -p "$extract_dir" "$INSTALL_DIR"

echo "Downloading DeepSQL self-host installer from $ARCHIVE_URL"
curl -fsSL "$ARCHIVE_URL" -o "$archive_path"
tar -xzf "$archive_path" -C "$extract_dir"

bundle_dir="$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
if [[ -z "$bundle_dir" || ! -f "$bundle_dir/scripts/install.sh" ]]; then
  echo "Error: downloaded archive did not contain scripts/install.sh." >&2
  exit 1
fi

echo "Installing DeepSQL self-host files into $INSTALL_DIR"
(cd "$bundle_dir" && tar -cf - .) | (cd "$INSTALL_DIR" && tar -xf -)
chmod +x "$INSTALL_DIR/scripts/"*.sh

"$INSTALL_DIR/scripts/install.sh"
