#!/usr/bin/env bash
# ============================================================
# Domain: Validator — context object, semver format gate,
#         tag/release existence checks, registry runner, and output
# ============================================================

# ── Semver pattern ────────────────────────────────────────────
# Accepts optional 'v' prefix, pre-release label, and build metadata.
readonly TRV_SEMVER_REGEX='^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'

# ── Context field keys ───────────────────────────────────────
readonly TRV_F_VERSION="version"
readonly TRV_F_REPO="repo"
readonly TRV_F_OUTPUT_FILE="output_file"
readonly TRV_F_TAG_EXISTS="tag_exists"
readonly TRV_F_RELEASE_EXISTS="release_exists"
readonly TRV_F_RESULT="result"

# ------------------------------------------------------------
# @description  Builds the tag-release validator context associative array
#               from explicit parameters. Called only from main().
#               Existence flags default to 'false'; result defaults to 'failed'
#               so any unhandled exit path produces a safe default.
#
# @param $1     ctx_name    - Name of the caller's declared associative array.
# @param $2     version     - Release version string (e.g. 'v1.2.3').
# @param $3     repo        - GitHub repository slug (owner/repo).
# @param $4     output_file - Absolute path to GITHUB_OUTPUT file.
# ------------------------------------------------------------
ctx_build() {
  local -n _cb="$1"
  local version="$2"
  local repo="$3"
  local output_file="$4"

  _cb[${TRV_F_VERSION}]="${version}"
  _cb[${TRV_F_REPO}]="${repo}"
  _cb[${TRV_F_OUTPUT_FILE}]="${output_file}"
  _cb[${TRV_F_TAG_EXISTS}]="false"
  _cb[${TRV_F_RELEASE_EXISTS}]="false"
  _cb[${TRV_F_RESULT}]="failed"
}

# ── Validators (pure: params only, no env access) ─────────────

# ------------------------------------------------------------
# @description  Hard-gate validator: checks that the version string
#               conforms to semver (vMAJOR.MINOR.PATCH[-pre][+build]).
#               Used as a precondition before any remote checks.
# @param $1     version - The version string to validate.
# @return       0 if valid semver, 1 otherwise.
# ------------------------------------------------------------
validate_semver_format() {
  local version="$1"

  if [[ ! "${version}" =~ ${TRV_SEMVER_REGEX} ]]; then
    log_error "Version '${version}' does not conform to semver (vMAJOR.MINOR.PATCH[-pre][+build])."
    return 1
  fi

  log_ok "Version '${version}' is valid semver."
}

# ------------------------------------------------------------
# @description  Soft validator: checks that no tag with this name already
#               exists in the remote repository. Safe to create when absent.
# @param $1     version - The tag name to look up.
# @param $2     repo    - GitHub repository slug (owner/repo).
# @return       0 if the tag is absent (safe), 1 if it already exists.
# ------------------------------------------------------------
validate_tag_absent() {
  local version="$1"
  local repo="$2"

  log_info "Checking tag '${version}' in '${repo}'..."

  if gh api "repos/${repo}/git/ref/tags/${version}" &>/dev/null; then
    log_error "Tag '${version}' already exists in '${repo}'."
    return 1
  fi

  log_ok "Tag '${version}' does not exist. Safe to create."
}

# ------------------------------------------------------------
# @description  Soft validator: checks that no GitHub release with this
#               version name already exists in the remote repository.
# @param $1     version - The release tag name to look up.
# @param $2     repo    - GitHub repository slug (owner/repo).
# @return       0 if the release is absent (safe), 1 if it already exists.
# ------------------------------------------------------------
validate_release_absent() {
  local version="$1"
  local repo="$2"

  log_info "Checking release '${version}' in '${repo}'..."

  if gh release view "${version}" --repo "${repo}" &>/dev/null; then
    log_error "Release '${version}' already exists in '${repo}'."
    return 1
  fi

  log_ok "Release '${version}' does not exist. Safe to create."
}

# ── Registry runner ───────────────────────────────────────────

# ------------------------------------------------------------
# @description  Runs all validators against the context and writes results
#               back into the context.
#
#               Two-phase execution:
#               1. Hard gate — validate_semver_format runs first and exits
#                  immediately on failure; no remote calls are made.
#               2. Soft validators — run independently via a registry that
#                  maps context_field → validator_fn. Both checks always
#                  run so downstream always receives the full state.
#                  A failed validator sets its mapped field to 'true' in
#                  the context.
#
#               Sets TRV_F_RESULT to 'passed' only when all soft validators
#               succeed.
#
# @param $1     ctx_name - Name of the TRV context associative array.
# @exitcode     1 if the semver format check fails.
# ------------------------------------------------------------
validators_run() {
  local ctx_name="$1"
  local -n _vr="${ctx_name}"

  local version="${_vr[${TRV_F_VERSION}]}"
  local repo="${_vr[${TRV_F_REPO}]}"

  # Phase 1: hard precondition — exits immediately on failure
  validate_semver_format "${version}" || exit 1

  # Phase 2: soft validators — registry maps context_field → validator_fn
  # Both run regardless of each other so the caller always gets full state.
  declare -A _SOFT_VALIDATOR_REGISTRY=(
    ["${TRV_F_TAG_EXISTS}"]="validate_tag_absent"
    ["${TRV_F_RELEASE_EXISTS}"]="validate_release_absent"
  )

  local all_passed=true
  local field fn
  for field in "${!_SOFT_VALIDATOR_REGISTRY[@]}"; do
    fn="${_SOFT_VALIDATOR_REGISTRY[${field}]}"
    if ! "${fn}" "${version}" "${repo}"; then
      _vr["${field}"]="true"
      all_passed=false
    fi
  done

  [[ "${all_passed}" == "true" ]] && _vr[${TRV_F_RESULT}]="passed"
}

# ── Output ────────────────────────────────────────────────────

# ------------------------------------------------------------
# @description  Writes validation_result, tag_exists, and release_exists
#               to the GitHub Actions output file.
# @param $1     ctx_name - Name of the TRV context associative array.
# ------------------------------------------------------------
output_export() {
  local ctx_name="$1"
  local -n _oe="${ctx_name}"

  {
    echo "validation_result=${_oe[${TRV_F_RESULT}]}"
    echo "tag_exists=${_oe[${TRV_F_TAG_EXISTS}]}"
    echo "release_exists=${_oe[${TRV_F_RELEASE_EXISTS}]}"
  } >> "${_oe[${TRV_F_OUTPUT_FILE}]}"
}

# ------------------------------------------------------------
# @description  Prints a human-readable tag and release validation summary
#               to stderr for GitHub Actions log visibility.
# @param $1     ctx_name - Name of the TRV context associative array.
# ------------------------------------------------------------
output_summary() {
  local ctx_name="$1"
  local -n _os="${ctx_name}"

  printf '\n%s\n'   "════════════════════════════════════════"
  printf '  %s\n'   "Tag & Release Validation Summary"
  printf '%s\n'     "════════════════════════════════════════"
  printf '  %-18s = %s\n' "repository"      "${_os[${TRV_F_REPO}]}"
  printf '  %-18s = %s\n' "release_version" "${_os[${TRV_F_VERSION}]}"
  printf '  %-18s = %s\n' "tag_exists"      "${_os[${TRV_F_TAG_EXISTS}]}"
  printf '  %-18s = %s\n' "release_exists"  "${_os[${TRV_F_RELEASE_EXISTS}]}"
  printf '  %-18s = %s\n' "result"          "${_os[${TRV_F_RESULT}]}"
  printf '%s\n'     "════════════════════════════════════════"
}
