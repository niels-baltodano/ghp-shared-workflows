#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Constants
# Compatible con GitHub Actions ubuntu-latest
# ============================================================

readonly EVENT_PULL_REQUEST="pull_request"
readonly EVENT_PUSH="push"
readonly EVENT_WORKFLOW_DISPATCH="workflow_dispatch"

readonly TARGET_ACTION_CONTAINER="container"
readonly TARGET_ACTION_FLUTTER="flutter"

readonly EXIT_ERROR=1
readonly REF_PREFIX_HEADS="refs/heads/"

# No Flutter: release|hotfix|bugfix/vX.Y.Z
readonly RELEASE_BRANCH_REGEX='^(release|hotfix|bugfix)/(v[0-9]+\.[0-9]+\.[0-9]+)$'

# Flutter: release|hotfix|bugfix/vX.Y.Z+BUILD
readonly FLUTTER_RELEASE_BRANCH_REGEX='^(release|hotfix|bugfix)/(v[0-9]+\.[0-9]+\.[0-9]+\+([0-9]+))$'

# ============================================================
# Global State
# ============================================================

EVENT=""
HEAD=""
BASE=""
REF_NAME=""
TARGET_ACTION=""

RELEASE_VERSION=""
RELEASE_VERSION_NUMBER=""
BUILD_NUMBER=""
SHOULD_RUN=false

# ============================================================
# Logging
# ============================================================

log_info() { echo "ℹ️  $*" >&2; }
log_ok() { echo "✅ $*" >&2; }
log_warn() { echo "⚠️  $*" >&2; }
log_error() { echo "❌ $*" >&2; }

# ============================================================
# Helpers
# ============================================================

strip_heads_prefix() {
  local value="${1:-}"
  echo "${value#${REF_PREFIX_HEADS}}"
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    log_error "La variable requerida '${name}' no está definida."
    exit "${EXIT_ERROR}"
  fi
}

# ============================================================
# Context Resolution
# ============================================================

resolve_context() {
  require_env "GITHUB_EVENT_NAME"
  require_env "GITHUB_REF_NAME"

  EVENT="${GITHUB_EVENT_NAME}"
  HEAD="$(strip_heads_prefix "${GITHUB_HEAD_REF:-${GITHUB_REF_NAME}}")"
  BASE="$(strip_heads_prefix "${GITHUB_BASE_REF:-}")"
  REF_NAME="$(strip_heads_prefix "${GITHUB_REF_NAME}")"
  TARGET_ACTION="${INPUT_TARGET_ACTION:-${TARGET_ACTION_CONTAINER}}"

  log_info "Context: event=${EVENT} head=${HEAD} base=${BASE} ref=${REF_NAME} target=${TARGET_ACTION}"
}

# ============================================================
# Event Type Checks
# ============================================================

is_pull_request() { [[ "${EVENT}" == "${EVENT_PULL_REQUEST}" ]]; }
is_push() { [[ "${EVENT}" == "${EVENT_PUSH}" ]]; }
is_dispatch() { [[ "${EVENT}" == "${EVENT_WORKFLOW_DISPATCH}" ]]; }

# ============================================================
# Project Type Checks
# ============================================================

is_container_project() {
  [[ -n "${GITHUB_WORKSPACE:-}" && -f "${GITHUB_WORKSPACE}/Dockerfile" ]]
}

is_flutter_project() {
  [[ -n "${GITHUB_WORKSPACE:-}" && -f "${GITHUB_WORKSPACE}/pubspec.yaml" ]]
}

# ============================================================
# Flutter helpers
# ============================================================

get_flutter_pubspec_version() {
  local pubspec_file="${GITHUB_WORKSPACE}/pubspec.yaml"
  local version=""

  if [[ ! -f "${pubspec_file}" ]]; then
    log_error "No existe pubspec.yaml en '${pubspec_file}'"
    return 1
  fi

  if ! command -v yq >/dev/null 2>&1; then
    log_error "El comando 'yq' no está instalado o no está en PATH"
    return 1
  fi

  version="$(yq -r '.version' "${pubspec_file}")"

  if [[ -z "${version}" || "${version}" == "null" ]]; then
    log_error "No se pudo leer '.version' desde pubspec.yaml"
    return 1
  fi

  if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$ ]]; then
    log_error "La versión en pubspec.yaml no cumple el formato esperado 'X.Y.Z+BUILD'. Valor encontrado: ${version}"
    return 1
  fi

  echo "${version}"
}

extract_build_number_from_version() {
  local version="$1"

  if [[ "${version}" =~ \+([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

# ============================================================
# Branch Type Checks
# ============================================================

is_hotfix_branch() {
  local branch="$1"
  [[ "${branch}" =~ ^hotfix/ ]]
}

resolve_active_branch() {
  if is_pull_request; then
    echo "${HEAD}"
  else
    echo "${REF_NAME}"
  fi
}

# ============================================================
# Branch Validation
# ============================================================

validate_release_branch() {
  local branch="$1"
  local context="$2"
  local regex=""
  local version_with_v=""
  local version_without_v=""
  local pubspec_version=""
  local build_number=""

  if is_flutter_project; then
    regex="${FLUTTER_RELEASE_BRANCH_REGEX}"
  else
    regex="${RELEASE_BRANCH_REGEX}"
  fi

  if [[ ! "${branch}" =~ ${regex} ]]; then
    log_error "[${context}] La rama '${branch}' no cumple el patrón: ${regex}"
    return 1
  fi

  version_with_v="${BASH_REMATCH[2]}"
  version_without_v="${version_with_v#v}"

  if is_flutter_project; then
    pubspec_version="$(get_flutter_pubspec_version)" || return 1

    if [[ "${pubspec_version}" != "${version_without_v}" ]]; then
      log_error "[${context}] La versión de la rama '${version_without_v}' no coincide con pubspec.yaml '${pubspec_version}'"
      return 1
    fi

    build_number="$(extract_build_number_from_version "${version_without_v}")" || {
      log_error "[${context}] No se pudo extraer el BUILD desde '${version_without_v}'"
      return 1
    }

    BUILD_NUMBER="${build_number}"
    log_ok "[${context}] Rama Flutter válida, pubspec coincidente y BUILD extraído: ${BUILD_NUMBER}"
  else
    BUILD_NUMBER=""
    log_ok "[${context}] Rama válida: ${branch} → version=${version_with_v}"
  fi

  RELEASE_VERSION="${version_with_v}"
  RELEASE_VERSION_NUMBER="${version_without_v}"

  return 0
}

# # ============================================================
# # Target Validation
# # ============================================================

validate_target_action() {
  case "${TARGET_ACTION}" in
  "${TARGET_ACTION_CONTAINER}")
    return 0
    ;;
  "${TARGET_ACTION_FLUTTER}")
    return 0
    ;;
  *)
    return 1
    ;;
  esac
}

# ============================================================
# Policy Evaluation
# ============================================================

evaluate_policy() {
  if is_pull_request; then
    if [[ "${BASE}" != "main" ]]; then
      log_info "PR hacia '${BASE}' (no main). La política no aplica."
      SHOULD_RUN=false
      return 0
    fi

    if ! validate_release_branch "${HEAD}" "PR → main"; then
      log_error "PR hacia main desde rama no permitida."
      exit "${EXIT_ERROR}"
    fi

    SHOULD_RUN=true
    return 0
  fi

  if is_push && [[ "${REF_NAME}" == "main" ]]; then
    log_ok "Push a main detectado."
    SHOULD_RUN=true
    return 0
  fi

  if is_dispatch; then
    if ! validate_release_branch "${REF_NAME}" "workflow_dispatch"; then
      log_error "workflow_dispatch desde rama no permitida."
      exit "${EXIT_ERROR}"
    fi

    SHOULD_RUN=true
    return 0
  fi

  log_warn "Evento '${EVENT}' sin política definida. El pipeline no se ejecutará."
  SHOULD_RUN=false
  return 0
}

# ============================================================
# Outputs
# ============================================================

export_outputs() {
  local should_run="$1"

  require_env "GITHUB_OUTPUT"

  local is_pr_event=false
  local is_push_event=false
  local is_dispatch_event=false
  local target_is_container=false
  local target_is_flutter=false
  local project_is_container=false
  local project_is_flutter=false
  local active_branch=""
  local branch_is_hotfix=false

  is_pull_request && is_pr_event=true
  is_push && is_push_event=true
  is_dispatch && is_dispatch_event=true
  validate_target_action && target_is_container=true
  [[ "${TARGET_ACTION}" == "${TARGET_ACTION_FLUTTER}" ]] && target_is_flutter=true
  is_container_project && project_is_container=true
  is_flutter_project && project_is_flutter=true

  active_branch="$(resolve_active_branch)"
  is_hotfix_branch "${active_branch}" && branch_is_hotfix=true

  {
    echo "should_run=${should_run}"
    echo "target_action=${TARGET_ACTION}"
    echo "release_version=${RELEASE_VERSION}"
    echo "release_version_number=${RELEASE_VERSION_NUMBER}"
    echo "build_number=${BUILD_NUMBER}"
    echo "is_pr=${is_pr_event}"
    echo "is_push=${is_push_event}"
    echo "is_dispatch=${is_dispatch_event}"
    # echo "target_is_container=${target_is_container}"
    echo "is_container=${project_is_container}"
    echo "is_hotfix=${branch_is_hotfix}"
    echo "is_flutter=${project_is_flutter}"
    echo "active_branch=${active_branch}"
  } >>"${GITHUB_OUTPUT}"
  # log de los outputs para visibilidad en logs (opcional)
  log_info "Outputs exportados:"
  log_info "  should_run=${should_run}"
  log_info "  target_action=${TARGET_ACTION}"
  log_info "  release_version=${RELEASE_VERSION}"
  log_info "  release_version_number=${RELEASE_VERSION_NUMBER}"
  log_info "  build_number=${BUILD_NUMBER}"
  log_info "  is_pr=${is_pr_event}"
  log_info "  is_push=${is_push_event}"
  log_info "  is_dispatch=${is_dispatch_event}"
  # log_info "  target_is_container=${target_is_container}"
  log_info "  is_container=${project_is_container}"
  log_info "  is_hotfix=${branch_is_hotfix}"
  log_info "  is_flutter=${project_is_flutter}"
  log_info "  active_branch=${active_branch}"
}

# ============================================================
# Summary
# ============================================================

print_summary() {
  local should_run="$1"

  echo "" >&2
  echo "════════════════════════════════════════" >&2
  echo "  Policy Gate Summary" >&2
  echo "════════════════════════════════════════" >&2
  echo "  event                = ${EVENT}" >&2
  echo "  head                 = ${HEAD}" >&2
  echo "  base                 = ${BASE}" >&2
  echo "  ref                  = ${REF_NAME}" >&2
  echo "  target_action        = ${TARGET_ACTION}" >&2
  echo "  release_version      = ${RELEASE_VERSION:-<none>}" >&2
  echo "  release_version_num  = ${RELEASE_VERSION_NUMBER:-<none>}" >&2
  echo "  build_number         = ${BUILD_NUMBER:-<none>}" >&2
  echo "  should_run           = ${should_run}" >&2
  echo "  is_container         = $(is_container_project && echo true || echo false)" >&2
  echo "════════════════════════════════════════" >&2
}

# ============================================================
# Main
# ============================================================

main() {
  resolve_context

  if ! validate_target_action; then
    log_error "target_action no soportado: '${TARGET_ACTION}'"
    exit "${EXIT_ERROR}"
  fi

  SHOULD_RUN=false
  evaluate_policy
  export_outputs "${SHOULD_RUN}"
  print_summary "${SHOULD_RUN}"
}

main "$@"
