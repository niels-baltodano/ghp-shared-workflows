#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Constants
# ============================================================

readonly SEMVER_REGEX='^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
readonly EXIT_ERROR=1

# ============================================================
# Logging
# ============================================================

log() {
	local level="$1"
	shift
	local -A prefixes=(
		[info]="ℹ️ "
		[ok]="✅"
		[warn]="⚠️ "
		[error]="❌"
	)
	echo "${prefixes[${level}]:-[${level}]} $*" >&2
}

# ============================================================
# Guards
# ============================================================

require_non_empty() {
	local value="$1"
	local name="$2"

	if [[ -z "${value}" ]]; then
		log error "${name} is not set."
		exit "${EXIT_ERROR}"
	fi
}

# ============================================================
# Validators — return 0 (ok) or 1 (fail); params only; no env access
# Uniform signature: fn(version repo)
# ============================================================

validate_semver_format() {
	local version="$1"
	local _repo="$2" # unused — uniform registry signature

	require_non_empty "${version}" "INPUT_RELEASE_VERSION"

	if [[ ! "${version}" =~ ${SEMVER_REGEX} ]]; then
		log error "Version '${version}' does not conform to semver (vMAJOR.MINOR.PATCH[-pre][+build])."
		return 1
	fi

	log ok "Version '${version}' is valid semver."
}

validate_tag_absent() {
	local version="$1"
	local repo="$2"

	require_non_empty "${repo}" "GITHUB_REPOSITORY"
	log info "Checking tag '${version}' in '${repo}'..."

	if gh api "repos/${repo}/git/ref/tags/${version}" &>/dev/null; then
		log error "Tag '${version}' already exists in '${repo}'."
		return 1
	fi

	log ok "Tag '${version}' does not exist. Safe to create."
}

validate_release_absent() {
	local version="$1"
	local repo="$2"

	require_non_empty "${repo}" "GITHUB_REPOSITORY"
	log info "Checking release '${version}' in '${repo}'..."

	if gh release view "${version}" --repo "${repo}" &>/dev/null; then
		log error "Release '${version}' already exists in '${repo}'."
		return 1
	fi

	log ok "Release '${version}' does not exist. Safe to create."
}

# ============================================================
# Registry Runner
#
# Semver is a hard precondition — exits immediately on failure.
# Existence checks both run regardless of each other so downstream
# always receives the full state (tag_exists, release_exists).
# Uses namerefs to write results back into caller's scope.
# ============================================================

run_validators() {
	local version="$1"
	local repo="$2"
	local -n _tag_exists="$3"
	local -n _release_exists="$4"

	validate_semver_format "${version}" "${repo}" || exit "${EXIT_ERROR}"

	if ! validate_tag_absent "${version}" "${repo}"; then
		_tag_exists="true"
	fi

	if ! validate_release_absent "${version}" "${repo}"; then
		_release_exists="true"
	fi

	[[ "${_tag_exists}" == "false" && "${_release_exists}" == "false" ]]
}

# ============================================================
# Outputs
# ============================================================

export_outputs() {
	local output_file="$1"
	local result="$2"
	local tag_exists="$3"
	local release_exists="$4"

	{
		echo "validation_result=${result}"
		echo "tag_exists=${tag_exists}"
		echo "release_exists=${release_exists}"
	} >>"${output_file}"
}

print_summary() {
	local version="$1"
	local repo="$2"
	local result="$3"
	local tag_exists="$4"
	local release_exists="$5"

	printf '\n%s\n' "════════════════════════════════════════"
	printf '  %s\n' "Tag & Release Validation Summary"
	printf '%s\n' "════════════════════════════════════════"
	printf '  %-18s = %s\n' "repository" "${repo}"
	printf '  %-18s = %s\n' "release_version" "${version}"
	printf '  %-18s = %s\n' "tag_exists" "${tag_exists}"
	printf '  %-18s = %s\n' "release_exists" "${release_exists}"
	printf '  %-18s = %s\n' "result" "${result}"
	printf '%s\n' "════════════════════════════════════════"
}

# ============================================================
# Main — sole owner of env var access; assembles context; orchestrates
# ============================================================

main() {
	local version="${INPUT_RELEASE_VERSION:-}"
	local repo="${GITHUB_REPOSITORY:-}"
	local output_file="${GITHUB_OUTPUT:-}"
	local tag_exists="false"
	local release_exists="false"
	local result="failed"

	if run_validators "${version}" "${repo}" tag_exists release_exists; then
		result="passed"
	fi

	export_outputs "${output_file}" "${result}" "${tag_exists}" "${release_exists}"
	print_summary "${version}" "${repo}" "${result}" "${tag_exists}" "${release_exists}"

	[[ "${result}" == "passed" ]] || exit "${EXIT_ERROR}"
}

main
