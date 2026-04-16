#!/usr/bin/env bash
# ============================================================
# Domain: Tag — context object, tag CRUD operations, and
#         tag-resolution orchestration
# ============================================================

# ── Context field keys ───────────────────────────────────────
readonly TRC_F_VERSION="version"
readonly TRC_F_REPO="repo"
readonly TRC_F_SHA="sha"
readonly TRC_F_ENVIRONMENT="environment"
readonly TRC_F_OUTPUT_FILE="output_file"
readonly TRC_F_PREV_TAG="prev_tag"
readonly TRC_F_PREV_SHA="prev_sha"
readonly TRC_F_RELEASE_URL="release_url"

# ── Sentinel ─────────────────────────────────────────────────
# Empty string: no previous tag exists (first release in the repo).
readonly TRC_INITIAL_TAG_SENTINEL=""

# ------------------------------------------------------------
# @description  Builds the tag-release creator context associative array
#               from explicit parameters. Called only from main().
#               Version fields that are resolved later (prev_tag, prev_sha,
#               release_url) are initialized to empty strings.
#
# @param $1     ctx_name    - Name of the caller's declared associative array.
# @param $2     version     - Release version string (e.g. 'v1.2.3').
# @param $3     repo        - GitHub repository slug (owner/repo).
# @param $4     sha         - Commit SHA to tag.
# @param $5     environment - Target environment label (e.g. 'dev', 'prod').
# @param $6     output_file - Absolute path to GITHUB_OUTPUT file.
# @example
#   declare -A TRC_CTX
#   ctx_build TRC_CTX "v1.2.3" "owner/repo" "abc1234def" "dev" "/tmp/github_output"
#   # TRC_CTX[version]="v1.2.3"
#   # TRC_CTX[repo]="owner/repo"
#   # TRC_CTX[sha]="abc1234def"
#   # TRC_CTX[environment]="dev"
#   # TRC_CTX[prev_tag]=""       (TRC_INITIAL_TAG_SENTINEL; populated by tag_resolve_previous)
#   # TRC_CTX[prev_sha]=""       (populated by tag_resolve_previous)
#   # TRC_CTX[release_url]=""    (populated by release_create)
# ------------------------------------------------------------
ctx_build() {
	local -n _cb="$1"
	local version="$2"
	local repo="$3"
	local sha="$4"
	local environment="$5"
	local output_file="$6"

	_cb[${TRC_F_VERSION}]="${version}"
	_cb[${TRC_F_REPO}]="${repo}"
	_cb[${TRC_F_SHA}]="${sha}"
	_cb[${TRC_F_ENVIRONMENT}]="${environment}"
	_cb[${TRC_F_OUTPUT_FILE}]="${output_file}"
	_cb[${TRC_F_PREV_TAG}]="${TRC_INITIAL_TAG_SENTINEL}"
	_cb[${TRC_F_PREV_SHA}]=""
	_cb[${TRC_F_RELEASE_URL}]=""
}

# ── Tag queries (pure: params only, no side effects) ─────────

# ------------------------------------------------------------
# @description  Checks whether a tag already exists in the remote.
# @param $1     version - The tag name to look up (e.g. 'v1.2.3').
# @param $2     repo    - GitHub repository slug (owner/repo).
# @return       0 if the tag exists, 1 otherwise.
# @example
#   tag_exists "v1.2.3" "owner/repo" && echo "tag exists"
#   # prints "tag exists" if the tag is present in the remote
#
#   tag_exists "v9.9.9" "owner/repo" || echo "tag does not exist"
#   # prints "tag does not exist" if absent
# ------------------------------------------------------------
tag_exists() {
	local version="$1"
	local repo="$2"
	gh api "repos/${repo}/git/ref/tags/${version}" &>/dev/null
}

# ------------------------------------------------------------
# @description  Resolves the commit SHA for a given tag, handling both
#               lightweight tags (.object.type = commit) and annotated tags
#               (.object.type = tag) which require a second API dereference.
# @param $1     tag  - The tag name to resolve.
# @param $2     repo - GitHub repository slug (owner/repo).
# @stdout       The commit SHA the tag points to.
# @example
#   tag_get_sha "v1.2.3" "owner/repo"
#   # Output: "abc1234def5678..."  (full commit SHA)
#
#   # Lightweight tag: one API call — refs → commit SHA directly.
#   # Annotated tag:   two API calls — refs → tag object → commit SHA.
# ------------------------------------------------------------
tag_get_sha() {
	local tag="$1"
	local repo="$2"

	# The refs API returns the object the ref points to directly.
	# For a lightweight tag: .object.type = "commit" and .object.sha is the commit SHA.
	# For an annotated tag:  .object.type = "tag"    and .object.sha is the tag object SHA,
	#                        which must be dereferenced via /git/tags/{sha} to reach the commit.
	local ref obj_type obj_sha
	ref="$(gh api "repos/${repo}/git/ref/tags/${tag}")"
	obj_type="$(echo "${ref}" | jq -r '.object.type')"
	obj_sha="$(echo "${ref}" | jq -r '.object.sha')"

	if [[ "${obj_type}" == "tag" ]]; then
		# Annotated tag: follow the tag object to its target commit SHA.
		gh api "repos/${repo}/git/tags/${obj_sha}" --jq '.object.sha'
	else
		# Lightweight tag: the ref points directly to the commit.
		echo "${obj_sha}"
	fi
}

# ── Tag mutations ─────────────────────────────────────────────

# ------------------------------------------------------------
# @description  Creates a lightweight tag at the given commit SHA.
# @param $1     version - The tag name to create.
# @param $2     repo    - GitHub repository slug (owner/repo).
# @param $3     sha     - Commit SHA to tag.
# @exitcode     1 if the GitHub API call fails.
# @example
#   tag_create "v1.2.3" "owner/repo" "abc1234def"
#   # Creates refs/tags/v1.2.3 pointing at commit abc1234def
#   # ✅ Tag 'v1.2.3' created.
# ------------------------------------------------------------
tag_create() {
	local version="$1"
	local repo="$2"
	local sha="$3"

	log_info "Creating tag '${version}' at commit '${sha}' in '${repo}'..."
	gh api "repos/${repo}/git/refs" \
		--method POST \
		-f "ref=refs/tags/${version}" \
		-f "sha=${sha}" \
		--silent
	log_ok "Tag '${version}' created."
}

# ------------------------------------------------------------
# @description  Returns the name of the tag that preceded the given version.
#               Must be called AFTER the new tag is created: the API returns
#               tags in reverse chronological order, so index 0 is the tag just
#               created and index 1 is the previous release.
#               Returns an empty string (TRC_INITIAL_TAG_SENTINEL) when no
#               previous tag exists.
# @param $1     version - The newly created tag (used for context only).
# @param $2     repo    - GitHub repository slug (owner/repo).
# @stdout       Previous tag name, or empty string if this is the first release.
# @example
#   # Called AFTER tag_create "v1.2.3" succeeded:
#   tag_get_previous "v1.2.3" "owner/repo"
#   # Output: "v1.2.2"   (the previous release tag at API index [1])
#
#   # First release in the repo (no prior tags):
#   tag_get_previous "v1.0.0" "owner/repo"
#   # Output: ""          (TRC_INITIAL_TAG_SENTINEL — changelog uses placeholder)
# ------------------------------------------------------------
tag_get_previous() {
	local version="$1"
	local repo="$2"
	gh api "repos/${repo}/tags" --jq '.[1].name // ""'
}

# ── Orchestrator ──────────────────────────────────────────────

# ------------------------------------------------------------
# @description  Guards against duplicate releases, creates the new tag,
#               and resolves the previous tag's commit SHA. Writes
#               prev_tag and prev_sha into the context for use by the
#               release step.
#
#               Ordering contract: tag_get_previous is called after
#               tag_create so the API sees the new tag at index 0 and
#               the previous release at index 1.
#
# @param $1     ctx_name - Name of the TRC context associative array.
# @exitcode     1 if the tag already exists.
# @example
#   declare -A TRC_CTX
#   ctx_build TRC_CTX "v1.2.3" "owner/repo" "abc1234" "dev" "/tmp/out"
#   tag_resolve_previous "TRC_CTX"
#   # Step 1: tag_exists check — exits 1 if v1.2.3 already present
#   # Step 2: tag_create "v1.2.3" "owner/repo" "abc1234"
#   # Step 3: tag_get_previous → TRC_CTX[prev_tag]="v1.2.2"
#   # Step 4: tag_get_sha "v1.2.2" → TRC_CTX[prev_sha]="def5678..."
#
#   # First release (no prior tags):
#   # TRC_CTX[prev_tag]=""    TRC_CTX[prev_sha]=""
# ------------------------------------------------------------
tag_resolve_previous() {
	local ctx_name="$1"
	local -n _trp="${ctx_name}"

	local version="${_trp[${TRC_F_VERSION}]}"
	local repo="${_trp[${TRC_F_REPO}]}"
	local sha="${_trp[${TRC_F_SHA}]}"

	if tag_exists "${version}" "${repo}"; then
		log_error "Tag '${version}' already exists in '${repo}'. Aborting."
		exit 1
	fi

	tag_create "${version}" "${repo}" "${sha}"

	local prev_tag prev_sha=""
	prev_tag="$(tag_get_previous "${version}" "${repo}")"

	if [[ -n "${prev_tag}" ]]; then
		prev_sha="$(tag_get_sha "${prev_tag}" "${repo}")"
	fi

	_trp[${TRC_F_PREV_TAG}]="${prev_tag}"
	_trp[${TRC_F_PREV_SHA}]="${prev_sha}"
}
