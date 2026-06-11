#!/usr/bin/env bash
#
# test-volume-fork-detection.sh - hermetic unit test for the installer's
# migration source-selection (classify_migration_source).
#
# WHAT IT PROVES
#   The installer NEVER silently picks one of several populated legacy volumes
#   and discards the rest. This guards the exact data-loss a client hit: an
#   upgrade where BOTH deepsql-selfhost_dba-agent-postgres (original bulk data)
#   and self-host_dba-agent-postgres (a fork holding later user config) were
#   populated. The old "first candidate with data wins" loop migrated the
#   original and silently stranded the fork.
#
#   Cases:
#     1. FORK   - >=2 populated candidates -> classified "fork" (caller halts).
#     2. SINGLE - exactly 1 populated candidate -> "single" (migrates it).
#     3. NONE   - no populated candidate -> "none" (skip).
#     4. OVERRIDE - DEEPSQL_VOLUME_SOURCE_<logical> forces a specific source,
#                   resolving a fork deterministically.
#     5. RECLAIMED - a reclaimed project's prefixed volume is a candidate.
#
# WHY A STUB
#   `docker` is faked on PATH: `volume inspect` answers from a known-volume
#   set, and the read-only `run ... alpine ls` (volume_has_data) answers from a
#   populated-volume set. No daemon, no images, runs in <1s.
#
# USAGE  ./scripts/test-volume-fork-detection.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/install.sh"

PASS_COUNT=0; FAIL_COUNT=0
log() { printf '\n\033[1;36m> %s\033[0m\n' "$*"; }
ok()  { printf '  \033[32m[PASS] %s\033[0m\n' "$*"; PASS_COUNT=$((PASS_COUNT+1)); }
bad() { printf '  \033[31m[FAIL] %s\033[0m\n' "$*"; FAIL_COUNT=$((FAIL_COUNT+1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fork-test.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# Extract the two functions under test from the shipping installer and eval
# them (sourcing the whole script would run the installer).
extract_fn() {
  awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{"{c=1} c{print} /^\}/{if(c)exit}' "$INSTALL_SH"
}
for fn in volume_has_data is_precious_volume volume_size_human volume_pg_last_write classify_migration_source migrate_prefixed_volumes_if_needed; do
  src="$(extract_fn "$fn")"
  if [[ -z "$src" ]]; then
    echo "Could not find ${fn}() in $INSTALL_SH" >&2
    echo "(RED until that function exists - expected pre-fix.)" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  eval "$src"
done

# ---- fake docker -----------------------------------------------------------
KNOWN="$WORK/known.txt"        # one volume name per line that "exists"
POP="$WORK/populated.txt"      # one volume name per line that "has data"
cat > "$WORK/docker" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  volume)
    if [[ "${2:-}" == "inspect" ]]; then
      grep -qx "${3:-}" "$KNOWN" && exit 0 || exit 1
    fi
    exit 0 ;;
  run)
    vol=""; prev=""
    for a in "$@"; do [[ "$prev" == "-v" ]] && vol="${a%%:*}"; prev="$a"; done
    grep -qx "$vol" "$POP" && echo "data"
    exit 0 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$WORK/docker"
export KNOWN POP
export PATH="$WORK:$PATH"

# ---- shared context the installer functions read ---------------------------
PROJECT_NAME="deepsql-selfhost"
RECLAIMED_PROJECTS=""
ROOT_DIR="/home/ec2-user/.deepsql/self-host"   # basename -> install_basename = self-host
LOGICAL="dba-agent-postgres"

set_volumes() { printf '%s\n' "$@" > "$KNOWN"; }
set_populated() { printf '%s\n' "$@" > "$POP"; }

verdict_of() { classify_migration_source "$LOGICAL" | cut -f1; }
payload_of() { classify_migration_source "$LOGICAL" | cut -f2; }

# === 1. FORK: original + fork both populated -> must NOT silently pick ========
log "Case 1: data fork (deepsql-selfhost_* AND self-host_* both populated)"
set_volumes "deepsql-selfhost_${LOGICAL}" "self-host_${LOGICAL}"
set_populated "deepsql-selfhost_${LOGICAL}" "self-host_${LOGICAL}"
v="$(verdict_of)"; p="$(payload_of)"
if [[ "$v" == "fork" ]] && grep -q "deepsql-selfhost_${LOGICAL}" <<<"$p" && grep -q "self-host_${LOGICAL}" <<<"$p"; then
  ok "fork detected, lists BOTH candidates ($p)"
else
  bad "expected fork listing both; got verdict='$v' payload='$p'"
fi

# === 2. SINGLE: only the original populated ==================================
log "Case 2: single populated candidate"
set_volumes "deepsql-selfhost_${LOGICAL}" "self-host_${LOGICAL}"
set_populated "deepsql-selfhost_${LOGICAL}"            # fork volume exists but EMPTY
if [[ "$(verdict_of)" == "single" && "$(payload_of)" == "deepsql-selfhost_${LOGICAL}" ]]; then
  ok "single -> deepsql-selfhost_${LOGICAL}"
else
  bad "expected single deepsql-selfhost_${LOGICAL}; got '$(verdict_of)' '$(payload_of)'"
fi

# === 3. NONE: nothing populated =============================================
log "Case 3: no populated candidate"
set_volumes "deepsql-selfhost_${LOGICAL}"
set_populated ""   # nothing has data
if [[ "$(verdict_of)" == "none" ]]; then
  ok "none"
else
  bad "expected none; got '$(verdict_of)'"
fi

# === 4. OVERRIDE: operator resolves the fork explicitly ======================
log "Case 4: DEEPSQL_VOLUME_SOURCE override resolves a fork"
set_volumes "deepsql-selfhost_${LOGICAL}" "self-host_${LOGICAL}"
set_populated "deepsql-selfhost_${LOGICAL}" "self-host_${LOGICAL}"
out="$(DEEPSQL_VOLUME_SOURCE_dba_agent_postgres="self-host_${LOGICAL}" classify_migration_source "$LOGICAL")"
if [[ "$(cut -f1 <<<"$out")" == "single" && "$(cut -f2 <<<"$out")" == "self-host_${LOGICAL}" ]]; then
  ok "override forces self-host_${LOGICAL}"
else
  bad "expected single self-host_${LOGICAL} via override; got '$out'"
fi

# === 5. RECLAIMED project volume is a candidate ==============================
log "Case 5: a reclaimed project's volume counts as a candidate"
RECLAIMED_PROJECTS=" deepsql-curl"
set_volumes "deepsql-curl_${LOGICAL}"
set_populated "deepsql-curl_${LOGICAL}"
if [[ "$(verdict_of)" == "single" && "$(payload_of)" == "deepsql-curl_${LOGICAL}" ]]; then
  ok "reclaimed deepsql-curl_${LOGICAL} selected"
else
  bad "expected single deepsql-curl_${LOGICAL}; got '$(verdict_of)' '$(payload_of)'"
fi
RECLAIMED_PROJECTS=""

# === 6. migrate_prefixed_volumes_if_needed ABORTS on a precious fork =========
# Proves the user-facing behavior: not just classification, but that the
# installer halts (exit !=0) with override guidance instead of silently
# migrating one volume and stranding the other. The destination absolute volume
# is absent (not in KNOWN), so migrate must populate it -> hits the fork.
log "Case 6: migrate halts (does not silently pick) on a Postgres fork"
set_volumes "deepsql-selfhost_${LOGICAL}" "self-host_${LOGICAL}"
set_populated "deepsql-selfhost_${LOGICAL}" "self-host_${LOGICAL}"
set +e
mig_out="$(migrate_prefixed_volumes_if_needed 2>&1)"; mig_rc=$?
set -e
if [[ $mig_rc -ne 0 ]] \
   && grep -q "Found MULTIPLE populated legacy volumes" <<<"$mig_out" \
   && grep -q "DEEPSQL_VOLUME_SOURCE_dba_agent_postgres" <<<"$mig_out"; then
  ok "migrate aborted (exit $mig_rc) with fork report + override hint"
else
  bad "expected migrate to abort with guidance; rc=$mig_rc out=<<$mig_out>>"
fi

log "Summary"
echo "  Passed: $PASS_COUNT   Failed: $FAIL_COUNT"
if [[ $FAIL_COUNT -eq 0 ]]; then
  printf '\n\033[1;32mPASS - migration never silently discards a populated fork.\033[0m\n'; exit 0
else
  printf '\n\033[1;31mFAIL - see assertions above.\033[0m\n'; exit 1
fi
