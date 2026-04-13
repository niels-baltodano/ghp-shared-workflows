#!/usr/bin/env bash
# set -euo pipefail
set -ex

# ============================================================
# Constants
# ============================================================

readonly EXIT_ERROR=1
readonly REGISTRY="ghcr.io"
readonly PLATFORM="linux/amd64"

readonly SECURITY_ALLOW_PUSH_TO_GHCR="${INPUT_SECURITY_ALLOW_PUSH_TO_GHCR:-false}"
readonly IS_SINGLE_BRANCH_DEPLOYMENT="${INPUT_IS_SINGLE_BRANCH_DEPLOYMENT:-false}"

readonly TRIVY_SEVERITY="${INPUT_TRIVY_SEVERITY:-CRITICAL,HIGH}"
readonly TRIVY_EXIT_CODE="${INPUT_TRIVY_EXIT_CODE:-1}"
readonly TRIVY_IGNORE_UNFIXED="${INPUT_TRIVY_IGNORE_UNFIXED:-true}"

readonly REF_PREFIX_HEADS="refs/heads/"
REF_NAME="${GITHUB_REF_NAME:-}"
REF_NAME="${REF_NAME#"${REF_PREFIX_HEADS}"}"
readonly REF_NAME

# ============================================================
# Logging
# ============================================================

log_info() { echo "ℹ️  $*" >&2; }
log_ok() { echo "✅ $*" >&2; }
log_error() { echo "❌ $*" >&2; }

# ============================================================
# Shared Helpers
# ============================================================

_trim() {
  local value="${1-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

_strip_matching_quotes() {
  local value="${1-}"

  if [[ ${#value} -ge 2 ]]; then
    if [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
      printf '%s' "${value:1:${#value}-2}"
      return 0
    fi
    if [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
      printf '%s' "${value:1:${#value}-2}"
      return 0
    fi
  fi

  printf '%s' "${value}"
}

get_repository_name() {
  local repository="${GITHUB_REPOSITORY,,}"

  if [[ "${IS_SINGLE_BRANCH_DEPLOYMENT}" == "true" ]]; then
    repository="${repository}-${REF_NAME}"
  fi

  echo "${repository//_/-}"
}

resolve_image_name() {
  local repository
  repository="$(get_repository_name)"

  local short_sha="${GITHUB_SHA:0:7}"
  echo "${REGISTRY}/${repository}:${short_sha}"
}

# ============================================================
# Command: build
# ============================================================

_validate_dockerfile() {
  local dockerfile_path="$1"

  if [[ ! -f "${dockerfile_path}" ]]; then
    log_error "Dockerfile not found at ${dockerfile_path}"
    return 1
  fi
}

_validate_docker_daemon() {
  if ! docker info &>/dev/null; then
    log_error "Docker daemon not available."
    return 1
  fi
}

# ------------------------------------------------------------
# Parsea una línea KEY=VALUE de .env de forma estricta.
#
# Reglas:
# - Ignora líneas vacías y comentarios.
# - Soporta "export KEY=VALUE".
# - Elimina CRLF.
# - Elimina UTF-8 BOM al inicio si existe.
# - No ejecuta shell.
# - No expande variables.
#
# Args:
#   $1: Línea completa.
#   $2: Nombre de variable destino para key (nameref).
#   $3: Nombre de variable destino para value (nameref).
#
# Returns:
#   0 si la línea es válida.
#   1 si debe ignorarse o es inválida.
# ------------------------------------------------------------
_parse_env_line() {
  local raw_line="${1-}"
  local -n _key_ref="$2"
  local -n _value_ref="$3"

  _key_ref=""
  _value_ref=""

  raw_line="${raw_line%$'\r'}"
  raw_line="${raw_line#$'\xEF\xBB\xBF'}"
  raw_line="$(_trim "${raw_line}")"

  [[ -z "${raw_line}" ]] && return 1
  [[ "${raw_line}" == \#* ]] && return 1

  if [[ "${raw_line}" == export[[:space:]]* ]]; then
    raw_line="${raw_line#export }"
    raw_line="$(_trim "${raw_line}")"
  fi

  [[ "${raw_line}" == *"="* ]] || return 1

  local parsed_key="${raw_line%%=*}"
  local parsed_value="${raw_line#*=}"

  parsed_key="$(_trim "${parsed_key}")"
  parsed_value="$(_trim "${parsed_value}")"

  [[ -n "${parsed_key}" ]] || return 1

  if ! [[ "${parsed_key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    log_error "Invalid env var name in .env: ${parsed_key}"
    return 1
  fi

  parsed_value="$(_strip_matching_quotes "${parsed_value}")"

  _key_ref="${parsed_key}"
  _value_ref="${parsed_value}"
  return 0
}

# ------------------------------------------------------------
# Lee un archivo .env y construye argumentos --build-arg.
#
# Diseño:
# - No usa source.
# - No ejecuta comandos.
# - No expande variables.
# - Solo convierte entradas válidas KEY=VALUE en:
#     --build-arg KEY=VALUE
#
# Args:
#   $1: Ruta del archivo .env.
#   $2: Nombre del array destino (nameref).
#
# Returns:
#   0 si el procesamiento termina correctamente.
# ------------------------------------------------------------
_parse_env_build_args() {
  local env_file="$1"
  local -n _args_ref="$2"

  if [[ ! -f "${env_file}" ]]; then
    log_info "No .env file found at ${env_file}. Continuing without build args."
    return 0
  fi

  log_info "Loading build arguments from ${env_file}"

  local line="" key="" value=""
  local line_number=0 build_arg_count=0

  while IFS= read -r line || [[ -n "${line}" ]]; do
    ((line_number += 1))

    if _parse_env_line "${line}" key value; then
      _args_ref+=(--build-arg "${key}=${value}")
      ((build_arg_count += 1))
      log_info "Loaded build arg key: ${key}"
    else
      local visible_line
      visible_line="$(_trim "${line%$'\r'}")"
      visible_line="${visible_line#$'\xEF\xBB\xBF'}"

      if [[ -n "${visible_line}" && "${visible_line}" != \#* ]]; then
        log_info "Ignoring non-supported .env line ${line_number}: ${visible_line}"
      fi
    fi
  done <"${env_file}"

  log_info "Loaded ${build_arg_count} build args from .env"
}

# ------------------------------------------------------------
# Construye los flags --label con OCI annotations estándar.
# Vincula la imagen al repositorio GitHub en GHCR packages.
#
# OCI annotations:
#   image.source      → asocia el package al repo en GitHub ⭐
#   image.revision    → SHA del commit para trazabilidad
#   image.created     → timestamp ISO 8601 del build
#   image.description → descripción del origen
#   image.branch      → nombre de la rama (si aplica)
#   image.authors     → autor del build (GITHUB_ACTOR)
#   image.github.action.url → URL del run de GitHub Actions
# Args:
#   $1: Nombre del array destino (nameref).
# ------------------------------------------------------------
_build_oci_labels() {
  local -n _labels_ref="$1"

  local created_at
  created_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  _labels_ref+=(
    --label "org.opencontainers.image.source=https://github.com/${GITHUB_REPOSITORY}"
    --label "org.opencontainers.image.revision=${GITHUB_SHA}"
    --label "org.opencontainers.image.created=${created_at}"
    --label "org.opencontainers.image.description=Built from ${GITHUB_REPOSITORY}"
    --label "org.opencontainers.image.branch=${REF_NAME}"
    --label "org.opencontainers.image.authors=${GITHUB_ACTOR}"
    --label "org.opencontainers.image.github.action.url=https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
  )

  log_info "OCI labels configured for: https://github.com/${GITHUB_REPOSITORY}"
}

# ------------------------------------------------------------
# Ejecuta el build de Docker usando buildx.
#
# Args:
#   $1: Nombre de imagen.
#   $2: Plataforma.
#   $3: Contexto del build.
#   $@: Argumentos adicionales (--build-arg, --label, etc.)
# ------------------------------------------------------------
_docker_build() {
  local image_name="$1"
  local platform="$2"
  local context="$3"
  shift 3
  local extra_args=("$@")

  log_info "Building image: ${image_name}"

  if [[ "${#extra_args[@]}" -gt 0 ]]; then
    log_info "Docker build args/labels (${#extra_args[@]} tokens):"
    printf 'ℹ️    %q\n' "${extra_args[@]}" >&2
  fi

  docker buildx build \
    --platform "${platform}" \
    --provenance=false \
    --load \
    -t "${image_name}" \
    "${extra_args[@]}" \
    "${context}"
}

_write_build_outputs() {
  local image_name="$1"
  local sha="$2"

  {
    echo "container_image_name_ghcr=${image_name}"
    echo "client_repo_sha=${sha}"
  } >>"${GITHUB_OUTPUT}"
}

_write_push_outputs() {
  local image_digest="$1"

  echo "container_image_digest_ghcr=${image_digest}" >>"${GITHUB_OUTPUT}"
}

# ------------------------------------------------------------
# Comando principal de build.
#
# Flujo:
# 1. Resuelve nombre de imagen.
# 2. Valida Dockerfile y daemon Docker.
# 3. Lee .env y genera --build-arg.
# 4. Genera --label OCI annotations.
# 5. Ejecuta docker buildx build.
# 6. Escribe outputs de GitHub Actions.
# ------------------------------------------------------------
cmd_build() {
  local image_name=""
  local build_args=()
  local label_args=()

  image_name="$(resolve_image_name)"

  _validate_dockerfile "${GITHUB_WORKSPACE}/Dockerfile" || exit "${EXIT_ERROR}"
  _validate_docker_daemon || exit "${EXIT_ERROR}"

  _parse_env_build_args "${GITHUB_WORKSPACE}/.env" build_args
  _build_oci_labels label_args

  _docker_build \
    "${image_name}" \
    "${PLATFORM}" \
    "${GITHUB_WORKSPACE}" \
    "${build_args[@]+"${build_args[@]}"}" \
    "${label_args[@]}"

  log_ok "Image built: ${image_name}"

  _write_build_outputs "${image_name}" "${GITHUB_SHA}"
}

# ============================================================
# Command: scan
# ============================================================

cmd_scan() {
  local image_name="${INPUT_IMAGE_NAME:-}"

  if [[ -z "${image_name}" ]]; then
    log_error "INPUT_IMAGE_NAME is required for scan."
    exit "${EXIT_ERROR}"
  fi

  if ! command -v trivy &>/dev/null; then
    log_error "Trivy not found."
    exit "${EXIT_ERROR}"
  fi

  if [[ "${SECURITY_ALLOW_PUSH_TO_GHCR}" == "true" ]]; then
    log_info "SECURITY_ALLOW_PUSH_TO_GHCR=true. Skipping scan."
    {
      echo "trivy_scan_result=skipped"
      echo "trivy_report_path=${TRIVY_REPORT_PATH}"
    } >>"${GITHUB_OUTPUT}"
    return 0
  fi

  log_info "Scanning image (severity=${TRIVY_SEVERITY})..."

  local trivy_args=(
    image
    --severity "${TRIVY_SEVERITY}"
    --exit-code "${TRIVY_EXIT_CODE}"
    --format table
    --no-progress
  )

  [[ "${TRIVY_IGNORE_UNFIXED}" == "true" ]] && trivy_args+=(--ignore-unfixed)

  if ! trivy "${trivy_args[@]}" "${image_name}"; then
    log_error "Vulnerabilities found above threshold (${TRIVY_SEVERITY})."
    echo "trivy_scan_result=failed" >>"${GITHUB_OUTPUT}"
    exit "${EXIT_ERROR}"
  fi

  log_ok "Scan passed. No vulnerabilities above threshold."
  echo "trivy_scan_result=passed" >>"${GITHUB_OUTPUT}"
}

# ============================================================
# Command: push
# ============================================================

# ------------------------------------------------------------
# Publica la imagen construida al registry y resuelve su digest.
#
# Requisitos:
# - INPUT_IMAGE_NAME debe estar definido.
#
# Flujo:
# 1. Ejecuta docker push.
# 2. Intenta resolver el digest vía docker inspect.
# 3. Si falla, usa docker buildx imagetools inspect.
# 4. Escribe el digest en GITHUB_OUTPUT.
# 5. Limpia imágenes dangling.
# ------------------------------------------------------------
cmd_push() {
  local image_name="${INPUT_IMAGE_NAME:-}"

  if [[ -z "${image_name}" ]]; then
    log_error "INPUT_IMAGE_NAME is required for push."
    exit "${EXIT_ERROR}"
  fi

  log_info "Pushing image: ${image_name}"
  docker push "${image_name}"

  local digest=""
  digest="$(docker inspect --format='{{index .RepoDigests 0}}' "${image_name}" 2>/dev/null | sed 's/.*@//')" || true

  if [[ -z "${digest}" ]]; then
    digest="$(docker buildx imagetools inspect "${image_name}" |
      awk '/^Digest:/{print $2; exit}')" || true
  fi

  if [[ -z "${digest}" ]]; then
    log_error "Failed to retrieve image digest."
    exit "${EXIT_ERROR}"
  fi

  local image_digest="${REGISTRY}/$(get_repository_name)@${digest}"
  log_ok "Image pushed. Digest: ${image_digest}"

  _write_push_outputs "${image_digest}"

  log_info "Cleaning up dangling images..."
  docker image prune -f >/dev/null 2>&1 || true
}

# ============================================================
# Entry Point
# ============================================================

# ------------------------------------------------------------
# Punto de entrada principal del script.
#
# Comandos soportados:
# - build
# - scan
# - push
#
# Args:
#   $1: Nombre del comando a ejecutar.
# ------------------------------------------------------------
main() {
  local command="${1:-}"

  case "${command}" in
  build) cmd_build ;;
  scan) cmd_scan ;;
  push) cmd_push ;;
  *)
    log_error "Usage: $0 {build|scan|push}"
    exit "${EXIT_ERROR}"
    ;;
  esac
}

main "$@"
