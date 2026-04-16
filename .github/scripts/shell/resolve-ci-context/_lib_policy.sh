#!/usr/bin/env bash
# ============================================================
# Domain: Policy — guards, push version resolution, event handlers,
#         and registry-based dispatch
# ============================================================

# ── Guards ────────────────────────────────────────────────────

# ------------------------------------------------------------
# @description  Exits with error if a remote tag already exists.
#               Hard precondition gate before any release operation.
# @param $1     version - The tag to check (e.g. 'v1.2.3').
# @param $2     repo    - GitHub repository slug (owner/repo).
# @exitcode     1 if the tag already exists in the remote.
# @example
#   # Tag v1.2.3 does not exist yet — continues normally:
#   guard_tag_not_exists "v1.2.3" "owner/repo"
#
#   # Tag v1.2.3 already exists — exits 1 with error message:
#   guard_tag_not_exists "v1.2.3" "owner/repo"
#   # ❌ Tag 'v1.2.3' already exists in 'owner/repo'.
# ------------------------------------------------------------
guard_tag_not_exists() {
	local version="$1"
	local repo="$2"

	if gh api "repos/${repo}/git/ref/tags/${version}" &>/dev/null; then
		log_error "Tag '${version}' already exists in '${repo}'."
		log_error "Version already released. Create a new release/ branch with an incremented version."
		exit 1
	fi
}

# ------------------------------------------------------------
# @description  Exits with error if a branch has already been merged
#               into main, preventing a re-deploy from a stale branch.
# @param $1     branch - The branch name to check.
# @exitcode     1 if the branch is already merged into origin/main.
# @example
#   # Branch has not been merged — continues normally:
#   guard_branch_not_merged "release/v1.2.3"
#
#   # Branch was already merged — exits 1 with error message:
#   guard_branch_not_merged "release/v1.0.0"
#   # ❌ Branch 'release/v1.0.0' has already been merged into main.
# ------------------------------------------------------------
guard_branch_not_merged() {
	local branch="$1"

	if git merge-base --is-ancestor "${branch}" "origin/main" 2>/dev/null; then
		log_error "Branch '${branch}' has already been merged into main."
		log_error "Create a new release/ branch (e.g. release/v0.0.2) for a new deployment."
		exit 1
	fi
}

# ── Push version resolution ───────────────────────────────────

# ------------------------------------------------------------
# @description  Resolves the release version on push-to-main events.
#               Queries the GitHub API for the PR that produced the merge
#               commit, then validates its head branch pattern.
#               Non-fatal: emits a warning when no PR is found (e.g. direct
#               push or insufficient token scope).
#
# @param $1     sha        - Merge commit SHA (GITHUB_SHA).
# @param $2     repo       - Repository slug (owner/repo).
# @param $3     is_flutter - '1' if Flutter project; '0' otherwise.
# @param $4     workspace  - Absolute path to GITHUB_WORKSPACE.
# @param $5     ctx_name   - Name of the CI context array to update.
# @example
#   declare -A CI_CTX
#   ctx_build CI_CTX "push" "" "" "main" "container" "abc1234" "owner/repo"
#   policy_resolve_version_from_push "abc1234" "owner/repo" "0" "/workspace" "CI_CTX"
#   # If the PR that merged had head branch "release/v1.2.3":
#   #   CI_CTX[release_version]="v1.2.3"
#   #   CI_CTX[release_version_number]="1.2.3"
#   # If no PR found (direct push or API unavailable):
#   #   ⚠️  No PR found for commit 'abc1234'. release_version not resolvable.
#   #   CI_CTX[release_version]="" (unchanged)
# ------------------------------------------------------------
policy_resolve_version_from_push() {
	local sha="$1"
	local repo="$2"
	local is_flutter="$3"
	local workspace="$4"
	local ctx_name="$5"

	if [[ -z "${sha}" || -z "${repo}" ]]; then
		log_warn "GITHUB_SHA or GITHUB_REPOSITORY unavailable. release_version not resolvable on push."
		return 0
	fi

	local source_branch
	source_branch="$(gh api "repos/${repo}/commits/${sha}/pulls" \
		--jq '.[0].head.ref // ""' 2>/dev/null || echo "")"

	if [[ -z "${source_branch}" ]]; then
		log_warn "No PR found for commit '${sha}'. release_version not resolvable."
		return 0
	fi

	local -A ver=()
	if branch_validate_release "${source_branch}" "push → main" "${is_flutter}" "${workspace}" ver; then
		local -n _prvp_ctx="${ctx_name}"
		_prvp_ctx[${CTX_F_RELEASE_VERSION}]="${ver[release_version]}"
		_prvp_ctx[${CTX_F_RELEASE_VERSION_NUMBER}]="${ver[release_version_number]}"
		_prvp_ctx[${CTX_F_BUILD_NUMBER}]="${ver[build_number]:-}"
	else
		log_warn "PR source branch '${source_branch}' is not a valid release branch."
	fi
}

# ── Event handlers ─────────────────────────────────────────────

# ------------------------------------------------------------
# @description  Policy for pull_request events. Enforces that the PR
#               targets main and originates from a valid release branch.
#               Blocks early if the tag already exists so conflicts are
#               caught during code review, not after merge.
#               Sets should_run=true and writes version fields on success.
#
# @param $1     ctx_name   - Name of the CI context associative array.
# @param $2     workspace  - Absolute path to GITHUB_WORKSPACE.
# @param $3     is_flutter - '1' if Flutter project; '0' for container.
# @exitcode     1 if the head branch is not a valid release branch, or the
#               tag already exists in the remote.
# @example
#   declare -A CI_CTX
#   ctx_build CI_CTX "pull_request" "release/v1.2.3" "main" \
#     "release/v1.2.3" "container" "abc1234" "owner/repo"
#   _policy_handle_pr "CI_CTX" "/workspace" "0"
#   # CI_CTX[should_run]="true"
#   # CI_CTX[release_version]="v1.2.3"
#   # CI_CTX[release_version_number]="1.2.3"
#
#   # PR targeting 'staging' (not main) — silent skip, should_run stays false:
#   ctx_build CI_CTX "pull_request" "release/v1.2.3" "staging" ...
#   _policy_handle_pr "CI_CTX" "/workspace" "0"
#   # CI_CTX[should_run]="false"
# ------------------------------------------------------------
_policy_handle_pr() {
	local ctx_name="$1"
	local workspace="$2"
	local is_flutter="$3"
	local -n _hpr="${ctx_name}"

	# Only enforce the policy for PRs targeting main; other base branches are ignored.
	if [[ "${_hpr[${CTX_F_BASE}]}" != "main" ]]; then
		log_info "PR targeting '${_hpr[${CTX_F_BASE}]}' (not main). Policy does not apply."
		return 0
	fi

	# Validate the source branch pattern and extract version fields into a local map.
	local -A ver=()
	branch_validate_release "${_hpr[${CTX_F_HEAD}]}" "PR → main" "${is_flutter}" "${workspace}" ver ||
		{
			log_error "PR to main from disallowed branch."
			exit 1
		}

	# Hard gate: if this tag was already released, the PR cannot proceed.
	guard_tag_not_exists "${ver[release_version]}" "${_hpr[${CTX_F_REPO}]}"

	# Promote extracted version fields into the shared context.
	_hpr[${CTX_F_RELEASE_VERSION}]="${ver[release_version]}"
	_hpr[${CTX_F_RELEASE_VERSION_NUMBER}]="${ver[release_version_number]}"
	_hpr[${CTX_F_BUILD_NUMBER}]="${ver[build_number]:-}"
	_hpr[${CTX_F_SHOULD_RUN}]="true"
}

# ------------------------------------------------------------
# @description  Policy for push events. Only reacts to pushes that land
#               on main (i.e. a merged PR). Attempts to resolve the release
#               version by looking up the merged PR's head branch via the
#               GitHub API. Non-fatal: if the API is unavailable or returns
#               no PR, should_run is still set to true so downstream jobs
#               (e.g. tag creation) can proceed with whatever context is known.
#
# @param $1     ctx_name   - Name of the CI context associative array.
# @param $2     workspace  - Absolute path to GITHUB_WORKSPACE.
# @param $3     is_flutter - '1' if Flutter project; '0' for container.
# @example
#   declare -A CI_CTX
#   ctx_build CI_CTX "push" "" "" "main" "container" "abc1234" "owner/repo"
#   _policy_handle_push "CI_CTX" "/workspace" "0"
#   # CI_CTX[should_run]="true"
#   # CI_CTX[release_version]="v1.2.3"  (if resolved from merged PR)
#
#   # Push to a non-main branch (e.g. push to a feature branch) — silent skip:
#   ctx_build CI_CTX "push" "" "" "feature/xyz" ...
#   _policy_handle_push "CI_CTX" "/workspace" "0"
#   # returns 0 immediately, should_run stays "false"
# ------------------------------------------------------------
_policy_handle_push() {
	local ctx_name="$1"
	local workspace="$2"
	local is_flutter="$3"
	local -n _hpush="${ctx_name}"

	# Pushes to non-main branches (e.g. direct pushes to feature branches) are ignored.
	[[ "${_hpush[${CTX_F_REF_NAME}]}" == "main" ]] || return 0

	log_ok "Push to main detected."

	# Best-effort: query the API for the PR that produced this merge commit
	# and extract its head branch to resolve the release version.
	policy_resolve_version_from_push \
		"${_hpush[${CTX_F_SHA}]}" \
		"${_hpush[${CTX_F_REPO}]}" \
		"${is_flutter}" \
		"${workspace}" \
		"${ctx_name}"

	_hpush[${CTX_F_SHOULD_RUN}]="true"
}

# ------------------------------------------------------------
# @description  Policy for workflow_dispatch events. Validates the dispatched
#               branch, then applies two hard gates: the tag must not exist yet
#               and the branch must not have already been merged. Both guards
#               prevent accidental re-deployments from stale branches.
#
# @param $1     ctx_name   - Name of the CI context associative array.
# @param $2     workspace  - Absolute path to GITHUB_WORKSPACE.
# @param $3     is_flutter - '1' if Flutter project; '0' for container.
# @exitcode     1 if the dispatched branch is not a valid release branch,
#               the corresponding tag already exists, or the branch was
#               already merged into main.
# @example
#   declare -A CI_CTX
#   ctx_build CI_CTX "workflow_dispatch" "" "" "release/v1.2.3" \
#     "container" "abc1234" "owner/repo"
#   _policy_handle_dispatch "CI_CTX" "/workspace" "0"
#   # CI_CTX[should_run]="true"
#   # CI_CTX[release_version]="v1.2.3"
#
#   # Dispatched from an already-merged branch — exits 1:
#   # ❌ Branch 'release/v1.0.0' has already been merged into main.
# ------------------------------------------------------------
_policy_handle_dispatch() {
	local ctx_name="$1"
	local workspace="$2"
	local is_flutter="$3"
	local -n _hdisp="${ctx_name}"

	local ref_name="${_hdisp[${CTX_F_REF_NAME}]}"
	local repo="${_hdisp[${CTX_F_REPO}]}"

	# Validate branch pattern and extract version fields.
	local -A ver=()
	branch_validate_release "${ref_name}" "workflow_dispatch" "${is_flutter}" "${workspace}" ver ||
		{
			log_error "workflow_dispatch from disallowed branch."
			exit 1
		}

	# Guard 1: the version has not already been tagged (prevents duplicate releases).
	guard_tag_not_exists "${ver[release_version]}" "${repo}"

	# Guard 2: the branch has not already been merged (prevents re-deploys from stale branches).
	guard_branch_not_merged "${ref_name}"

	# Promote extracted version fields into the shared context.
	_hdisp[${CTX_F_RELEASE_VERSION}]="${ver[release_version]}"
	_hdisp[${CTX_F_RELEASE_VERSION_NUMBER}]="${ver[release_version_number]}"
	_hdisp[${CTX_F_BUILD_NUMBER}]="${ver[build_number]:-}"
	_hdisp[${CTX_F_SHOULD_RUN}]="true"
}

# ── Registry dispatch ─────────────────────────────────────────

# ------------------------------------------------------------
# @description  Evaluates the CI/CD gate policy for the current event
#               using a registry (dispatch table). Maps each known event
#               type to its handler function. Unknown events result in
#               should_run=false with a warning; no error is raised.
#
# @param $1     ctx_name   - Name of the CI context associative array.
# @param $2     workspace  - Absolute path to GITHUB_WORKSPACE.
# @param $3     is_flutter - '1' if Flutter project; '0' for container.
# @example
#   declare -A CI_CTX
#   ctx_build CI_CTX "pull_request" "release/v1.2.3" "main" \
#     "release/v1.2.3" "container" "abc1234" "owner/repo"
#   policy_evaluate "CI_CTX" "/workspace" "0"
#   # Dispatches to _policy_handle_pr
#   # CI_CTX[should_run]="true" on success
#
#   # Unknown event — warning, no error, pipeline skipped:
#   ctx_build CI_CTX "schedule" ...
#   policy_evaluate "CI_CTX" "/workspace" "0"
#   # ⚠️  Event 'schedule' has no defined policy. Pipeline will not run.
#   # CI_CTX[should_run]="false"
# ------------------------------------------------------------
policy_evaluate() {
	local ctx_name="$1"
	local workspace="$2"
	local is_flutter="$3"
	local -n _pe_ctx="${ctx_name}"

	local event="${_pe_ctx[${CTX_F_EVENT}]}"

	declare -A _HANDLER_REGISTRY=(
		["${CTX_EVENT_PR}"]="_policy_handle_pr"
		["${CTX_EVENT_PUSH}"]="_policy_handle_push"
		["${CTX_EVENT_DISPATCH}"]="_policy_handle_dispatch"
	)

	local handler="${_HANDLER_REGISTRY[${event}]:-}"

	if [[ -z "${handler}" ]]; then
		log_warn "Event '${event}' has no defined policy. Pipeline will not run."
		return 0
	fi

	"${handler}" "${ctx_name}" "${workspace}" "${is_flutter}"
}
