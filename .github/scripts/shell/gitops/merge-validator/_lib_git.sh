#!/usr/bin/env bash
# ============================================================
# Domain: Git Operations — fetch, divergence check, conflict detection,
#         and branch freshness orchestration
# ============================================================

# ------------------------------------------------------------
# @description  Fetches the origin branch and a target branch at the
#               specified depth. Exits on fetch failure.
# @param $1     depth  - Number of commits to fetch (--depth value).
# @param $2     origin - The protected base branch name (e.g. 'main').
# @param $3     branch - The release/feature branch to fetch.
# @exitcode     1 if either fetch fails.
# ------------------------------------------------------------
git_fetch_branches() {
  local depth="$1"
  local origin="$2"
  local branch="$3"

  log_info "Fetching '${origin}' and '${branch}' (depth=${depth})..."

  git fetch --depth="${depth}" origin "${origin}" 2>/dev/null \
    || { log_error "Could not fetch '${origin}'."; exit 1; }

  [[ "${branch}" == "${origin}" ]] && return 0

  git fetch --depth="${depth}" origin "${branch}" 2>/dev/null \
    || { log_error "Could not fetch '${branch}'."; exit 1; }
}

# ------------------------------------------------------------
# @description  Computes how many commits the branch is behind the origin
#               branch. Exits when the count exceeds max_behind.
#
# @param $1     branch     - The branch being validated.
# @param $2     origin     - The protected base branch (e.g. 'main').
# @param $3     max_behind - Maximum allowed commits behind (0 = must be current).
# @param $4     context    - Label for log messages (e.g. 'PR → main').
# @exitcode     1 if behind count exceeds max_behind.
# ------------------------------------------------------------
git_check_divergence() {
  local branch="$1"
  local origin="$2"
  local max_behind="$3"
  local context="$4"

  local behind ahead
  behind="$(git rev-list --count "origin/${branch}..origin/${origin}")"
  ahead="$(git rev-list  --count "origin/${origin}..origin/${branch}")"

  log_info "[${context}] '${branch}' vs '${origin}': ahead=${ahead}, behind=${behind}"

  if [[ "${behind}" -gt "${max_behind}" ]]; then
    log_error "[${context}] '${branch}' is ${behind} commit(s) behind '${origin}' (max allowed: ${max_behind})."
    log_error "Branch is not up to date. Run: git rebase origin/${origin}"
    exit 1
  fi

  log_ok "[${context}] Branch is up to date with '${origin}'."
}

# ------------------------------------------------------------
# @description  Performs a dry-run merge using git merge-tree to detect
#               conflicts without modifying the working tree.
#               Exits when conflicts are found.
#
# @param $1     branch  - The branch being validated.
# @param $2     origin  - The protected base branch.
# @param $3     context - Label for log messages.
# @exitcode     1 if merge conflicts are detected.
# ------------------------------------------------------------
git_check_merge_conflicts() {
  local branch="$1"
  local origin="$2"
  local context="$3"

  log_info "[${context}] Checking conflicts between '${branch}' and '${origin}'..."

  local merge_base
  merge_base="$(git merge-base "origin/${origin}" "origin/${branch}")"

  if ! git merge-tree "${merge_base}" "origin/${origin}" "origin/${branch}" | grep -q '<<<<<<<'; then
    log_ok "[${context}] No conflicts detected."
    return 0
  fi

  log_error "[${context}] Conflicts detected between '${branch}' and '${origin}'."
  log_error "Resolve conflicts locally before continuing."
  exit 1
}

# ------------------------------------------------------------
# @description  Orchestrates the full freshness validation for a branch:
#               fetch → divergence check → conflict detection.
#               All git state is fetched fresh; no assumptions about
#               the local working copy.
#
# @param $1     branch     - The branch to validate.
# @param $2     depth      - Fetch depth.
# @param $3     origin     - The protected base branch.
# @param $4     max_behind - Maximum allowed commits behind origin.
# @param $5     context    - Label for log messages.
# @exitcode     1 on fetch failure, stale branch, or merge conflicts.
# ------------------------------------------------------------
git_validate_branch_freshness() {
  local branch="$1"
  local depth="$2"
  local origin="$3"
  local max_behind="$4"
  local context="$5"

  git_fetch_branches        "${depth}" "${origin}" "${branch}"
  git_check_divergence      "${branch}" "${origin}" "${max_behind}" "${context}"
  git_check_merge_conflicts "${branch}" "${origin}" "${context}"
}
