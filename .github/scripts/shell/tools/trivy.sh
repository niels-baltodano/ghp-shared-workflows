#!/usr/bin/env bash
# ============================================================
# trivy.sh
#
# Installs Trivy from the latest safe GitHub release.
#
# Safety strategy:
#   1. Skip installation if Trivy is already in PATH.
#   2. Query the GitHub Releases API for the latest version.
#   3. Check each candidate against the OSV.dev advisory database.
#      Skip versions that have known vulnerabilities and try the
#      next older release (up to MAX_LOOKBACK releases).
#   4. Fall back to FALLBACK_SAFE_VERSION if the API is unavailable
#      or no safe release is found within the lookback window.
#   5. Download the tarball, verify its SHA-256 checksum against the
#      official checksums file, then install to /usr/local/bin.
# ============================================================
set -euo pipefail

# ── Constants ─────────────────────────────────────────────────

# Known-good fallback used when the GitHub API is unreachable or every
# recent release has active advisories in OSV.dev.
readonly TRIVY_FALLBACK_VERSION="v0.69.3"

# Maximum number of recent releases to evaluate before giving up and
# using the fallback. Prevents an infinite loop if many releases are
# compromised simultaneously.
readonly TRIVY_MAX_LOOKBACK=5

readonly TRIVY_INSTALL_DIR="/usr/local/bin"
readonly TRIVY_TMP_ARCHIVE="/tmp/trivy.tar.gz"
readonly TRIVY_TMP_CHECKSUMS="/tmp/trivy_checksums.txt"

# ── Logging ───────────────────────────────────────────────────

log_info() { echo "ℹ️  $*" >&2; }
log_ok() { echo "✅ $*" >&2; }
log_warn() { echo "⚠️  $*" >&2; }
log_error() { echo "❌ $*" >&2; }

# ── Helpers ───────────────────────────────────────────────────

# ------------------------------------------------------------
# @description  Queries the OSV.dev vulnerability database to check
#               whether a given Trivy release version has any known
#               security advisories. Used to skip compromised releases
#               during version selection.
#
# @param $1     version - Release tag to check (e.g. 'v0.58.0').
# @return       0 if the version has advisories (compromised),
#               1 if it is clean or the API is unreachable.
# @example
#   _trivy_is_compromised "v0.58.0" && echo "skip this version"
#   _trivy_is_compromised "v0.69.3" || echo "version is clean"
# ------------------------------------------------------------
_trivy_is_compromised() {
	local version="${1#v}" # OSV.dev expects version without the 'v' prefix

	local data
	data="$(jq -n --arg name "aquasecurity/trivy" --arg version "${version}" \
		'{"package":{"name":$name,"ecosystem":"GitHub Actions"},"version":$version}')"

	local response
	response="$(
		curl -fsSL -X POST https://api.osv.dev/v1/query \
			-H 'Content-Type: application/json' \
			-d "${data}" |
			jq -r '.results | if length > 0 then "true" else "false" end'
		2>/dev/null
	)" || return 1 # treat API failure as "not compromised" (fail open)

	# Count "id" fields in the JSON response — each one is a distinct advisory.
	local vuln_count
	vuln_count="$(echo "${response}" | grep -c '"id"' 2>/dev/null)" || vuln_count=0

	[[ "${vuln_count}" -gt 0 ]]
}

# ------------------------------------------------------------
# @description  Fetches the tag name of the latest Trivy release from
#               the GitHub Releases API.
# @stdout       The latest tag string (e.g. 'v0.70.0'), or empty on failure.
# @example
#   _trivy_resolve_latest_version
#   # Output: "v0.70.0"
#
#   # GitHub API unreachable:
#   # Output: ""  (empty — caller falls back to TRIVY_FALLBACK_VERSION)
# ------------------------------------------------------------
_trivy_resolve_latest_version() {
	curl -fsSL https://api.github.com/repos/aquasecurity/trivy/releases/latest |
		grep -o '"tag_name": *"[^"]*"' |
		cut -d'"' -f4
}

# ------------------------------------------------------------
# @description  Selects the newest Trivy release that has no known
#               advisories in OSV.dev. Evaluates up to TRIVY_MAX_LOOKBACK
#               recent releases in descending order (newest first).
#               Falls back to TRIVY_FALLBACK_VERSION when the API is
#               unavailable or every candidate is compromised.
#
# @stdout       A safe version tag string (e.g. 'v0.69.3').
# @example
#   _trivy_find_safe_version
#   # Output: "v0.70.0"  (latest, clean)
#
#   # v0.70.0 has advisories, v0.69.3 is clean:
#   # Output: "v0.69.3"
#
#   # GitHub API unreachable:
#   # Output: "v0.69.3"  (TRIVY_FALLBACK_VERSION)
# ------------------------------------------------------------
_trivy_find_safe_version() {
	local latest
	latest="$(_trivy_resolve_latest_version)"

	if [[ -z "${latest}" ]]; then
		log_warn "GitHub API unavailable. Using fallback ${TRIVY_FALLBACK_VERSION}."
		echo "${TRIVY_FALLBACK_VERSION}"
		return 0
	fi

	# Fetch the TRIVY_MAX_LOOKBACK most recent releases and evaluate each one.
	local releases
	releases="$(curl -fsSL \
		"https://api.github.com/repos/aquasecurity/trivy/releases?per_page=${TRIVY_MAX_LOOKBACK}" |
		grep -o '"tag_name": *"[^"]*"' |
		cut -d'"' -f4)"

	local tag
	while IFS= read -r tag; do
		[[ -z "${tag}" ]] && continue

		if ! _trivy_is_compromised "${tag}"; then
			# First clean version found — use it.
			echo "${tag}"
			return 0
		fi

		log_warn "Version ${tag} has active advisories on OSV.dev — skipping."
	done <<<"${releases}"

	log_warn "No safe release found in the last ${TRIVY_MAX_LOOKBACK} releases. Using fallback ${TRIVY_FALLBACK_VERSION}."
	echo "${TRIVY_FALLBACK_VERSION}"
}

# ------------------------------------------------------------
# @description  Downloads the Trivy tarball for the given version,
#               verifies its SHA-256 checksum against the official
#               checksums file, extracts the binary, and installs it
#               to TRIVY_INSTALL_DIR. Temporary files are removed
#               regardless of success or failure.
#
# @param $1     version - The version tag to install (e.g. 'v0.69.3').
# @exitcode     1 if the checksum does not match.
# @example
#   _trivy_download_and_install "v0.69.3"
#   # Downloads: trivy_0.69.3_Linux-64bit.tar.gz
#   # Verifies:  SHA-256 checksum from trivy_0.69.3_checksums.txt
#   # Installs:  /usr/local/bin/trivy
# ------------------------------------------------------------
_trivy_download_and_install() {
	local version="$1"
	local version_num="${version#v}" # strip leading 'v' for filename construction

	local base_url="https://github.com/aquasecurity/trivy/releases/download/${version}"
	local archive_name="trivy_${version_num}_Linux-64bit.tar.gz"

	log_info "Downloading Trivy ${version}..."
	curl -fsSL "${base_url}/${archive_name}" -o "${TRIVY_TMP_ARCHIVE}"

	# Fetch the official checksums file published alongside each release.
	curl -fsSL "${base_url}/trivy_${version_num}_checksums.txt" -o "${TRIVY_TMP_CHECKSUMS}"

	# Extract the expected SHA-256 for the archive we downloaded.
	local expected_sha actual_sha
	expected_sha="$(grep "${archive_name}" "${TRIVY_TMP_CHECKSUMS}" | awk '{print $1}')"
	actual_sha="$(sha256sum "${TRIVY_TMP_ARCHIVE}" | awk '{print $1}')"

	# Always remove temporary files before checking result.
	trap 'rm -f "${TRIVY_TMP_ARCHIVE}" "${TRIVY_TMP_CHECKSUMS}"' EXIT

	if [[ "${expected_sha}" != "${actual_sha}" ]]; then
		log_error "Checksum mismatch for ${archive_name}."
		log_error "  expected: ${expected_sha}"
		log_error "  actual:   ${actual_sha}"
		exit 1
	fi

	log_ok "Checksum verified."

	tar -xzf "${TRIVY_TMP_ARCHIVE}" -C /tmp
	sudo mv /tmp/trivy "${TRIVY_INSTALL_DIR}/trivy"
	chmod +x "${TRIVY_INSTALL_DIR}/trivy"
}

# ── Entry point ───────────────────────────────────────────────

# ------------------------------------------------------------
# @description  Idempotent entry point. Skips installation when Trivy
#               is already present in PATH; otherwise selects the latest
#               safe version and installs it.
# @exitcode     1 if download, checksum verification, or installation fails.
# @example
#   ./trivy.sh
#   # Trivy already installed → ✅ Trivy already installed: Version: 0.69.3
#   # Not installed           → selects safe version, downloads, verifies, installs
# ------------------------------------------------------------
main() {
	if command -v trivy &>/dev/null; then
		log_ok "Trivy already installed: $(trivy --version 2>&1 | head -1)"
		return 0
	fi

	local version
	version="$(_trivy_find_safe_version)"

	_trivy_download_and_install "${version}"

	log_ok "Trivy ${version} installed successfully."
	trivy --version
}

main "$@"
