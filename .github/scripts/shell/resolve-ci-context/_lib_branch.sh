#!/usr/bin/env bash
# ============================================================
# Domain: Branch Validation — pattern matching, version extraction,
#         Flutter pubspec alignment
# ============================================================

# ── Branch regex patterns ────────────────────────────────────
# Container: release|hotfix|bugfix/vX.Y.Z
readonly BRANCH_RELEASE_REGEX='^(release|hotfix|bugfix)/(v[0-9]+\.[0-9]+\.[0-9]+)$'

# Flutter:   release|hotfix|bugfix/vX.Y.Z+BUILD
readonly BRANCH_FLUTTER_REGEX='^(release|hotfix|bugfix)/(v[0-9]+\.[0-9]+\.[0-9]+\+([0-9]+))$'

# ------------------------------------------------------------
# @description  Reads the version field from pubspec.yaml using yq,
#               validates that it follows the X.Y.Z+BUILD format.
# @param $1     workspace - Absolute path to GITHUB_WORKSPACE.
# @stdout       Raw version string (e.g. '1.2.3+45').
# @return       0 on success; 1 if file is missing, yq absent, or format invalid.
# @example
#   # pubspec.yaml contains: version: 1.2.3+45
#   branch_flutter_read_pubspec_version "/workspace"
#   # Output: "1.2.3+45"
#
#   # pubspec.yaml is missing:
#   branch_flutter_read_pubspec_version "/workspace"
#   # return 1  — logs "pubspec.yaml not found"
# ------------------------------------------------------------
branch_flutter_read_pubspec_version() {
	local workspace="$1"
	local pubspec_file="${workspace}/pubspec.yaml"

	[[ -f "${pubspec_file}" ]] || {
		log_error "pubspec.yaml not found at '${pubspec_file}'"
		return 1
	}
	command -v yq >/dev/null 2>&1 || {
		log_error "'yq' is not installed or not in PATH"
		return 1
	}

	local version
	version="$(yq -r '.version' "${pubspec_file}")"

	[[ -n "${version}" && "${version}" != "null" ]] ||
		{
			log_error "Could not read '.version' from pubspec.yaml"
			return 1
		}

	[[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$ ]] ||
		{
			log_error "pubspec.yaml version '${version}' does not match expected format X.Y.Z+BUILD"
			return 1
		}

	echo "${version}"
}

# ------------------------------------------------------------
# @description  Extracts the numeric BUILD segment after '+' from a
#               Flutter version string (e.g. '1.2.3+45' → '45').
# @param $1     version - Version string in X.Y.Z+BUILD format.
# @stdout       The build number string.
# @return       0 on success, 1 if the +BUILD segment is absent.
# @example
#   branch_flutter_extract_build_number "1.2.3+45"
#   # Output: "45"
#
#   branch_flutter_extract_build_number "1.2.3"
#   # return 1  — logs "Could not extract build number"
# ------------------------------------------------------------
branch_flutter_extract_build_number() {
	local version="$1"

	if [[ "${version}" =~ \+([0-9]+)$ ]]; then
		echo "${BASH_REMATCH[1]}"
		return 0
	fi

	log_error "Could not extract build number from version '${version}'"
	return 1
}

# ------------------------------------------------------------
# @description  Returns 0 when a branch name starts with 'hotfix/'.
# @param $1     branch - The branch name to check.
# @return       0 if hotfix branch, 1 otherwise.
# @example
#   branch_is_hotfix "hotfix/v1.2.3"  && echo "hotfix"      # prints "hotfix"
#   branch_is_hotfix "release/v1.2.3" || echo "not hotfix"  # prints "not hotfix"
# ------------------------------------------------------------
branch_is_hotfix() { [[ "$1" =~ ^hotfix/ ]]; }

# ------------------------------------------------------------
# @description  Resolves the semantically active branch for the current event.
#               On pull_request events this is the head (source) branch.
#               On push and dispatch events this is the ref name.
# @param $1     event    - The GitHub event name.
# @param $2     head     - The PR head branch.
# @param $3     ref_name - The push/dispatch ref name.
# @stdout       The active branch name.
# @example
#   # On a pull_request event (head branch is the active one):
#   branch_resolve_active "pull_request" "release/v1.2.3" "main"
#   # Output: "release/v1.2.3"
#
#   # On a push event (the ref that was pushed is the active one):
#   branch_resolve_active "push" "" "main"
#   # Output: "main"
# ------------------------------------------------------------
branch_resolve_active() {
	local event="$1"
	local head="$2"
	local ref_name="$3"

	if ctx_is_pr "${event}"; then
		echo "${head}"
	else
		echo "${ref_name}"
	fi
}

# ------------------------------------------------------------
# @description  Validates a branch name against the release pattern for the
#               detected project type. For Flutter projects, also verifies
#               that the branch version matches pubspec.yaml.
#               Writes extracted version fields into an output associative array.
#
# @param $1     branch     - Branch name to validate.
# @param $2     context    - Label for log messages (e.g. 'PR → main').
# @param $3     is_flutter - '1' if Flutter project; '0' for container.
# @param $4     workspace  - Absolute path to GITHUB_WORKSPACE.
# @param $5     out_name   - Name of the caller's associative array (nameref).
#                            Written fields: release_version, release_version_number,
#                            build_number.
# @return       0 on valid branch; 1 on pattern mismatch or version conflict.
# @example
#   # Container project:
#   declare -A out=()
#   branch_validate_release "release/v1.2.3" "PR → main" "0" "/workspace" out
#   # out[release_version]="v1.2.3"
#   # out[release_version_number]="1.2.3"
#   # out[build_number]=""
#
#   # Flutter project with pubspec.yaml version: 1.2.3+45
#   declare -A fout=()
#   branch_validate_release "release/v1.2.3+45" "PR → main" "1" "/workspace" fout
#   # fout[release_version]="v1.2.3+45"
#   # fout[release_version_number]="1.2.3+45"
#   # fout[build_number]="45"
#
#   # Invalid branch name:
#   branch_validate_release "feature/my-change" "PR → main" "0" "/workspace" out
#   # return 1  — logs pattern mismatch error
# ------------------------------------------------------------
branch_validate_release() {
	local branch="$1"
	local context="$2"
	local is_flutter="$3"
	local workspace="$4"
	local -n _bvr_out="$5"

	local regex
	if [[ "${is_flutter}" == "1" ]]; then
		regex="${BRANCH_FLUTTER_REGEX}"
	else
		regex="${BRANCH_RELEASE_REGEX}"
	fi

	if [[ ! "${branch}" =~ ${regex} ]]; then
		log_error "[${context}] Branch '${branch}' does not match pattern: ${regex}"
		return 1
	fi

	# BASH_REMATCH capture groups from the matched regex:
	#   [0] full match  (e.g. 'release/v1.2.3')
	#   [1] branch type (e.g. 'release' | 'hotfix' | 'bugfix')
	#   [2] version     (e.g. 'v1.2.3'  or 'v1.2.3+45' for Flutter)
	#   [3] build num   (Flutter only, e.g. '45')
	local version_with_v="${BASH_REMATCH[2]}"
	local version_without_v="${version_with_v#v}"

	if [[ "${is_flutter}" == "1" ]]; then
		local pubspec_version
		pubspec_version="$(branch_flutter_read_pubspec_version "${workspace}")" || return 1

		[[ "${pubspec_version}" == "${version_without_v}" ]] ||
			{
				log_error "[${context}] Branch version '${version_without_v}' does not match pubspec.yaml '${pubspec_version}'"
				return 1
			}

		local build_number
		build_number="$(branch_flutter_extract_build_number "${version_without_v}")" || return 1

		_bvr_out[build_number]="${build_number}"
		log_ok "[${context}] Flutter branch valid; pubspec aligned; build=${build_number}"
	else
		_bvr_out[build_number]=""
		log_ok "[${context}] Branch valid: ${branch} → version=${version_with_v}"
	fi

	_bvr_out[release_version]="${version_with_v}"
	_bvr_out[release_version_number]="${version_without_v}"
}
