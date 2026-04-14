#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Constants
# ============================================================

readonly EXIT_ERROR=1
readonly INITIAL_TAG_SENTINEL=""
readonly NO_COMMITS_PLACEHOLDER="_No se encontraron commits._"

# ============================================================
# Logging
# ============================================================

log() {
  local level="$1"
  shift
  local -A prefixes=(
    [info]="ℹ️ "
    [ok]="✅"
    [warn]="⚠️ "
    [error]="❌"
  )
  echo "${prefixes[${level}]:-[${level}]} $*" >&2
}

# ============================================================
# Guards
# ============================================================

require_non_empty() {
  local value="$1"
  local name="$2"

  if [[ -z "${value}" ]]; then
    log error "${name} is not set."
    exit "${EXIT_ERROR}"
  fi
}

# ============================================================
# Tag Operations — params only; no env access
# ============================================================

tag_exists() {
  local version="$1"
  local repo="$2"

  gh api "repos/${repo}/git/ref/tags/${version}" &>/dev/null
}

create_tag() {
  local version="$1"
  local repo="$2"
  local sha="$3"

  log info "Creating tag '${version}' at commit '${sha}' in '${repo}'..."

  gh api "repos/${repo}/git/refs" \
    --method POST \
    -f "ref=refs/tags/${version}" \
    -f "sha=${sha}" \
    --silent

  log ok "Tag '${version}' created."
}

get_previous_tag() {
  local version="$1"
  local repo="$2"

  # After creating the new tag: index 0 = new tag, index 1 = previous tag.
  # Returns empty string (INITIAL_TAG_SENTINEL) when no previous tag exists.
  gh api "repos/${repo}/tags" --jq '.[1].name // ""'
}

get_tag_sha() {
  local tag="$1"
  local repo="$2"

  # One API call: lightweight tags have .object.type = "commit";
  # annotated tags have .object.type = "tag" and need a second dereference.
  local ref obj_type obj_sha
  ref="$(gh api "repos/${repo}/git/ref/tags/${tag}")"
  obj_type="$(echo "${ref}" | jq -r '.object.type')"
  obj_sha="$(echo "${ref}"  | jq -r '.object.sha')"

  if [[ "${obj_type}" == "tag" ]]; then
    gh api "repos/${repo}/git/tags/${obj_sha}" --jq '.object.sha'
  else
    echo "${obj_sha}"
  fi
}

# ============================================================
# Release Operations — params only; no env access
# ============================================================

get_commits_between() {
  local base_sha="$1"
  local head_sha="$2"
  local repo="$3"

  gh api "repos/${repo}/compare/${base_sha}...${head_sha}" \
    | jq -r --arg repo "${repo}" \
      '.commits[] | "\(.commit.message | split("\n")[0]) | https://github.com/\($repo)/commit/\(.sha)"' \
    2>/dev/null || true
}

build_release_body() {
  local tag_name="$1"
  local environment="$2"
  local date="$3"
  local commits_body="$4"

  printf '## 🚀 Release `%s` generado automáticamente por CI/CD\n\n' "${tag_name}"
  printf '📍 **Entorno:** `%s`\n'                                     "${environment}"
  printf '📅 **Fecha:** %s\n\n'                                        "${date}"
  printf -- '---\n\n'
  printf '### 📦 Cambios incluidos:\n\n'
  printf '%s\n'                                                         "${commits_body}"
}

create_release() {
  local version="$1"
  local repo="$2"
  local prev_sha="$3"
  local current_sha="$4"
  local environment="$5"

  local current_date
  current_date="$(date +"%Y-%m-%d-%H-%M-%S")"

  local commits_body="${NO_COMMITS_PLACEHOLDER}"
  if [[ -n "${prev_sha}" ]]; then
    local commits
    commits="$(get_commits_between "${prev_sha}" "${current_sha}" "${repo}")"
    [[ -n "${commits}" ]] && commits_body="${commits}"
  fi

  local body
  body="$(build_release_body "${version}" "${environment}" "${current_date}" "${commits_body}")"

  log info "Creating release '${version}' in '${repo}'..."

  gh release create "${version}" \
    --repo "${repo}" \
    --notes "${body}"

  log ok "Release '${version}' created."
}

# ============================================================
# Outputs
# ============================================================

export_outputs() {
  local output_file="$1"
  local release_url="$2"

  {
    echo "tag_created=true"
    echo "release_created=true"
    echo "release_url=${release_url}"
  } >>"${output_file}"
}

print_summary() {
  local version="$1"
  local repo="$2"
  local prev_tag="$3"
  local release_url="$4"

  printf '\n%s\n'         "════════════════════════════════════════"
  printf '  %s\n'         "Tag & Release Creation Summary"
  printf '%s\n'           "════════════════════════════════════════"
  printf '  %-18s = %s\n' "repository"      "${repo}"
  printf '  %-18s = %s\n' "release_version" "${version}"
  printf '  %-18s = %s\n' "previous_tag"    "${prev_tag:-none}"
  printf '  %-18s = %s\n' "release_url"     "${release_url}"
  printf '  %-18s = %s\n' "result"          "success"
  printf '%s\n'           "════════════════════════════════════════"
}

# ============================================================
# Main — sole owner of env var access; assembles context; orchestrates
# ============================================================

main() {
  local version="${INPUT_RELEASE_VERSION:-}"
  local repo="${GITHUB_REPOSITORY:-}"
  local sha="${GITHUB_SHA:-}"
  local environment="${INPUT_ENVIRONMENT:-}"
  local output_file="${GITHUB_OUTPUT:-}"

  require_non_empty "${version}"     "INPUT_RELEASE_VERSION"
  require_non_empty "${repo}"        "GITHUB_REPOSITORY"
  require_non_empty "${sha}"         "GITHUB_SHA"
  require_non_empty "${environment}" "INPUT_ENVIRONMENT"

  if tag_exists "${version}" "${repo}"; then
    log error "Tag '${version}' already exists in '${repo}'. Aborting."
    exit "${EXIT_ERROR}"
  fi

  create_tag "${version}" "${repo}" "${sha}"

  local prev_tag prev_sha
  prev_tag="$(get_previous_tag "${version}" "${repo}")"
  prev_sha="${INITIAL_TAG_SENTINEL}"

  if [[ -n "${prev_tag}" ]]; then
    prev_sha="$(get_tag_sha "${prev_tag}" "${repo}")"
  fi

  create_release "${version}" "${repo}" "${prev_sha}" "${sha}" "${environment}"

  local release_url
  release_url="$(gh release view "${version}" --repo "${repo}" --json url --jq '.url')"

  export_outputs "${output_file}" "${release_url}"
  print_summary  "${version}" "${repo}" "${prev_tag}" "${release_url}"
}

main
