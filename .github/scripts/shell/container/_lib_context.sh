#!/usr/bin/env bash
# ============================================================
# Domain: Context — constants, context object, image name resolution,
#         and GitHub Actions output writers
# ============================================================

# ── Fixed infrastructure constants ───────────────────────────
readonly BP_REGISTRY="ghcr.io"
readonly BP_PLATFORM="linux/amd64"
readonly BP_REF_PREFIX="refs/heads/"

# ── Input defaults (prefer environment > constant > default) ──
readonly BP_DEFAULT_SECURITY_ALLOW_PUSH="false"
readonly BP_DEFAULT_IS_SINGLE_BRANCH="false"
readonly BP_DEFAULT_TRIVY_SEVERITY="CRITICAL,HIGH"
readonly BP_DEFAULT_TRIVY_EXIT_CODE="1"
readonly BP_DEFAULT_TRIVY_IGNORE_UNFIXED="true"

# ── Context field keys ───────────────────────────────────────
readonly BP_F_REGISTRY="registry"
readonly BP_F_PLATFORM="platform"
readonly BP_F_SECURITY_ALLOW_PUSH="security_allow_push"
readonly BP_F_IS_SINGLE_BRANCH="is_single_branch"
readonly BP_F_TRIVY_SEVERITY="trivy_severity"
readonly BP_F_TRIVY_EXIT_CODE="trivy_exit_code"
readonly BP_F_TRIVY_IGNORE_UNFIXED="trivy_ignore_unfixed"
readonly BP_F_REF_NAME="ref_name"
readonly BP_F_REPOSITORY="repository"
readonly BP_F_SHA="sha"
readonly BP_F_WORKSPACE="workspace"
readonly BP_F_ACTOR="actor"
readonly BP_F_RUN_ID="run_id"
readonly BP_F_OUTPUT_FILE="output_file"
readonly BP_F_IMAGE_NAME="image_name"
readonly BP_F_IMAGE_DIGEST="image_digest"

# ------------------------------------------------------------
# @description  Builds the build-and-push context associative array from
#               explicit parameters. Called only from main().
#               BP_F_IMAGE_NAME accepts the pre-resolved image name passed
#               by the action YAML to scan/push steps; it is empty during
#               the build step and populated by cmd_build at runtime.
#
# @param $1     ctx_name             - Name of the caller's associative array.
# @param $2     security_allow_push  - INPUT_SECURITY_ALLOW_PUSH_TO_GHCR.
# @param $3     is_single_branch     - INPUT_IS_SINGLE_BRANCH_DEPLOYMENT.
# @param $4     trivy_severity       - INPUT_TRIVY_SEVERITY.
# @param $5     trivy_exit_code      - INPUT_TRIVY_EXIT_CODE.
# @param $6     trivy_ignore_unfixed - INPUT_TRIVY_IGNORE_UNFIXED.
# @param $7     ref_name             - GITHUB_REF_NAME (refs/heads/ prefix stripped).
# @param $8     repository           - GITHUB_REPOSITORY (owner/repo).
# @param $9     sha                  - GITHUB_SHA.
# @param $10    workspace            - GITHUB_WORKSPACE.
# @param $11    actor                - GITHUB_ACTOR.
# @param $12    run_id               - GITHUB_RUN_ID.
# @param $13    output_file          - GITHUB_OUTPUT path.
# @param $14    image_name_input     - INPUT_IMAGE_NAME (empty during build step).
# @example
#   declare -A BP_CTX
#   ctx_build BP_CTX "false" "false" "CRITICAL,HIGH" "1" "true" \
#     "refs/heads/release/v1.2.3" "owner/my-repo" "abc1234def" \
#     "/workspace" "github-actor" "12345678" "/tmp/github_output" ""
#   # BP_CTX[registry]="ghcr.io"
#   # BP_CTX[platform]="linux/amd64"
#   # BP_CTX[ref_name]="release/v1.2.3"   (refs/heads/ prefix stripped)
#   # BP_CTX[trivy_severity]="CRITICAL,HIGH"
#   # BP_CTX[image_name]=""               (empty; populated by cmd_build)
#   # BP_CTX[image_digest]=""             (empty; populated by cmd_push)
#
#   # Scan/push steps pass the image name resolved by the build step:
#   ctx_build BP_CTX "" "" "" "" "" "release/v1.2.3" "owner/my-repo" "abc1234def" \
#     "/workspace" "github-actor" "12345678" "/tmp/github_output" \
#     "ghcr.io/owner/my-repo:abc1234"
#   # BP_CTX[image_name]="ghcr.io/owner/my-repo:abc1234"
# ------------------------------------------------------------
ctx_build() {
	local -n _cb="$1"

	_cb[${BP_F_REGISTRY}]="${BP_REGISTRY}"
	_cb[${BP_F_PLATFORM}]="${BP_PLATFORM}"
	_cb[${BP_F_SECURITY_ALLOW_PUSH}]="${2:-${BP_DEFAULT_SECURITY_ALLOW_PUSH}}"
	_cb[${BP_F_IS_SINGLE_BRANCH}]="${3:-${BP_DEFAULT_IS_SINGLE_BRANCH}}"
	_cb[${BP_F_TRIVY_SEVERITY}]="${4:-${BP_DEFAULT_TRIVY_SEVERITY}}"
	_cb[${BP_F_TRIVY_EXIT_CODE}]="${5:-${BP_DEFAULT_TRIVY_EXIT_CODE}}"
	_cb[${BP_F_TRIVY_IGNORE_UNFIXED}]="${6:-${BP_DEFAULT_TRIVY_IGNORE_UNFIXED}}"
	_cb[${BP_F_REF_NAME}]="${7#${BP_REF_PREFIX}}"
	_cb[${BP_F_REPOSITORY}]="${8}"
	_cb[${BP_F_SHA}]="${9}"
	_cb[${BP_F_WORKSPACE}]="${10}"
	_cb[${BP_F_ACTOR}]="${11}"
	_cb[${BP_F_RUN_ID}]="${12}"
	_cb[${BP_F_OUTPUT_FILE}]="${13}"
	_cb[${BP_F_IMAGE_NAME}]="${14:-}"
	_cb[${BP_F_IMAGE_DIGEST}]=""
}

# ── Image name resolution (pure: params only) ────────────────

# ------------------------------------------------------------
# @description  Derives the repository name used for GHCR image tagging.
#               Lowercases the repository slug, appends the branch suffix
#               when single-branch deployment is active, and replaces
#               underscores with hyphens (GHCR naming constraint).
# @param $1     repository        - Raw GITHUB_REPOSITORY (owner/repo).
# @param $2     is_single_branch  - 'true' to append branch suffix.
# @param $3     ref_name          - Branch name (appended when single-branch).
# @stdout       Normalised repository name ready for image tagging.
# @example
#   ctx_resolve_repository_name "Owner/My_Repo" "false" "main"
#   # Output: "owner/my-repo"  (lowercased, underscores → hyphens)
#
#   ctx_resolve_repository_name "Owner/My_Repo" "true" "release/v1.2.3"
#   # Output: "owner/my-repo-release/v1.2.3"  (branch suffix appended)
# ------------------------------------------------------------
ctx_resolve_repository_name() {
	local repository="${1,,}"
	local is_single_branch="$2"
	local ref_name="$3"

	local name="${repository}"
	[[ "${is_single_branch}" == "true" ]] && name="${name}-${ref_name}"
	echo "${name//_/-}"
}

# ------------------------------------------------------------
# @description  Composes the full GHCR image name with short SHA tag.
# @param $1     registry        - Container registry host (e.g. 'ghcr.io').
# @param $2     repository_name - Normalised repository name from ctx_resolve_repository_name.
# @param $3     short_sha       - First 7 characters of GITHUB_SHA.
# @stdout       Full image reference (e.g. 'ghcr.io/owner/repo:abc1234').
# @example
#   ctx_resolve_image_name "ghcr.io" "owner/my-repo" "abc1234"
#   # Output: "ghcr.io/owner/my-repo:abc1234"
# ------------------------------------------------------------
ctx_resolve_image_name() {
	local registry="$1"
	local repository_name="$2"
	local short_sha="$3"
	echo "${registry}/${repository_name}:${short_sha}"
}

# ── Output writers ────────────────────────────────────────────

# ------------------------------------------------------------
# @description  Writes the resolved image name and commit SHA to the
#               GitHub Actions output file after a successful build.
# @param $1     ctx_name - Name of the BP context associative array.
# @example
#   # After cmd_build sets BP_CTX[image_name]="ghcr.io/owner/my-repo:abc1234":
#   output_write_build "BP_CTX"
#   # Appends to GITHUB_OUTPUT:
#   #   container_image_name_ghcr=ghcr.io/owner/my-repo:abc1234
#   #   client_repo_sha=abc1234def5678...
# ------------------------------------------------------------
output_write_build() {
	local ctx_name="$1"
	local -n _owb="${ctx_name}"
	{
		echo "container_image_name_ghcr=${_owb[${BP_F_IMAGE_NAME}]}"
		echo "client_repo_sha=${_owb[${BP_F_SHA}]}"
	} >>"${_owb[${BP_F_OUTPUT_FILE}]}"
}

# ------------------------------------------------------------
# @description  Writes the image digest to the GitHub Actions output file
#               after a successful push.
# @param $1     ctx_name - Name of the BP context associative array.
# @example
#   # After cmd_push sets BP_CTX[image_digest]="ghcr.io/owner/my-repo@sha256:a1b2...":
#   output_write_push "BP_CTX"
#   # Appends to GITHUB_OUTPUT:
#   #   container_image_digest_ghcr=ghcr.io/owner/my-repo@sha256:a1b2...
# ------------------------------------------------------------
output_write_push() {
	local ctx_name="$1"
	local -n _owp="${ctx_name}"
	echo "container_image_digest_ghcr=${_owp[${BP_F_IMAGE_DIGEST}]}" \
		>>"${_owp[${BP_F_OUTPUT_FILE}]}"
}
