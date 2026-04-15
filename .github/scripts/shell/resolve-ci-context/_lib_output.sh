#!/usr/bin/env bash
# ============================================================
# Domain: Output — GitHub Actions output writing and summary reporting
# ============================================================

# ------------------------------------------------------------
# @description  Derives all boolean flags from the CI context and
#               writes them to the GitHub Actions output file.
#               Logs every field to stderr for run visibility.
#
# @param $1     ctx_name    - Name of the CI context associative array.
# @param $2     workspace   - Absolute path to GITHUB_WORKSPACE.
# @param $3     output_file - Absolute path to GITHUB_OUTPUT file.
# ------------------------------------------------------------
output_export() {
  local ctx_name="$1"
  local workspace="$2"
  local output_file="$3"
  local -n _oe_ctx="${ctx_name}"

  local event="${_oe_ctx[${CTX_F_EVENT}]}"

  local is_pr_flag=false
  local is_push_flag=false
  local is_dispatch_flag=false
  ctx_is_pr       "${event}" && is_pr_flag=true
  ctx_is_push     "${event}" && is_push_flag=true
  ctx_is_dispatch "${event}" && is_dispatch_flag=true

  local is_container_flag=false
  local is_flutter_flag=false
  ctx_is_container_project "${workspace}" && is_container_flag=true
  ctx_is_flutter_project   "${workspace}" && is_flutter_flag=true

  local active_branch
  active_branch="$(branch_resolve_active \
    "${event}" \
    "${_oe_ctx[${CTX_F_HEAD}]}" \
    "${_oe_ctx[${CTX_F_REF_NAME}]}")"

  local is_hotfix_flag=false
  branch_is_hotfix "${active_branch}" && is_hotfix_flag=true

  {
    echo "should_run=${_oe_ctx[${CTX_F_SHOULD_RUN}]}"
    echo "target_action=${_oe_ctx[${CTX_F_TARGET}]}"
    echo "release_version=${_oe_ctx[${CTX_F_RELEASE_VERSION}]}"
    echo "release_version_number=${_oe_ctx[${CTX_F_RELEASE_VERSION_NUMBER}]}"
    echo "build_number=${_oe_ctx[${CTX_F_BUILD_NUMBER}]}"
    echo "is_pr=${is_pr_flag}"
    echo "is_push=${is_push_flag}"
    echo "is_dispatch=${is_dispatch_flag}"
    echo "is_container=${is_container_flag}"
    echo "is_hotfix=${is_hotfix_flag}"
    echo "is_flutter=${is_flutter_flag}"
    echo "active_branch=${active_branch}"
  } >>"${output_file}"

  log_info "Outputs exported:"
  log_info "  should_run             = ${_oe_ctx[${CTX_F_SHOULD_RUN}]}"
  log_info "  target_action          = ${_oe_ctx[${CTX_F_TARGET}]}"
  log_info "  release_version        = ${_oe_ctx[${CTX_F_RELEASE_VERSION}]}"
  log_info "  release_version_number = ${_oe_ctx[${CTX_F_RELEASE_VERSION_NUMBER}]}"
  log_info "  build_number           = ${_oe_ctx[${CTX_F_BUILD_NUMBER}]}"
  log_info "  is_pr                  = ${is_pr_flag}"
  log_info "  is_push                = ${is_push_flag}"
  log_info "  is_dispatch            = ${is_dispatch_flag}"
  log_info "  is_container           = ${is_container_flag}"
  log_info "  is_hotfix              = ${is_hotfix_flag}"
  log_info "  is_flutter             = ${is_flutter_flag}"
  log_info "  active_branch          = ${active_branch}"
}

# ------------------------------------------------------------
# @description  Prints a human-readable policy gate summary to stderr.
#               Useful for tracing the context that led to a given
#               should_run decision in the GitHub Actions log.
#
# @param $1     ctx_name  - Name of the CI context associative array.
# @param $2     workspace - Absolute path to GITHUB_WORKSPACE.
# ------------------------------------------------------------
output_summary() {
  local ctx_name="$1"
  local workspace="$2"
  local -n _os_ctx="${ctx_name}"

  local is_container_flag
  is_container_flag="$(ctx_is_container_project "${workspace}" && echo true || echo false)"

  cat >&2 <<EOF

════════════════════════════════════════
  Policy Gate Summary
════════════════════════════════════════
  event                = ${_os_ctx[${CTX_F_EVENT}]}
  head                 = ${_os_ctx[${CTX_F_HEAD}]}
  base                 = ${_os_ctx[${CTX_F_BASE}]}
  ref                  = ${_os_ctx[${CTX_F_REF_NAME}]}
  target_action        = ${_os_ctx[${CTX_F_TARGET}]}
  release_version      = ${_os_ctx[${CTX_F_RELEASE_VERSION}]:-<none>}
  release_version_num  = ${_os_ctx[${CTX_F_RELEASE_VERSION_NUMBER}]:-<none>}
  build_number         = ${_os_ctx[${CTX_F_BUILD_NUMBER}]:-<none>}
  should_run           = ${_os_ctx[${CTX_F_SHOULD_RUN}]}
  is_container         = ${is_container_flag}
════════════════════════════════════════
EOF
}
