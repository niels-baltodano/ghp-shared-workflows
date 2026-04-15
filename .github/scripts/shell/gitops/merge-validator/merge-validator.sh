#!/usr/bin/env bash
# ============================================================
# merge-validator.sh
#
# Facade: sources domain libraries, validates required environment,
# builds the merge-validator context object, evaluates the branch
# freshness policy, and exports GitHub Actions outputs.
#
# All environment variable access is isolated to main().
# Domain logic lives in the _lib_*.sh siblings.
# ============================================================
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib_git.sh
source "${SCRIPTS_DIR}/_lib_git.sh"
# shellcheck source=_lib_policy.sh
source "${SCRIPTS_DIR}/_lib_policy.sh"

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
  exit 1
}

# ── Entry point ──────────────────────────────────────────────

# ------------------------------------------------------------
# @description  Entry point and sole owner of environment variable access.
#               Validates required env vars, constructs the merge-validator
#               context, evaluates the branch freshness policy, and writes
#               the result to GITHUB_OUTPUT.
#
# @exitcode     0  Validation completed (result may be 'skipped' or 'valid').
# @exitcode     1  Required env var missing, stale branch, or merge conflicts.
# ------------------------------------------------------------
main() {
  _require_env "GITHUB_EVENT_NAME"
  _require_env "GITHUB_REF_NAME"
  _require_env "GITHUB_OUTPUT"

  declare -A MV_CTX
  ctx_build MV_CTX \
    "${GITHUB_EVENT_NAME}" \
    "${GITHUB_HEAD_REF:-}" \
    "${GITHUB_BASE_REF:-}" \
    "${GITHUB_REF_NAME}" \
    "${INPUT_FETCH_DEPTH:-}" \
    "${INPUT_MAX_BEHIND:-}"

  policy_evaluate "MV_CTX"

  output_export  "MV_CTX" "${GITHUB_OUTPUT}"
  output_summary "MV_CTX"
}

main "$@"
