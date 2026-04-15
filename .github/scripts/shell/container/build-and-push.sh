#!/usr/bin/env bash
# ============================================================
# build-and-push.sh
#
# Facade: sources domain libraries, validates required environment,
# builds the BP context object, and dispatches the requested command
# (build | scan | push) via a registry.
#
# All environment variable access is isolated to main().
# Domain logic lives in the _lib_*.sh siblings.
#
# Step-to-step data flow:
#   build  → writes container_image_name_ghcr to GITHUB_OUTPUT
#   scan   → reads INPUT_IMAGE_NAME (set by action.yml from build output)
#   push   → reads INPUT_IMAGE_NAME (set by action.yml from build output)
# ============================================================
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib_context.sh
source "${SCRIPTS_DIR}/_lib_context.sh"
# shellcheck source=_lib_env_parser.sh
source "${SCRIPTS_DIR}/_lib_env_parser.sh"
# shellcheck source=_lib_build.sh
source "${SCRIPTS_DIR}/_lib_build.sh"
# shellcheck source=_lib_scan_push.sh
source "${SCRIPTS_DIR}/_lib_scan_push.sh"

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
#               Validates required env vars, constructs the BP context,
#               and dispatches to the requested command handler via a
#               registry. Unknown commands print usage and exit 1.
#
# @param $1     command - One of: build | scan | push
# @exitcode     0  Command completed successfully.
# @exitcode     1  Unknown command, missing env var, or handler failure.
# ------------------------------------------------------------
# main()
# -------
# Entry point function that orchestrates the container build and push workflow.
#
# This function performs the following operations:
# 1. Validates required environment variables (GITHUB_REPOSITORY, GITHUB_SHA, GITHUB_REF_NAME, etc.)
# 2. Initializes a build context associative array (BP_CTX) populated with configuration parameters
#    including security settings, deployment info, Trivy scan configuration, and image details
# 3. Maps command names to their corresponding handler functions:
#    - "build" -> cmd_build
#    - "scan"  -> cmd_scan
#    - "push"  -> cmd_push
# 4. Retrieves the command from the first positional argument
# 5. Looks up the appropriate handler function for the given command
# 6. Executes the handler function with the build context as an argument,
#    or exits with error code 1 if the command is invalid
#
# Parameters:
#   $1 - Command to execute (build|scan|push)
#
# Exit Codes:
#   0 - Success (handler function completed successfully)
#   1 - Invalid command provided
#
# Environment Variables Required:
#   GITHUB_REPOSITORY, GITHUB_SHA, GITHUB_REF_NAME, GITHUB_WORKSPACE, GITHUB_OUTPUT
#
# Environment Variables Optional:
#   INPUT_SECURITY_ALLOW_PUSH_TO_GHCR, INPUT_IS_SINGLE_BRANCH_DEPLOYMENT,
#   INPUT_TRIVY_SEVERITY, INPUT_TRIVY_EXIT_CODE, INPUT_TRIVY_IGNORE_UNFIXED,
#   GITHUB_ACTOR, GITHUB_RUN_ID, INPUT_IMAGE_NAME
main() {
  _require_env "GITHUB_REPOSITORY"
  _require_env "GITHUB_SHA"
  _require_env "GITHUB_REF_NAME"
  _require_env "GITHUB_WORKSPACE"
  _require_env "GITHUB_OUTPUT"

  declare -A BP_CTX
  ctx_build BP_CTX \
    "${INPUT_SECURITY_ALLOW_PUSH_TO_GHCR:-}" \
    "${INPUT_IS_SINGLE_BRANCH_DEPLOYMENT:-}" \
    "${INPUT_TRIVY_SEVERITY:-}" \
    "${INPUT_TRIVY_EXIT_CODE:-}" \
    "${INPUT_TRIVY_IGNORE_UNFIXED:-}" \
    "${GITHUB_REF_NAME}" \
    "${GITHUB_REPOSITORY}" \
    "${GITHUB_SHA}" \
    "${GITHUB_WORKSPACE}" \
    "${GITHUB_ACTOR:-}" \
    "${GITHUB_RUN_ID:-}" \
    "${GITHUB_OUTPUT}" \
    "${INPUT_IMAGE_NAME:-}"

  declare -A _CMD_REGISTRY=(
    ["build"]="cmd_build"
    ["scan"]="cmd_scan"
    ["push"]="cmd_push"
  )

  local command="${1:-}"
  local handler="${_CMD_REGISTRY[${command}]:-}"

  if [[ -z "${handler}" ]]; then
    log_error "Usage: $(basename "$0") {build|scan|push}"
    exit 1
  fi

  "${handler}" "BP_CTX"
}

main "$@"
