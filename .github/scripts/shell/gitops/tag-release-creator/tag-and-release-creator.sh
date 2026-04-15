#!/usr/bin/env bash
# ============================================================
# tag-and-release-creator.sh
#
# Facade: sources domain libraries, validates required environment,
# builds the TRC context object, and orchestrates tag creation,
# release creation, and output writing.
#
# All environment variable access is isolated to main().
# Domain logic lives in the _lib_*.sh siblings.
# ============================================================
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib_tag.sh
source "${SCRIPTS_DIR}/_lib_tag.sh"
# shellcheck source=_lib_release.sh
source "${SCRIPTS_DIR}/_lib_release.sh"

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
#               Validates required env vars, constructs the TRC context,
#               then runs the tag → release → output pipeline.
#
# @exitcode     0  Tag and release created successfully.
# @exitcode     1  Required env var missing, tag already exists,
#                  or GitHub API call failure.
# ------------------------------------------------------------
main() {
  _require_env "INPUT_RELEASE_VERSION"
  _require_env "GITHUB_REPOSITORY"
  _require_env "GITHUB_SHA"
  _require_env "INPUT_ENVIRONMENT"
  _require_env "GITHUB_OUTPUT"

  declare -A TRC_CTX
  ctx_build TRC_CTX \
    "${INPUT_RELEASE_VERSION}" \
    "${GITHUB_REPOSITORY}" \
    "${GITHUB_SHA}" \
    "${INPUT_ENVIRONMENT}" \
    "${GITHUB_OUTPUT}"

  tag_resolve_previous "TRC_CTX"
  release_create       "TRC_CTX"

  output_export  "TRC_CTX"
  output_summary "TRC_CTX"
}

main "$@"
