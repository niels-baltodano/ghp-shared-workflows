#!/usr/bin/env bash
# ============================================================
# resolve-ci-context.sh
#
# Facade: sources domain libraries, validates required environment,
# builds the CI context object, evaluates branch/event policy,
# and exports GitHub Actions outputs.
#
# All environment variable access is isolated to main().
# Domain logic lives in the _lib_*.sh siblings.
# ============================================================
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib_context.sh
source "${SCRIPTS_DIR}/_lib_context.sh"
# shellcheck source=_lib_branch.sh
source "${SCRIPTS_DIR}/_lib_branch.sh"
# shellcheck source=_lib_policy.sh
source "${SCRIPTS_DIR}/_lib_policy.sh"
# shellcheck source=_lib_output.sh
source "${SCRIPTS_DIR}/_lib_output.sh"

readonly EXIT_ERROR=1

# ── Logging ───────────────────────────────────────────────────

log_info()  { echo "ℹ️  $*" >&2; }
log_ok()    { echo "✅ $*" >&2; }
log_warn()  { echo "⚠️  $*" >&2; }
log_error() { echo "❌ $*" >&2; }

# ── Environment guard ────────────────────────────────────────

_require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] && return 0
  log_error "Required variable '${name}' is not set."
  exit "${EXIT_ERROR}"
}

# ── Entry point ──────────────────────────────────────────────

# ------------------------------------------------------------
# @description  Entry point and sole owner of environment variable access.
#               Validates required env vars, constructs the CI context
#               from GitHub Actions environment, evaluates the branch and
#               event policy, then exports all outputs.
#
# @exitcode     0  Pipeline context resolved (should_run may still be false).
# @exitcode     1  Required env var missing, unsupported target_action,
#                  or policy violation (invalid branch / duplicate tag).
# ------------------------------------------------------------
main() {
  _require_env "GITHUB_EVENT_NAME"
  _require_env "GITHUB_REF_NAME"
  _require_env "GITHUB_OUTPUT"

  declare -A CI_CTX
  ctx_build CI_CTX \
    "${GITHUB_EVENT_NAME}" \
    "${GITHUB_HEAD_REF:-}" \
    "${GITHUB_BASE_REF:-}" \
    "${GITHUB_REF_NAME}" \
    "${INPUT_TARGET_ACTION:-}" \
    "${GITHUB_SHA:-}" \
    "${GITHUB_REPOSITORY:-}"

  if ! ctx_validate_target "${CI_CTX[${CTX_F_TARGET}]}"; then
    log_error "Unsupported target_action: '${CI_CTX[${CTX_F_TARGET}]}'"
    exit "${EXIT_ERROR}"
  fi

  local is_flutter="0"
  ctx_is_flutter_project "${GITHUB_WORKSPACE:-}" && is_flutter="1"

  policy_evaluate "CI_CTX" "${GITHUB_WORKSPACE:-}" "${is_flutter}"

  output_export  "CI_CTX" "${GITHUB_WORKSPACE:-}" "${GITHUB_OUTPUT}"
  output_summary "CI_CTX" "${GITHUB_WORKSPACE:-}"
}

main "$@"
