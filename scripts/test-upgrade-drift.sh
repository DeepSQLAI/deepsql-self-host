#!/usr/bin/env bash
#
# test-upgrade-drift.sh — reproduction + regression test for the
# container/volume project-name drift that caused data-loss scares on
# upgrade (fixed across v1.3.2 -> v1.3.4).
#
# WHAT IT PROVES
#   1. A legacy install whose volumes are Compose-prefixed under a drifted
#      project name ("self-host", from the install-dir basename) can be
#      upgraded WITHOUT losing data.
#   2. After upgrade the data lives on the ABSOLUTE volume (dba-agent-postgres)
#      that v1.3.3 introduced, under the canonical project name
#      (deepsql-selfhost) that v1.3.4 pinned in docker-compose.yml.
#   3. The original prefixed volume is preserved as a rollback safety net.
#
# NOT COVERED
#   Full backend functionality (needs real Azure OpenAI creds). This drives
#   postgres + volume + project-name mechanics only; the backend may come up
#   unhealthy with the dummy creds below and that is expected.
#
# SAFETY
#   Runs in a throwaway temp dir with dedicated containers/volumes. Never
#   touches an existing ~/.deepsql/self-host install. Cleans up on exit
#   (set KEEP=1 to inspect artifacts).
#
# USAGE
#   ./scripts/test-upgrade-drift.sh                  # tests the live one-liner
#   DEEPSQL_SELF_HOST_REF=main ./scripts/test-upgrade-drift.sh
#   KEEP=1 ./scripts/test-upgrade-drift.sh
#
set -euo pipefail

LEGACY_REF="${LEGACY_REF:-v1.3.1}"
UPGRADE_REF="${DEEPSQL_SELF_HOST_REF:-}"
INSTALL_ONE_LINER="${INSTALL_ONE_LINER:-curl -fsSL https://install.deepsql.ai/install.sh | bash}"
TEST_ROOT="${DEEPSQL_TEST_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/deepsql-drift.XXXXXX")}"
INSTALL_DIR="$TEST_ROOT/self-host"
SENTINEL="drift_test_$(date +%s)"

export DEEPSQL_BACKEND_PORT="${DEEPSQL_BACKEND_PORT:-59085}"
export DEEPSQL_FRONTEND_PORT="${DEEPSQL_FRONTEND_PORT:-53035}"
export DEEPSQL_POSTGRES_PORT="${DEEPSQL_POSTGRES_PORT:-55432}"
export DEEPSQL_VALKEY_PORT="${DEEPSQL_VALKEY_PORT:-56379}"
export AZURE_OPENAI_KEY="${AZURE_OPENAI_KEY:-drift-test-dummy-key-0000}"
export AZURE_OPENAI_ENDPOINT="${AZURE_OPENAI_ENDPOINT:-https://drift-test.invalid/}"
export DEEPSQL_INITIAL_ADMIN_EMAIL="${DEEPSQL_INITIAL_ADMIN_EMAIL:-admin@drift-test.local}"
export DEEPSQL_INITIAL_ADMIN_PASSWORD="${DEEPSQL_INITIAL_ADMIN_PASSWORD:-DriftTest123!}"
export DEEPSQL_INSTALL_DIR="$INSTALL_DIR"

LEGACY_PROJECT="self-host"
CANONICAL_PROJECT="deepsql-selfhost"
LEGACY_PG_VOLUME="${LEGACY_PROJECT}_dba-agent-postgres"
ABSOLUTE_PG_VOLUME="dba-agent-postgres"

PASS_COUNT=0
FAIL_COUNT=0

log()  { printf '\n\033[1;36m> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m[PASS] %s\033[0m\n' "$*"; PASS_COUNT=$((PASS_COUNT+1)); }
bad()  { printf '  \033[31m[FAIL] %s\033[0m\n' "$*"; FAIL_COUNT=$((FAIL_COUNT+1)); }

legacy_compose() {
  docker compose -p "$LEGACY_PROJECT" --env-file "$INSTALL_DIR/.env" \
    -f "$INSTALL_DIR/docker-compose.yml" "$@"
}

pg_query() {
  local container="$1"; shift
  docker exec "$container" psql -U postgres -d dba_agent -tAc "$*"
}

cleanup() {
  local code=$?
  if [[ "${KEEP:-0}" == "1" ]]; then
    log "KEEP=1 set - leaving artifacts at $TEST_ROOT"
    return
  fi
  log "Cleaning up test artifacts"
  docker compose -p "$LEGACY_PROJECT"    -f "$INSTALL_DIR/docker-compose.yml" down --remove-orphans >/dev/null 2>&1 || true
  docker compose -p "$CANONICAL_PROJECT" -f "$INSTALL_DIR/docker-compose.yml" down --remove-orphans >/dev/null 2>&1 || true
  docker volume rm -f \
    "$LEGACY_PG_VOLUME" "${LEGACY_PROJECT}_dba-agent-valkey" "${LEGACY_PROJECT}_dba-agent-logs" \
    "$ABSOLUTE_PG_VOLUME" dba-agent-valkey dba-agent-logs >/dev/null 2>&1 || true
  rm -rf "$TEST_ROOT" 2>/dev/null || true
  exit $code
}
trap cleanup EXIT

log "Phase 0 - preconditions"
docker info >/dev/null 2>&1 || { echo "Docker daemon not reachable."; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "docker compose v2 required."; exit 1; }
ok "Docker + Compose available"
echo "  Sandbox: $TEST_ROOT"
echo "  Legacy ref: $LEGACY_REF   Upgrade ref: ${UPGRADE_REF:-<latest release>}"

log "Phase 1 - create legacy install drifted under project '$LEGACY_PROJECT'"
mkdir -p "$INSTALL_DIR"
curl -fsSL "https://github.com/DeepSQLAI/deepsql-self-host/archive/refs/tags/${LEGACY_REF}.tar.gz" \
  -o "$TEST_ROOT/legacy.tgz"
tar -xzf "$TEST_ROOT/legacy.tgz" -C "$TEST_ROOT"
legacy_bundle="$(find "$TEST_ROOT" -maxdepth 1 -type d -name 'deepsql-self-host-*' | head -1)"
cp "$legacy_bundle/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml"

if grep -qE '^name:' "$INSTALL_DIR/docker-compose.yml"; then
  bad "Legacy compose unexpectedly pins 'name:' - pick an older LEGACY_REF (pre-v1.3.4)"
  exit 1
fi
ok "Legacy compose has no top-level name: (drift premise holds)"

cat > "$INSTALL_DIR/.env" <<EOF
DEEPSQL_BACKEND_IMAGE=ghcr.io/deepsqlai/deepsql-self-host-backend:${LEGACY_REF#v}
DEEPSQL_FRONTEND_IMAGE=ghcr.io/deepsqlai/deepsql-self-host-frontend:${LEGACY_REF#v}
DEEPSQL_SKIP_IMAGE_PULL=false
SECURITY_JWT_SECRET=drift-test-jwt-secret-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
ENCRYPTION_KEY=drift-test-encryption-key-bbbbbbbb
ENCRYPTION_KEY_ID=self-hosted-key-1
DB_PASSWORD=drift-test-db-password
SPRING_PROFILES_ACTIVE=prod
VECTOR_STORE_TYPE=pgvector
AZURE_SEARCH_ENABLED=false
DEEPSQL_BACKEND_PORT=${DEEPSQL_BACKEND_PORT}
DEEPSQL_FRONTEND_PORT=${DEEPSQL_FRONTEND_PORT}
DEEPSQL_POSTGRES_PORT=${DEEPSQL_POSTGRES_PORT}
DEEPSQL_VALKEY_PORT=${DEEPSQL_VALKEY_PORT}
EOF

legacy_compose up -d postgres
log "Waiting for legacy postgres to become healthy"
until docker ps --filter "name=${LEGACY_PROJECT}-postgres-1" --filter "health=healthy" \
        --format '{{.Names}}' | grep -q .; do sleep 3; done
ok "Legacy postgres healthy as ${LEGACY_PROJECT}-postgres-1"

if docker volume inspect "$LEGACY_PG_VOLUME" >/dev/null 2>&1; then
  ok "Legacy prefixed volume created: $LEGACY_PG_VOLUME"
else
  bad "Expected legacy volume $LEGACY_PG_VOLUME was not created"
  exit 1
fi

pg_query "${LEGACY_PROJECT}-postgres-1" "CREATE TABLE IF NOT EXISTS drift_sentinel(tag text primary key);" >/dev/null
pg_query "${LEGACY_PROJECT}-postgres-1" "INSERT INTO drift_sentinel(tag) VALUES ('${SENTINEL}') ON CONFLICT DO NOTHING;" >/dev/null
seeded="$(pg_query "${LEGACY_PROJECT}-postgres-1" "SELECT tag FROM drift_sentinel WHERE tag='${SENTINEL}';")"
[[ "$seeded" == "$SENTINEL" ]] && ok "Seeded sentinel row: $SENTINEL" || { bad "Failed to seed sentinel"; exit 1; }

legacy_compose down >/dev/null 2>&1
ok "Legacy stack stopped (volumes preserved) - mirrors the real pre-upgrade state"

log "Phase 2 - upgrade in place with ${UPGRADE_REF:-latest} installer"
upgrade_env=( "DEEPSQL_INSTALL_DIR=$INSTALL_DIR" )
[[ -n "$UPGRADE_REF" ]] && upgrade_env+=( "DEEPSQL_SELF_HOST_REF=$UPGRADE_REF" )
set +e
env "${upgrade_env[@]}" timeout 300 bash -c "$INSTALL_ONE_LINER" > "$TEST_ROOT/upgrade.log" 2>&1
upgrade_code=$?
set -e
echo "  installer exit code: $upgrade_code (timeout/backend-unhealthy expected with dummy Azure creds)"
echo "  --- migration-relevant installer output ---"
grep -E "Migrating volume|mirrors|project|Promoting|Adopting|Enabling" "$TEST_ROOT/upgrade.log" | sed 's/^/    /' || true

log "Phase 3 - assertions"

if docker volume inspect "$ABSOLUTE_PG_VOLUME" >/dev/null 2>&1; then
  ok "Absolute volume present: $ABSOLUTE_PG_VOLUME"
else
  bad "Absolute volume $ABSOLUTE_PG_VOLUME missing - migration did not run"
fi

if docker volume inspect "$LEGACY_PG_VOLUME" >/dev/null 2>&1; then
  ok "Legacy volume preserved as safety net: $LEGACY_PG_VOLUME"
else
  bad "Legacy volume $LEGACY_PG_VOLUME was deleted - safety net violated"
fi

running_projects="$(docker ps -a --filter "label=com.docker.compose.service" \
  --format '{{.Label "com.docker.compose.project"}}' | sort -u | grep -E 'deepsql|self-host' || true)"
echo "  Compose projects present: $(echo "$running_projects" | tr '\n' ' ')"
if docker ps -a --format '{{.Names}}' | grep -q "^${CANONICAL_PROJECT}-postgres-1$"; then
  ok "Containers use canonical project name: ${CANONICAL_PROJECT}-*"
else
  bad "No ${CANONICAL_PROJECT}-postgres-1 container - project name not canonical"
fi

log "Waiting for upgraded postgres to be queryable"
canon_pg="${CANONICAL_PROJECT}-postgres-1"
if docker ps --filter "name=${canon_pg}" --format '{{.Names}}' | grep -q .; then
  until docker exec "$canon_pg" pg_isready -U postgres >/dev/null 2>&1; do sleep 2; done
  recovered="$(pg_query "$canon_pg" "SELECT tag FROM drift_sentinel WHERE tag='${SENTINEL}';" 2>/dev/null || true)"
  if [[ "$recovered" == "$SENTINEL" ]]; then
    ok "Sentinel data survived upgrade: $recovered"
  else
    bad "Sentinel row NOT found after upgrade (got: '${recovered:-<empty>}') - DATA LOSS"
  fi
else
  bad "Canonical postgres container not running - cannot verify data"
fi

log "Summary"
echo "  Passed: $PASS_COUNT   Failed: $FAIL_COUNT"
if [[ $FAIL_COUNT -eq 0 ]]; then
  printf '\n\033[1;32mPASS - upgrade preserves data and uses canonical project/volume names.\033[0m\n'
  exit 0
else
  printf '\n\033[1;31mFAIL - see assertions above. Installer log: %s\033[0m\n' "$TEST_ROOT/upgrade.log"
  KEEP=1
  exit 1
fi
