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

_policy_handle_pr() {
  local ctx_name="$1"
  local workspace="$2"
  local is_flutter="$3"
  local -n _hpr="${ctx_name}"

  if [[ "${_hpr[${CTX_F_BASE}]}" != "main" ]]; then
    log_info "PR targeting '${_hpr[${CTX_F_BASE}]}' (not main). Policy does not apply."
    return 0
  fi

  local -A ver=()
  branch_validate_release "${_hpr[${CTX_F_HEAD}]}" "PR → main" "${is_flutter}" "${workspace}" ver \
    || { log_error "PR to main from disallowed branch."; exit 1; }

  guard_tag_not_exists "${ver[release_version]}" "${_hpr[${CTX_F_REPO}]}"

  _hpr[${CTX_F_RELEASE_VERSION}]="${ver[release_version]}"
  _hpr[${CTX_F_RELEASE_VERSION_NUMBER}]="${ver[release_version_number]}"
  _hpr[${CTX_F_BUILD_NUMBER}]="${ver[build_number]:-}"
  _hpr[${CTX_F_SHOULD_RUN}]="true"
}

_policy_handle_push() {
  local ctx_name="$1"
  local workspace="$2"
  local is_flutter="$3"
  local -n _hpush="${ctx_name}"

  [[ "${_hpush[${CTX_F_REF_NAME}]}" == "main" ]] || return 0

  log_ok "Push to main detected."
  policy_resolve_version_from_push \
    "${_hpush[${CTX_F_SHA}]}" \
    "${_hpush[${CTX_F_REPO}]}" \
    "${is_flutter}" \
    "${workspace}" \
    "${ctx_name}"

  _hpush[${CTX_F_SHOULD_RUN}]="true"
}

_policy_handle_dispatch() {
  local ctx_name="$1"
  local workspace="$2"
  local is_flutter="$3"
  local -n _hdisp="${ctx_name}"

  local ref_name="${_hdisp[${CTX_F_REF_NAME}]}"
  local repo="${_hdisp[${CTX_F_REPO}]}"

  local -A ver=()
  branch_validate_release "${ref_name}" "workflow_dispatch" "${is_flutter}" "${workspace}" ver \
    || { log_error "workflow_dispatch from disallowed branch."; exit 1; }

  guard_tag_not_exists   "${ver[release_version]}" "${repo}"
  guard_branch_not_merged "${ref_name}"

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
