#!/usr/bin/env bash
# Collect a redacted diagnostic bundle from a DeepSQL self-host installation.
# Run on the host where DeepSQL is installed. Output is a single tarball
# in $HOME that you can attach to a support ticket or email to DeepSQL.
#
# Secrets matching *KEY, *SECRET, *PASSWORD, *TOKEN, *CREDENTIAL are
# redacted from the captured .env before bundling. No DB content, no
# queries, no LLM prompts are collected.
#
# Overrides (env vars):
#   DEEPSQL_COMPOSE_FILE   path to docker-compose.yml
#   DEEPSQL_ENV_FILE       path to .env
#   DEEPSQL_PROJECT_NAME   compose project name (default: deepsql-selfhost)
#   DEEPSQL_DIAG_OUT_DIR   directory to write the tarball (default: $HOME)

set -uo pipefail

# UserData / SSM / CI often invoke this with HOME unset, which breaks
# the OUT_DIR default below under `set -u`.
if [[ -z "${HOME:-}" ]]; then
  HOME="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 || true)"
  [[ -z "$HOME" ]] && HOME=/root
  export HOME
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="${DEEPSQL_COMPOSE_FILE:-$ROOT_DIR/docker-compose.yml}"
ENV_FILE="${DEEPSQL_ENV_FILE:-$ROOT_DIR/.env}"
PROJECT_NAME="${DEEPSQL_PROJECT_NAME:-deepsql-selfhost}"

TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
BUNDLE_NAME="deepsql-diag-${TIMESTAMP}-${HOSTNAME_SHORT}"
OUT_DIR="${DEEPSQL_DIAG_OUT_DIR:-$HOME}"
OUT_TGZ="$OUT_DIR/${BUNDLE_NAME}.tar.gz"

STAGE_DIR="$(mktemp -d -t deepsql-diag.XXXXXX)"
trap 'rm -rf "$STAGE_DIR"' EXIT

BUNDLE_DIR="$STAGE_DIR/$BUNDLE_NAME"
mkdir -p "$BUNDLE_DIR/logs"

have() { command -v "$1" >/dev/null 2>&1; }

capture() {
  # capture <outfile> <label> <command...>
  local out="$1" label="$2"; shift 2
  {
    printf '=== %s ===\n' "$label"
    "$@" 2>&1
    printf '\n'
  } >> "$out"
}

compose() {
  docker compose --project-name "$PROJECT_NAME" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

# 1. metadata
{
  echo "Generated:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Generator:     deepsql diagnose.sh"
  echo "Host:          $HOSTNAME_SHORT"
  echo "Install dir:   $ROOT_DIR"
  echo "Compose file:  $COMPOSE_FILE"
  echo "Env file:      $ENV_FILE"
  echo "Project:       $PROJECT_NAME"
} > "$BUNDLE_DIR/metadata.txt"

# 2. system info
SYS="$BUNDLE_DIR/system.txt"
capture "$SYS" "uname -a"        uname -a
capture "$SYS" "/etc/os-release" sh -c 'cat /etc/os-release 2>/dev/null || sw_vers 2>/dev/null || echo "(none)"'
capture "$SYS" "uptime"          uptime
capture "$SYS" "CPU count"       sh -c 'nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null'
capture "$SYS" "Memory"          sh -c 'free -h 2>/dev/null || vm_stat 2>/dev/null || echo "(unavailable)"'
capture "$SYS" "Disk usage"      df -h

# 3. docker / compose info
DOC="$BUNDLE_DIR/docker.txt"
if have docker; then
  capture "$DOC" "docker version"         docker version
  capture "$DOC" "docker info"            docker info
  capture "$DOC" "docker compose version" docker compose version
  capture "$DOC" "docker system df"       docker system df
else
  echo "docker not on PATH" > "$DOC"
fi

# 4. stack state
STK="$BUNDLE_DIR/stack.txt"
if have docker && [[ -f "$COMPOSE_FILE" ]]; then
  capture "$STK" "compose ps"     compose ps
  capture "$STK" "compose images" compose images
  capture "$STK" "compose top"    compose top
  CIDS="$(compose ps -q 2>/dev/null | tr '\n' ' ')"
  if [[ -n "${CIDS// }" ]]; then
    capture "$STK" "docker stats (snapshot)" docker stats --no-stream $CIDS
    capture "$STK" "container health"        sh -c "docker inspect --format '{{.Name}}: {{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $CIDS"
  fi
else
  echo "compose file not found at $COMPOSE_FILE" > "$STK"
fi

# 5. per-service logs
if have docker && [[ -f "$COMPOSE_FILE" ]]; then
  for svc in postgres valkey backend frontend; do
    compose logs --no-color --tail=1000 "$svc" > "$BUNDLE_DIR/logs/$svc.log" 2>&1 || true
  done
fi

# 6. .env redacted
if [[ -f "$ENV_FILE" ]]; then
  awk '
    /^[[:space:]]*(#|$)/ { print; next }
    {
      line = $0
      key = line
      sub(/^[[:space:]]*export[[:space:]]+/, "", key)
      sub(/=.*/, "", key)
      if (key ~ /(KEY|SECRET|PASSWORD|TOKEN|CREDENTIAL|EMAIL)/) {
        prefix = line
        sub(/=.*/, "=", prefix)
        print prefix "***REDACTED***"
      } else {
        print line
      }
    }
  ' "$ENV_FILE" > "$BUNDLE_DIR/env.redacted"
else
  echo "(no .env file at $ENV_FILE)" > "$BUNDLE_DIR/env.redacted"
fi

# 7. compose file (no secrets)
[[ -f "$COMPOSE_FILE" ]] && cp "$COMPOSE_FILE" "$BUNDLE_DIR/docker-compose.yml"

# 8. network reachability
NET="$BUNDLE_DIR/network.txt"
{
  echo "=== /etc/resolv.conf ==="
  grep -v '^#' /etc/resolv.conf 2>/dev/null || echo "(unavailable)"
  echo
} > "$NET"

HOSTS=(install.deepsql.ai ghcr.io github.com registry.npmjs.org)
AZURE_HOST="$(grep -oE 'AZURE_OPENAI_ENDPOINT=https?://[^/[:space:]]+' "$ENV_FILE" 2>/dev/null \
  | head -1 | sed -E 's,.*://,,')"
[[ -n "$AZURE_HOST" ]] && HOSTS+=("$AZURE_HOST")

for h in "${HOSTS[@]}"; do
  {
    echo "--- $h ---"
    if have getent; then
      getent hosts "$h" 2>&1 || true
    elif have host; then
      host "$h" 2>&1 || true
    else
      nslookup "$h" 2>&1 | head -6 || true
    fi
    if have nc; then
      nc -vz -w5 "$h" 443 2>&1 | tail -1
    else
      (timeout 5 bash -c "exec 3<>/dev/tcp/$h/443 && echo 'tcp/443 reachable'") 2>&1 \
        || echo "tcp/443 unreachable"
    fi
    echo
  } >> "$NET"
done

# 9. existing scripts
[[ -x "$SCRIPT_DIR/status.sh" ]]     && "$SCRIPT_DIR/status.sh"     > "$BUNDLE_DIR/status.txt"     2>&1
[[ -x "$SCRIPT_DIR/smoke-test.sh" ]] && "$SCRIPT_DIR/smoke-test.sh" > "$BUNDLE_DIR/smoke-test.txt" 2>&1

# 10. quick error filter
if [[ -s "$BUNDLE_DIR/logs/backend.log" ]]; then
  grep -iE 'error|exception|fatal|fail|denied' "$BUNDLE_DIR/logs/backend.log" \
    | tail -200 > "$BUNDLE_DIR/backend-errors.txt" 2>/dev/null || true
fi

# 11. install context
CTX="$BUNDLE_DIR/install-context.txt"
{
  echo "=== git (if a checkout) ==="
  (cd "$ROOT_DIR" 2>/dev/null && git rev-parse HEAD 2>/dev/null && git log -1 --oneline 2>/dev/null) \
    || echo "(not a git checkout)"
  echo
  echo "=== install.sh head ==="
  head -5 "$SCRIPT_DIR/install.sh" 2>/dev/null || echo "(install.sh not found)"
  echo
  echo "=== directory listing ==="
  ls -la "$ROOT_DIR" 2>/dev/null || true
} > "$CTX"

# 12. README inside bundle
cat > "$BUNDLE_DIR/README.txt" <<EOF
DeepSQL self-host diagnostic bundle
====================================
Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Host:      $HOSTNAME_SHORT

Files:
  metadata.txt           summary of where this came from
  system.txt             OS, CPU, memory, disk
  docker.txt             docker + docker compose versions and state
  stack.txt              compose ps / images / top / stats / health
  logs/*.log             last 1000 lines per service
  env.redacted           .env with secret values masked
  docker-compose.yml     copy of the compose file (no secrets)
  network.txt            DNS + tcp/443 reachability checks
  status.txt             ./scripts/status.sh output (if present)
  smoke-test.txt         ./scripts/smoke-test.sh output (if present)
  backend-errors.txt     filtered error/exception lines from backend.log
  install-context.txt    git rev, install dir listing

Secrets handling:
  Values for any .env key matching *KEY, *SECRET, *PASSWORD, *TOKEN,
  *CREDENTIAL, *EMAIL are replaced with ***REDACTED*** before bundling.
  Review env.redacted manually before sharing if you handle especially
  sensitive secrets.

What is NOT collected:
  Database contents, queries, query results, LLM prompts/responses,
  user data, vector embeddings.
EOF

# pack
tar -czf "$OUT_TGZ" -C "$STAGE_DIR" "$BUNDLE_NAME"

BUNDLE_BYTES="$(wc -c < "$OUT_TGZ" | tr -d ' ')"
BUNDLE_KB=$(( BUNDLE_BYTES / 1024 ))

cat <<EOF

================================================================
Diagnostic bundle created (${BUNDLE_KB} KB):

  $OUT_TGZ

Secrets matching *KEY/*SECRET/*PASSWORD/*TOKEN/*CREDENTIAL/*EMAIL
are redacted in env.redacted. Open the tarball and review before
sharing if you want to double-check.

Attach to a GitHub issue or email to support@deepsql.ai with a
short description of what went wrong.
================================================================
EOF
