#!/usr/bin/env bash
# ============================================================
# tag-and-release-validator.sh
#
# Facade: sources domain library, validates required environment,
# builds the TRV context object, runs the validator registry,
# and exports GitHub Actions outputs.
#
# All environment variable access is isolated to main().
# Domain logic lives in _lib_validator.sh.
# ============================================================
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib_validator.sh
source "${SCRIPTS_DIR}/_lib_validator.sh"

# ── Logging ───────────────────────────────────────────────────

log_info() { echo "ℹ️  $*" >&2; }
log_ok() { echo "✅ $*" >&2; }
log_warn() { echo "⚠️  $*" >&2; }
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
#               Validates required env vars, constructs the TRV context,
#               runs the validator registry, exports outputs, and exits
#               non-zero when validation fails.
#
# @exitcode     0  All validators passed (semver valid, tag and release absent).
# @exitcode     1  Required env var missing, invalid semver format,
#                  or tag / release already exists.
# ------------------------------------------------------------
main() {
	_require_env "INPUT_RELEASE_VERSION"
	_require_env "GITHUB_REPOSITORY"
	_require_env "GITHUB_OUTPUT"

	declare -A TRV_CTX
	ctx_build TRV_CTX \
		"${INPUT_RELEASE_VERSION}" \
		"${GITHUB_REPOSITORY}" \
		"${GITHUB_OUTPUT}"

	validators_run "TRV_CTX"

	output_export "TRV_CTX"
	output_summary "TRV_CTX"

	[[ "${TRV_CTX[${TRV_F_RESULT}]}" == "passed" ]] || exit 1
}

main "$@"
