#!/usr/bin/env bash
# ============================================================
# Domain: CI Context — constants, context object lifecycle, and predicates
# ============================================================

# ── Event type constants ─────────────────────────────────────
readonly CTX_EVENT_PR="pull_request"
readonly CTX_EVENT_PUSH="push"
readonly CTX_EVENT_DISPATCH="workflow_dispatch"

# ── Target action constants ──────────────────────────────────
readonly CTX_TARGET_CONTAINER="container"
readonly CTX_TARGET_FLUTTER="flutter"

# ── Context field keys ───────────────────────────────────────
readonly CTX_F_EVENT="event"
readonly CTX_F_HEAD="head"
readonly CTX_F_BASE="base"
readonly CTX_F_REF_NAME="ref_name"
readonly CTX_F_TARGET="target"
readonly CTX_F_SHA="sha"
readonly CTX_F_REPO="repo"
readonly CTX_F_RELEASE_VERSION="release_version"
readonly CTX_F_RELEASE_VERSION_NUMBER="release_version_number"
readonly CTX_F_BUILD_NUMBER="build_number"
readonly CTX_F_SHOULD_RUN="should_run"

# ── Internal ─────────────────────────────────────────────────
readonly _CTX_REF_PREFIX="refs/heads/"

# ------------------------------------------------------------
# @description  Strips the 'refs/heads/' prefix from a Git ref string.
# @param $1     ref - Full ref string (e.g. 'refs/heads/main').
# @stdout       Normalized branch name without prefix.
# ------------------------------------------------------------
_ctx_strip_ref_prefix() {
  local ref="${1:-}"
  echo "${ref#${_CTX_REF_PREFIX}}"
}

# ------------------------------------------------------------
# @description  Constructs the CI context associative array from raw
#               GitHub Actions environment values. Called only from main().
#               Normalizes head/base/ref_name by stripping refs/heads/ prefix.
#               On push events GITHUB_HEAD_REF is empty; falls back to ref_name.
#
# @param $1     ctx_name  - Name of the caller's declared associative array.
# @param $2     event     - Raw GITHUB_EVENT_NAME value.
# @param $3     head_ref  - Raw GITHUB_HEAD_REF value (may be empty on push).
# @param $4     base_ref  - Raw GITHUB_BASE_REF value.
# @param $5     ref_name  - Raw GITHUB_REF_NAME value.
# @param $6     target    - INPUT_TARGET_ACTION (optional; defaults to 'container').
# @param $7     sha       - GITHUB_SHA value.
# @param $8     repo      - GITHUB_REPOSITORY (owner/repo slug).
# ------------------------------------------------------------
ctx_build() {
  local -n _ctx_b="$1"
  local event="$2"
  local head_ref="$3"
  local base_ref="$4"
  local ref_name="$5"
  local target="${6:-${CTX_TARGET_CONTAINER}}"
  local sha="$7"
  local repo="$8"

  _ctx_b[${CTX_F_EVENT}]="${event}"
  _ctx_b[${CTX_F_HEAD}]="$(_ctx_strip_ref_prefix "${head_ref:-${ref_name}}")"
  _ctx_b[${CTX_F_BASE}]="$(_ctx_strip_ref_prefix "${base_ref}")"
  _ctx_b[${CTX_F_REF_NAME}]="$(_ctx_strip_ref_prefix "${ref_name}")"
  _ctx_b[${CTX_F_TARGET}]="${target}"
  _ctx_b[${CTX_F_SHA}]="${sha}"
  _ctx_b[${CTX_F_REPO}]="${repo}"
  _ctx_b[${CTX_F_RELEASE_VERSION}]=""
  _ctx_b[${CTX_F_RELEASE_VERSION_NUMBER}]=""
  _ctx_b[${CTX_F_BUILD_NUMBER}]=""
  _ctx_b[${CTX_F_SHOULD_RUN}]="false"
}

# ── Event predicates (accept event string) ───────────────────

ctx_is_pr()       { [[ "$1" == "${CTX_EVENT_PR}" ]]; }
ctx_is_push()     { [[ "$1" == "${CTX_EVENT_PUSH}" ]]; }
ctx_is_dispatch() { [[ "$1" == "${CTX_EVENT_DISPATCH}" ]]; }

# ── Project type detectors (accept workspace path) ───────────

# ------------------------------------------------------------
# @description  Returns 0 when the workspace contains a Dockerfile,
#               indicating this is a container project.
# @param $1     workspace - Absolute path to GITHUB_WORKSPACE.
# @return       0 if Dockerfile exists, 1 otherwise.
# ------------------------------------------------------------
ctx_is_container_project() {
  local workspace="$1"
  [[ -n "${workspace}" && -f "${workspace}/Dockerfile" ]]
}

# ------------------------------------------------------------
# @description  Returns 0 when the workspace contains a pubspec.yaml,
#               indicating this is a Flutter project.
# @param $1     workspace - Absolute path to GITHUB_WORKSPACE.
# @return       0 if pubspec.yaml exists, 1 otherwise.
# ------------------------------------------------------------
ctx_is_flutter_project() {
  local workspace="$1"
  [[ -n "${workspace}" && -f "${workspace}/pubspec.yaml" ]]
}

# ------------------------------------------------------------
# @description  Validates that a target_action string is a known value.
# @param $1     target - The target action to validate.
# @return       0 if valid (container | flutter), 1 otherwise.
# ------------------------------------------------------------
ctx_validate_target() {
  local target="$1"
  case "${target}" in
    "${CTX_TARGET_CONTAINER}" | "${CTX_TARGET_FLUTTER}") return 0 ;;
    *) return 1 ;;
  esac
}
