#!/usr/bin/env bash
#
# reconcile-schema.sh — repair internal-DB schema drift on an upgraded
# DeepSQL self-host install.
#
# WHY THIS EXISTS
#   The self-host backend evolves its internal Postgres schema with Hibernate
#   `ddl-auto=update` (there is no Flyway in the self-host image). Hibernate
#   adds a new NOT NULL column as `ALTER TABLE t ADD COLUMN c <type> not null`
#   WITHOUT a DEFAULT. Postgres rejects that on a table that already has rows,
#   and the backend runs with `hibernate.hbm2ddl.halt_on_error=false`, so the
#   failure is swallowed at startup — the container comes up "healthy" with a
#   schema that no longer matches the JPA entities.
#
#   The first endpoint to hydrate such an entity then fails with
#   `ERROR: column ... does not exist` and returns HTTP 500. The known
#   casualty is `index_recommendations` (breaks `deepsql indexes health`
#   and `deepsql indexes list`), but this script idempotently reconciles
#   every column delta that an upgraded volume could be missing.
#
#   Each statement is `ADD COLUMN IF NOT EXISTS ... DEFAULT ...` guarded by a
#   table-existence check, so the script is safe to run repeatedly and safe
#   across versions (tables absent on a given install are skipped, not failed).
#
# WHAT IT DOES NOT DO
#   No data is modified or deleted. Only missing columns / lookup tables are
#   added, with the same defaults the canonical migrations use. No backend
#   restart is required — the schema is read live on the next request.
#
# USAGE (run on the host where DeepSQL is installed)
#   ./scripts/reconcile-schema.sh             # detect + reconcile
#   ./scripts/reconcile-schema.sh --dry-run   # show what is missing, change nothing
#
# Overrides (env vars):
#   DEEPSQL_COMPOSE_FILE   path to docker-compose.yml   (default: ../docker-compose.yml)
#   DEEPSQL_ENV_FILE       path to .env                 (default: ../.env)
#   DEEPSQL_PROJECT_NAME   compose project name         (default: deepsql-selfhost)
#   DEEPSQL_PG_CONTAINER   postgres container name/id   (default: auto-detect)
#   DEEPSQL_DB_NAME        internal database name       (default: dba_agent)
#   DEEPSQL_DB_USER        internal database user       (default: postgres)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="${DEEPSQL_COMPOSE_FILE:-$ROOT_DIR/docker-compose.yml}"
ENV_FILE="${DEEPSQL_ENV_FILE:-$ROOT_DIR/.env}"
PROJECT_NAME="${DEEPSQL_PROJECT_NAME:-deepsql-selfhost}"
DB_NAME="${DEEPSQL_DB_NAME:-dba_agent}"
DB_USER="${DEEPSQL_DB_USER:-postgres}"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

have() { command -v "$1" >/dev/null 2>&1; }
die()  { echo "error: $*" >&2; exit 1; }

have docker || die "docker is not on PATH; run this on the DeepSQL host"

# ── Resolve the internal Postgres container ─────────────────────────────────
# Prefer the compose service; fall back to a name match so drifted installs
# (project name "self-host", container "self-host-postgres-1") still resolve.
resolve_pg_container() {
  if [[ -n "${DEEPSQL_PG_CONTAINER:-}" ]]; then
    echo "$DEEPSQL_PG_CONTAINER"; return 0
  fi
  local cid=""
  if [[ -f "$COMPOSE_FILE" ]]; then
    local compose_args=(compose --project-name "$PROJECT_NAME" -f "$COMPOSE_FILE")
    [[ -f "$ENV_FILE" ]] && compose_args+=(--env-file "$ENV_FILE")
    cid="$(docker "${compose_args[@]}" ps -q postgres 2>/dev/null | head -n1)"
  fi
  if [[ -z "$cid" ]]; then
    # Name-based fallback: any running container whose name ends in -postgres-1
    cid="$(docker ps --filter "name=postgres" --format '{{.Names}}' 2>/dev/null \
            | grep -E '(^|[-_])postgres([-_][0-9]+)?$' | head -n1)"
  fi
  [[ -n "$cid" ]] && echo "$cid"
}

PG_CONTAINER="$(resolve_pg_container)"
[[ -n "$PG_CONTAINER" ]] || die "could not find the internal postgres container; set DEEPSQL_PG_CONTAINER"

echo "Container:   $PG_CONTAINER"
echo "Database:    $DB_NAME  (user: $DB_USER)"
echo "Mode:        $([[ $DRY_RUN -eq 1 ]] && echo 'DRY RUN (no changes)' || echo 'reconcile')"
echo

psql_q() {
  # psql_q <sql>  → run quietly, tuples-only, single value
  docker exec -i "$PG_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tAq -c "$1" 2>/dev/null
}
psql_exec() {
  # psql_exec <sql>  → run a statement block, abort on first failure
  docker exec -i "$PG_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -q -c "$1"
}

# Reconcile block. Every entry mirrors a canonical migration delta. NOT NULL
# columns carry an explicit DEFAULT so the add succeeds on a populated table —
# exactly what Hibernate fails to emit.
RECONCILE_SQL=$(cat <<'SQL'
-- index_recommendations: the confirmed casualty (V93/V94/V95/V97 deltas)
DO $$ BEGIN
  IF to_regclass('public.index_recommendations') IS NOT NULL THEN
    ALTER TABLE index_recommendations
      ADD COLUMN IF NOT EXISTS occurrence_count     INTEGER NOT NULL DEFAULT 1,
      ADD COLUMN IF NOT EXISTS first_seen_at        TIMESTAMP,
      ADD COLUMN IF NOT EXISTS last_seen_at         TIMESTAMP,
      ADD COLUMN IF NOT EXISTS kind                 VARCHAR(20) NOT NULL DEFAULT 'CREATE_INDEX',
      ADD COLUMN IF NOT EXISTS workload_score_ms    BIGINT NOT NULL DEFAULT 0,
      ADD COLUMN IF NOT EXISTS write_cost_score     BIGINT NOT NULL DEFAULT 0,
      ADD COLUMN IF NOT EXISTS evidence_count       INTEGER NOT NULL DEFAULT 0,
      ADD COLUMN IF NOT EXISTS hypopg_before_cost   DOUBLE PRECISION,
      ADD COLUMN IF NOT EXISTS hypopg_after_cost    DOUBLE PRECISION,
      ADD COLUMN IF NOT EXISTS hypopg_reduction_pct DOUBLE PRECISION,
      ADD COLUMN IF NOT EXISTS hypopg_evaluated_at  TIMESTAMP;
  END IF;
END $$;

-- index_recommendation_evidence: lookup table backing /top + evidence payloads (V96)
CREATE TABLE IF NOT EXISTS index_recommendation_evidence (
    id                  VARCHAR(36)       PRIMARY KEY,
    recommendation_id   VARCHAR(36)       NOT NULL REFERENCES index_recommendations(id) ON DELETE CASCADE,
    query_fingerprint   VARCHAR(64)       NOT NULL,
    example_sql         TEXT,
    calls               BIGINT            NOT NULL DEFAULT 0,
    mean_exec_time_ms   DOUBLE PRECISION  NOT NULL DEFAULT 0,
    total_exec_time_ms  DOUBLE PRECISION  NOT NULL DEFAULT 0,
    rows_examined       BIGINT,
    role                VARCHAR(32)       NOT NULL,
    observed_at         TIMESTAMP         NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMP         NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uk_rec_evidence UNIQUE (recommendation_id, query_fingerprint)
);

-- Defensive: other NOT NULL column adds that Hibernate could have silently
-- failed to apply on a populated table (no-ops where already present).
DO $$ BEGIN
  IF to_regclass('public.schema_documentation') IS NOT NULL THEN
    ALTER TABLE schema_documentation
      ADD COLUMN IF NOT EXISTS source     VARCHAR(20) NOT NULL DEFAULT 'USER',
      ADD COLUMN IF NOT EXISTS confidence DOUBLE PRECISION;
  END IF;
  IF to_regclass('public.encrypted_credentials') IS NOT NULL THEN
    ALTER TABLE encrypted_credentials
      ADD COLUMN IF NOT EXISTS enable_data_sampling BOOLEAN NOT NULL DEFAULT TRUE;
  END IF;
  IF to_regclass('public.users') IS NOT NULL THEN
    ALTER TABLE users
      ADD COLUMN IF NOT EXISTS account_status VARCHAR(32) NOT NULL DEFAULT 'ACTIVE';
  END IF;
  IF to_regclass('public.query_fingerprints') IS NOT NULL THEN
    ALTER TABLE query_fingerprints
      ADD COLUMN IF NOT EXISTS normalization_version INTEGER NOT NULL DEFAULT 1;
  END IF;
  IF to_regclass('public.resource_limits') IS NOT NULL THEN
    ALTER TABLE resource_limits
      ADD COLUMN IF NOT EXISTS slow_query_history_retention_days INTEGER NOT NULL DEFAULT 30;
  END IF;
  IF to_regclass('public.ingestion_jobs') IS NOT NULL THEN
    ALTER TABLE ingestion_jobs
      ADD COLUMN IF NOT EXISTS truncated BOOLEAN NOT NULL DEFAULT FALSE;
  END IF;
END $$;
SQL
)

# (table:column) pairs to check for the before/after report and dry-run.
CHECKS=(
  "index_recommendations:evidence_count"
  "index_recommendations:workload_score_ms"
  "index_recommendations:write_cost_score"
  "index_recommendations:kind"
  "index_recommendations:occurrence_count"
  "index_recommendations:hypopg_before_cost"
  "users:account_status"
  "schema_documentation:source"
  "encrypted_credentials:enable_data_sampling"
  "query_fingerprints:normalization_version"
  "resource_limits:slow_query_history_retention_days"
  "ingestion_jobs:truncated"
)

column_exists() {
  local tbl="$1" col="$2" out
  out="$(psql_q "SELECT 1 FROM information_schema.columns WHERE table_name='$tbl' AND column_name='$col' LIMIT 1;")"
  [[ "$out" == "1" ]]
}
table_exists() {
  local tbl="$1" out
  out="$(psql_q "SELECT to_regclass('public.$tbl') IS NOT NULL;")"
  [[ "$out" == "t" ]]
}

# Verify connectivity up front so a bad container/credential fails clearly.
[[ "$(psql_q 'SELECT 1;')" == "1" ]] || die "cannot query $DB_NAME on $PG_CONTAINER as $DB_USER"

echo "── Schema check (before) ──"
missing=0
for pair in "${CHECKS[@]}"; do
  tbl="${pair%%:*}"; col="${pair##*:}"
  if ! table_exists "$tbl"; then
    printf '  %-55s %s\n' "$tbl.$col" "skip (table absent)"
    continue
  fi
  if column_exists "$tbl" "$col"; then
    printf '  %-55s %s\n' "$tbl.$col" "ok"
  else
    printf '  %-55s %s\n' "$tbl.$col" "MISSING"
    missing=$((missing + 1))
  fi
done
echo

if [[ $missing -eq 0 ]]; then
  echo "No drift detected — every checked column is present. Nothing to do."
  exit 0
fi

if [[ $DRY_RUN -eq 1 ]]; then
  echo "Dry run: $missing column(s) missing. Re-run without --dry-run to reconcile."
  exit 0
fi

echo "── Reconciling ($missing column(s) missing) ──"
if psql_exec "$RECONCILE_SQL"; then
  echo "Applied."
else
  die "reconcile failed; capture the output above and escalate"
fi
echo

echo "── Schema check (after) ──"
still_missing=0
for pair in "${CHECKS[@]}"; do
  tbl="${pair%%:*}"; col="${pair##*:}"
  table_exists "$tbl" || continue
  if column_exists "$tbl" "$col"; then
    printf '  %-55s %s\n' "$tbl.$col" "ok"
  else
    printf '  %-55s %s\n' "$tbl.$col" "STILL MISSING"
    still_missing=$((still_missing + 1))
  fi
done
echo

if [[ $still_missing -eq 0 ]]; then
  echo "Done. Re-run 'deepsql indexes health' / 'deepsql indexes list' to confirm recovery."
  echo "No backend restart is required."
else
  die "$still_missing column(s) still missing after reconcile — capture output and escalate"
fi
