#!/usr/bin/env bash
#
# test-image-pin-downgrade-guard.sh — regression test for bump_image_pins_from_release().
#
# A field report found that a release whose bundled .env.example LAGGED the
# customer's pin (e.g. .env.example=1.3.1 while the customer ran 1.3.4) silently
# rolled the customer BACKWARD on `curl ... | bash`, logged misleadingly as
# "Upgrading". This proves:
#   - target > current  -> upgrade applied, labeled "Upgrading"
#   - target < current  -> DOWNGRADE BLOCKED by default (pin kept), labeled WARNING
#   - target < current + DEEPSQL_ALLOW_IMAGE_DOWNGRADE=true -> forced downgrade
#   - target == current  -> no-op
#   - non-semver target ("latest") -> applied, neutral label (direction unknown)
#
# Pattern mirrors test-volume-fork-detection.sh: extract the functions under
# test from the shipping installer and eval them (sourcing would run install).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${INSTALL_SH:-$SCRIPT_DIR/install.sh}"
WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

c_ok=$'\033[32m'; c_bad=$'\033[1;31m'; c_hd=$'\033[1;36m'; c_off=$'\033[0m'
log()  { printf '\n%s> %s%s\n' "$c_hd" "$1" "$c_off"; }
ok()   { printf '  %s[PASS] %s%s\n' "$c_ok" "$1" "$c_off"; }
bad()  { printf '  %s[FAIL] %s%s\n' "$c_bad" "$1" "$c_off"; FAILED=1; }
FAILED=0

extract_fn() {
  awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{"{c=1} c{print} /^\}/{if(c)exit}' "$INSTALL_SH"
}
for fn in env_value_for set_env_value image_pin_direction bump_image_pins_from_release; do
  src="$(extract_fn "$fn")"
  if [[ -z "$src" ]]; then echo "Could not find ${fn}() in $INSTALL_SH" >&2; exit 1; fi
  # shellcheck disable=SC1090
  eval "$src"
done

BK=DEEPSQL_BACKEND_IMAGE
FR=DEEPSQL_FRONTEND_IMAGE
REPO=ghcr.io/deepsqlai/deepsql-self-host-backend
REPOF=ghcr.io/deepsqlai/deepsql-self-host-frontend

# Writes a .env and .env.example pair into a fresh ROOT_DIR and runs the bump.
# Sets ROOT_DIR/ENV_FILE in the PARENT scope (no command substitution, which
# would subshell those assignments away) and captures stdout to $OUT.
OUT="$WORK/out.txt"
run_bump() {  # run_bump <env_tag> <example_tag> [allow_downgrade]
  local env_tag="$1" ex_tag="$2" allow="${3:-false}"
  ROOT_DIR="$WORK/case.$RANDOM"; mkdir -p "$ROOT_DIR"
  ENV_FILE="$ROOT_DIR/.env"
  printf '%s=%s:%s\n%s=%s:%s\n' "$BK" "$REPO" "$env_tag" "$FR" "$REPOF" "$env_tag" > "$ENV_FILE"
  printf '%s=%s:%s\n%s=%s:%s\n' "$BK" "$REPO" "$ex_tag"  "$FR" "$REPOF" "$ex_tag"  > "$ROOT_DIR/.env.example"
  DEEPSQL_ALLOW_IMAGE_DOWNGRADE="$allow" bump_image_pins_from_release >"$OUT" 2>&1
}
pin_tag() { env_value_for "$BK" "$ENV_FILE" | sed -E 's/.*://'; }

# 1. Upgrade
log "Case 1: target > current -> upgrade"
run_bump 1.3.4 1.3.6; out="$(cat "$OUT")"
[[ "$(pin_tag)" == "1.3.6" ]] && grep -q "Upgrading" <<<"$out" \
  && ok "1.3.4 -> 1.3.6 applied, labeled Upgrading" \
  || bad "expected upgrade to 1.3.6; pin=$(pin_tag) out=<<$out>>"

# 2. Downgrade blocked
log "Case 2: target < current -> blocked by default"
run_bump 1.3.6 1.3.1; out="$(cat "$OUT")"
[[ "$(pin_tag)" == "1.3.6" ]] && grep -qi "WARNING" <<<"$out" && grep -qi "older image" <<<"$out" \
  && ok "1.3.6 kept; release 1.3.1 refused with warning" \
  || bad "expected pin kept at 1.3.6 with warning; pin=$(pin_tag) out=<<$out>>"

# 3. Downgrade forced
log "Case 3: target < current + override -> forced downgrade"
run_bump 1.3.6 1.3.1 true; out="$(cat "$OUT")"
[[ "$(pin_tag)" == "1.3.1" ]] && grep -qi "forcing DOWNGRADE" <<<"$out" \
  && ok "override applied downgrade to 1.3.1" \
  || bad "expected forced downgrade to 1.3.1; pin=$(pin_tag) out=<<$out>>"

# 4. Equal
log "Case 4: target == current -> no-op"
run_bump 1.3.6 1.3.6; out="$(cat "$OUT")"
[[ "$(pin_tag)" == "1.3.6" ]] && ! grep -q "Upgrading" <<<"$out" \
  && ok "no change, no Upgrading line" \
  || bad "expected silent no-op; pin=$(pin_tag) out=<<$out>>"

# 5. Unknown (non-semver target)
log "Case 5: non-semver target -> applied, neutral label"
run_bump 1.3.6 latest; out="$(cat "$OUT")"
[[ "$(pin_tag)" == "latest" ]] && grep -q "Updating" <<<"$out" && ! grep -q "Upgrading" <<<"$out" \
  && ok "latest applied, labeled Updating (not Upgrading)" \
  || bad "expected neutral apply of :latest; pin=$(pin_tag) out=<<$out>>"

log "Summary"
if [[ $FAILED -eq 0 ]]; then
  printf '  Passed: 5   Failed: 0\n\n%sPASS - bump never silently downgrades.%s\n' "$c_ok" "$c_off"
else
  printf '\n%sFAIL - see assertions above.%s\n' "$c_bad" "$c_off"; exit 1
fi
