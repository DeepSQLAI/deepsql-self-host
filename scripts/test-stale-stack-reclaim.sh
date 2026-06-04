#!/usr/bin/env bash
#
# test-stale-stack-reclaim.sh - hermetic unit test for the installer's
# reclaim_stale_project_stacks() function.
#
# WHAT IT PROVES
#   On upgrade, the installer AUTO-RECLAIMS a stale DeepSQL stack that is
#   running under a DIFFERENT Compose project name (the #1 cause of the
#   "port already allocated" failure operators hit when upgrading an install
#   that predates the `name: deepsql-selfhost` pin), while:
#     1. removing ONLY that stack's containers (frees the host ports),
#     2. NEVER removing any volume (customer data is preserved), and
#     3. NEVER touching an unrelated Compose project that merely happens to
#        have a service literally named "postgres"/"backend" (the false-
#        positive footgun that made the original code warn-only).
#     4. NEVER touching our OWN canonical project.
#
# WHY A STUB INSTEAD OF A REAL UPGRADE
#   The risk in this change is the SCOPING decision (what counts as "a stale
#   DeepSQL stack"), not Docker mechanics. We stub `docker` with a fake on
#   PATH that returns canned `ps` output and records every `rm`/`volume`
#   call, then assert the function makes the right decisions. Runs in <1s,
#   needs no Docker daemon and pulls no images. The full port-collision
#   integration path is covered by the upgrade-drift E2E family.
#
# USAGE
#   ./scripts/test-stale-stack-reclaim.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/install.sh"

PASS_COUNT=0
FAIL_COUNT=0
log()  { printf '\n\033[1;36m> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m[PASS] %s\033[0m\n' "$*"; PASS_COUNT=$((PASS_COUNT+1)); }
bad()  { printf '  \033[31m[FAIL] %s\033[0m\n' "$*"; FAIL_COUNT=$((FAIL_COUNT+1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/reclaim-test.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Extract just reclaim_stale_project_stacks() from the real install.sh and
# source it. Sourcing install.sh wholesale would run the entire installer, so
# we slice the single function (header line through its column-0 closing brace)
# and eval that. This keeps the test bound to the SHIPPING implementation.
# ---------------------------------------------------------------------------
fn_src="$(awk '/^reclaim_stale_project_stacks\(\) \{/{capture=1} capture{print} /^\}/{if(capture)exit}' "$INSTALL_SH")"
if [[ -z "$fn_src" ]]; then
  echo "Could not find reclaim_stale_project_stacks() in $INSTALL_SH" >&2
  echo "(This test is RED until that function exists - that is expected pre-fix.)" >&2
  exit 1
fi
# shellcheck disable=SC1090
eval "$fn_src"

PROJECT_NAME="deepsql-selfhost"   # the canonical name the function protects
RECLAIMED_PROJECTS=""             # global the installer declares; reclaim appends to it

# ---------------------------------------------------------------------------
# Fake `docker`. Reads canned container inventory from $FAKE_DOCKER_PS
# (lines: project<TAB>service<TAB>image) and records mutating calls to
# $FAKE_DOCKER_CALLS. Synthesizes container ids as "<project>-<service>-1".
# ---------------------------------------------------------------------------
FAKE_DOCKER_PS="$WORK/ps.tsv"
FAKE_DOCKER_CALLS="$WORK/calls.log"
: > "$FAKE_DOCKER_CALLS"

cat > "$WORK/docker" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  ps)
    shift
    quiet=0; projfilter=""
    for a in "$@"; do
      case "$a" in
        -q|-aq) quiet=1 ;;
        label=com.docker.compose.project=*) projfilter="${a#label=com.docker.compose.project=}" ;;
      esac
    done
    if [[ "$quiet" == 1 ]]; then
      while IFS=$'\t' read -r p s _img; do
        [[ -z "${p:-}" ]] && continue
        [[ -n "$projfilter" && "$p" != "$projfilter" ]] && continue
        printf '%s-%s-1\n' "$p" "$s"
      done < "$FAKE_DOCKER_PS"
    else
      cat "$FAKE_DOCKER_PS"
    fi
    ;;
  stop)
    shift
    printf 'stop %s\n' "$*" >> "$FAKE_DOCKER_CALLS"
    ;;
  rm)
    shift
    printf 'rm %s\n' "$*" >> "$FAKE_DOCKER_CALLS"
    ;;
  volume)
    shift
    printf 'volume %s\n' "$*" >> "$FAKE_DOCKER_CALLS"
    ;;
  *)
    printf '%s\n' "$*" >> "$FAKE_DOCKER_CALLS"
    ;;
esac
FAKE
chmod +x "$WORK/docker"
export FAKE_DOCKER_PS FAKE_DOCKER_CALLS
export PATH="$WORK:$PATH"

# ---------------------------------------------------------------------------
# Canned inventory: three projects coexisting at upgrade time.
#   deepsql-selfhost : our OWN new stack (the keep target) -> never touched
#   self-host        : stale DeepSQL full stack, our images -> RECLAIM
#   acme-db          : unrelated project, has a "postgres" + "backend" service
#                      on non-DeepSQL images, NOT a full stack -> WARN only
# (tabs are literal between columns)
# ---------------------------------------------------------------------------
printf '%s\n' \
"deepsql-selfhost	postgres	pgvector/pgvector:pg18" \
"deepsql-selfhost	valkey	valkey/valkey:9.0.3" \
"deepsql-selfhost	backend	ghcr.io/deepsqlai/deepsql-self-host-backend:1.3.1" \
"deepsql-selfhost	frontend	ghcr.io/deepsqlai/deepsql-self-host-frontend:1.3.1" \
"self-host	postgres	pgvector/pgvector:pg18" \
"self-host	valkey	valkey/valkey:9.0.3" \
"self-host	backend	ghcr.io/deepsqlai/deepsql-self-host-backend:1.3.0" \
"self-host	frontend	ghcr.io/deepsqlai/deepsql-self-host-frontend:1.3.0" \
"acme-db	postgres	postgres:16" \
"acme-db	backend	acme/internal-api:latest" \
  > "$FAKE_DOCKER_PS"

log "Running reclaim_stale_project_stacks() against the canned inventory"
# Call in the CURRENT shell (output to a file, not a $(...) subshell) so the
# RECLAIMED_PROJECTS global it sets is observable for assertion 7.
reclaim_stale_project_stacks > "$WORK/out.txt" 2>&1 || true
out="$(cat "$WORK/out.txt")"
printf '%s\n' "$out" | sed 's/^/    /'
calls="$(cat "$FAKE_DOCKER_CALLS")"

log "Assertions"

# 1. The stale DeepSQL stack's FOUR containers are all removed.
removed_all_stale=true
for svc in postgres valkey backend frontend; do
  grep -q "self-host-${svc}-1" <<< "$calls" || removed_all_stale=false
done
if [[ "$removed_all_stale" == true ]] && grep -q '^rm ' <<< "$calls"; then
  ok "Stale 'self-host' stack reclaimed (all 4 containers removed)"
else
  bad "Stale 'self-host' containers were not all removed"
fi

# 2. No volume is EVER removed (data preserved).
if grep -q '^volume ' <<< "$calls"; then
  bad "A 'docker volume' command was issued - volumes must never be touched"
else
  ok "No volume was removed (customer data preserved)"
fi

# 2b. The stale Postgres is stopped GRACEFULLY (clean checkpoint) before any
# removal - and the stop precedes the rm in the call log.
stop_line="$(grep -n '^stop .*self-host-postgres-1' <<< "$calls" | head -1 | cut -d: -f1)"
rm_line="$(grep -n '^rm .*self-host-postgres-1' <<< "$calls" | head -1 | cut -d: -f1)"
if [[ -n "$stop_line" && -n "$rm_line" && "$stop_line" -lt "$rm_line" ]]; then
  ok "Stale Postgres stopped gracefully BEFORE removal (clean shutdown)"
elif [[ -n "$stop_line" && -z "$rm_line" ]]; then
  ok "Stale Postgres stopped gracefully (no forced kill)"
else
  bad "Stale Postgres was not gracefully stopped before removal"
fi

# 2c. No SIGKILL-first removal: a plain 'rm' (post graceful stop) is expected,
# not 'rm -f' on a still-running container.
if grep -q '^rm -f' <<< "$calls"; then
  bad "Forced 'rm -f' used on the primary path - graceful stop should precede removal"
else
  ok "Removal used a plain 'rm' after graceful stop (no SIGKILL-first)"
fi

# 3. The unrelated 'acme-db' project is never reclaimed.
if grep -q 'acme-db-' <<< "$calls"; then
  bad "Unrelated project 'acme-db' had containers removed (false positive!)"
else
  ok "Unrelated 'acme-db' project left untouched"
fi

# 4. Our OWN canonical project is never reclaimed.
if grep -q 'deepsql-selfhost-' <<< "$calls"; then
  bad "Canonical 'deepsql-selfhost' project had containers removed"
else
  ok "Canonical 'deepsql-selfhost' project left untouched"
fi

# 5. The reclaim is announced for the stale stack...
if grep -qi "Reclaiming stale DeepSQL stack under project 'self-host'" <<< "$out"; then
  ok "Reclaim announced for 'self-host'"
else
  bad "No reclaim announcement for 'self-host'"
fi

# 6. ...and the unrelated project is surfaced as a warning, not silently skipped.
if grep -q "acme-db" <<< "$out"; then
  ok "Unrelated 'acme-db' surfaced as a warning"
else
  bad "Unrelated 'acme-db' was not surfaced to the operator"
fi

# 7. The reclaimed project is handed to migrate (RECLAIMED_PROJECTS) so its
# prefixed volumes are carried forward - and the unrelated project is NOT.
if grep -qw "self-host" <<< "$RECLAIMED_PROJECTS" && ! grep -qw "acme-db" <<< "$RECLAIMED_PROJECTS"; then
  ok "RECLAIMED_PROJECTS handoff = '${RECLAIMED_PROJECTS# }' (migrate will rescue its data)"
else
  bad "RECLAIMED_PROJECTS handoff wrong: '${RECLAIMED_PROJECTS}'"
fi

log "Summary"
echo "  Passed: $PASS_COUNT   Failed: $FAIL_COUNT"
if [[ $FAIL_COUNT -eq 0 ]]; then
  printf '\n\033[1;32mPASS - auto-reclaim is scoped and volume-safe.\033[0m\n'
  exit 0
else
  printf '\n\033[1;31mFAIL - see assertions above.\033[0m\n'
  exit 1
fi
