#!/usr/bin/env bash
# ============================================================
# Domain: Release — changelog generation, release creation,
#         and output writing
# ============================================================

# Placeholder used in the release body when no commit range is available
# (first release in the repo, or the previous tag SHA could not be resolved).
readonly TRC_NO_COMMITS_PLACEHOLDER="_No commits found._"

# ── Changelog helpers (pure: params only) ────────────────────

# ------------------------------------------------------------
# @description  Fetches the list of commits reachable from head_sha but
#               not from base_sha, formatted as one-line summaries with
#               direct commit URLs. Returns an empty string (not an error)
#               when the range is empty or the API call fails.
# @param $1     base_sha - SHA of the previous release tag (exclusive).
# @param $2     head_sha - SHA of the new release commit (inclusive).
# @param $3     repo     - GitHub repository slug (owner/repo).
# @stdout       Newline-separated commit entries, or empty string.
# @example
#   release_get_commits_between "def5678" "abc1234" "owner/repo"
#   # Output (one line per commit in the range):
#   #   Fix login timeout | https://github.com/owner/repo/commit/bcd2345
#   #   Add dark mode     | https://github.com/owner/repo/commit/abc1234
#
#   # Range is empty (base_sha == head_sha or API unavailable):
#   # Output: ""  (empty string, not an error)
# ------------------------------------------------------------
release_get_commits_between() {
	local base_sha="$1"
	local head_sha="$2"
	local repo="$3"

	gh api "repos/${repo}/compare/${base_sha}...${head_sha}" |
		jq -r --arg repo "${repo}" \
			'.commits[] | "\(.commit.message | split("\n")[0]) | https://github.com/\($repo)/commit/\(.sha)"' \
			2>/dev/null || true
}

# ------------------------------------------------------------
# @description  Builds the Markdown body for a GitHub release.
#               Pure function; all values are passed as parameters.
# @param $1     tag_name     - The release tag name (e.g. 'v1.2.3').
# @param $2     environment  - Target environment label.
# @param $3     date         - Build date string (e.g. '2026-04-16-10-00-00').
# @param $4     commits_body - Pre-formatted commit list or placeholder text.
# @stdout       Markdown-formatted release body.
# @example
#   release_build_body "v1.2.3" "dev" "2026-04-16-10-00-00" "Fix login bug | https://..."
#   # Output:
#   #   ## 🚀 Release `v1.2.3` generated automatically by CI/CD
#   #
#   #   📍 **Environment:** `dev`
#   #   📅 **Date:** 2026-04-16-10-00-00
#   #
#   #   ---
#   #
#   #   ### 📦 Included changes:
#   #
#   #   Fix login bug | https://...
#
#   # First release (no previous tag):
#   release_build_body "v1.0.0" "prod" "2026-04-16-10-00-00" "_No commits found._"
# ------------------------------------------------------------
release_build_body() {
	local tag_name="$1"
	local environment="$2"
	local date="$3"
	local commits_body="$4"

	printf '## 🚀 Release `%s` generated automatically by CI/CD\n\n' "${tag_name}"
	printf '📍 **Environment:** `%s`\n' "${environment}"
	printf '📅 **Date:** %s\n\n' "${date}"
	printf -- '---\n\n'
	printf '### 📦 Included changes:\n\n'
	printf '%s\n' "${commits_body}"
}

# ── Release orchestrator ──────────────────────────────────────

# ------------------------------------------------------------
# @description  Builds the changelog, creates the GitHub release, and
#               writes the resulting release URL back into the context.
#               Uses prev_sha from the context to define the commit range;
#               falls back to TRC_NO_COMMITS_PLACEHOLDER when no previous
#               release exists.
#
# @param $1     ctx_name - Name of the TRC context associative array.
#                          Reads:  version, repo, sha, environment, prev_sha.
#                          Writes: release_url.
# @exitcode     1 if the gh release create call fails.
# @example
#   declare -A TRC_CTX
#   ctx_build TRC_CTX "v1.2.3" "owner/repo" "abc1234" "dev" "/tmp/out"
#   tag_resolve_previous "TRC_CTX"  # sets prev_sha
#   release_create "TRC_CTX"
#   # Creates GitHub release "v1.2.3" with changelog of commits since prev_sha
#   # TRC_CTX[release_url]="https://github.com/owner/repo/releases/tag/v1.2.3"
#
#   # First release (prev_sha=""):
#   release_create "TRC_CTX"
#   # Release body uses "_No commits found._" placeholder
# ------------------------------------------------------------
release_create() {
	local ctx_name="$1"
	local -n _rc="${ctx_name}"

	local version="${_rc[${TRC_F_VERSION}]}"
	local repo="${_rc[${TRC_F_REPO}]}"
	local sha="${_rc[${TRC_F_SHA}]}"
	local environment="${_rc[${TRC_F_ENVIRONMENT}]}"
	local prev_sha="${_rc[${TRC_F_PREV_SHA}]}"

	local current_date
	current_date="$(date +"%Y-%m-%d-%H-%M-%S")"

	local commits_body="${TRC_NO_COMMITS_PLACEHOLDER}"
	if [[ -n "${prev_sha}" ]]; then
		local commits
		commits="$(release_get_commits_between "${prev_sha}" "${sha}" "${repo}")"
		[[ -n "${commits}" ]] && commits_body="${commits}"
	fi

	local body
	body="$(release_build_body "${version}" "${environment}" "${current_date}" "${commits_body}")"

	log_info "Creating release '${version}' in '${repo}'..."
	gh release create "${version}" --repo "${repo}" --notes "${body}"
	log_ok "Release '${version}' created."

	local release_url
	release_url="$(gh release view "${version}" --repo "${repo}" --json url --jq '.url')"
	_rc[${TRC_F_RELEASE_URL}]="${release_url}"
}

# ── Output ────────────────────────────────────────────────────

# ------------------------------------------------------------
# @description  Writes tag_created, release_created, and release_url
#               to the GitHub Actions output file.
# @param $1     ctx_name - Name of the TRC context associative array.
# @example
#   output_export "TRC_CTX"
#   # Appends to GITHUB_OUTPUT:
#   #   tag_created=true
#   #   release_created=true
#   #   release_url=https://github.com/owner/repo/releases/tag/v1.2.3
# ------------------------------------------------------------
output_export() {
	local ctx_name="$1"
	local -n _oe="${ctx_name}"

	{
		echo "tag_created=true"
		echo "release_created=true"
		echo "release_url=${_oe[${TRC_F_RELEASE_URL}]}"
	} >>"${_oe[${TRC_F_OUTPUT_FILE}]}"
}

# ------------------------------------------------------------
# @description  Prints a human-readable tag and release creation summary
#               to stderr for GitHub Actions log visibility.
# @param $1     ctx_name - Name of the TRC context associative array.
# @example
#   output_summary "TRC_CTX"
#   # Prints to stderr:
#   # ════════════════════════════════════════
#   #   Tag & Release Creation Summary
#   # ════════════════════════════════════════
#   #   repository         = owner/repo
#   #   release_version    = v1.2.3
#   #   previous_tag       = v1.2.2
#   #   release_url        = https://github.com/owner/repo/releases/tag/v1.2.3
#   #   result             = success
#   # ════════════════════════════════════════
# ------------------------------------------------------------
output_summary() {
	local ctx_name="$1"
	local -n _os="${ctx_name}"

	printf '\n%s\n' "════════════════════════════════════════"
	printf '  %s\n' "Tag & Release Creation Summary"
	printf '%s\n' "════════════════════════════════════════"
	printf '  %-18s = %s\n' "repository" "${_os[${TRC_F_REPO}]}"
	printf '  %-18s = %s\n' "release_version" "${_os[${TRC_F_VERSION}]}"
	printf '  %-18s = %s\n' "previous_tag" "${_os[${TRC_F_PREV_TAG}]:-none}"
	printf '  %-18s = %s\n' "release_url" "${_os[${TRC_F_RELEASE_URL}]}"
	printf '  %-18s = %s\n' "result" "success"
	printf '%s\n' "════════════════════════════════════════"
}
