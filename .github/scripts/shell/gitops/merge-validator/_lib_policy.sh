#!/usr/bin/env bash
# ============================================================
# Domain: Policy — context constants, context object, event predicates,
#         registry-based dispatch, and output writing
# ============================================================

# ── Event type constants ─────────────────────────────────────
readonly MV_EVENT_PR="pull_request"
readonly MV_EVENT_PUSH="push"
readonly MV_EVENT_DISPATCH="workflow_dispatch"

# ── Config defaults (prefer environment > constant > default) ─
readonly MV_ORIGIN_BRANCH="main"
readonly MV_DEFAULT_FETCH_DEPTH=50
readonly MV_DEFAULT_MAX_BEHIND=0

# ── Context field keys ───────────────────────────────────────
readonly MV_F_EVENT="event"
readonly MV_F_HEAD="head"
readonly MV_F_BASE="base"
readonly MV_F_REF_NAME="ref_name"
readonly MV_F_FETCH_DEPTH="fetch_depth"
readonly MV_F_MAX_BEHIND="max_behind"
readonly MV_F_FRESHNESS_RESULT="freshness_result"

# ── Internal ─────────────────────────────────────────────────
readonly _MV_REF_PREFIX="refs/heads/"

# ------------------------------------------------------------
# @description  Strips the 'refs/heads/' prefix from a Git ref string,
#               normalizing it to a plain branch name.
# @param $1     ref - Full ref string (e.g. 'refs/heads/main').
# @stdout       Normalized branch name without prefix.
# @example
#   _mv_strip_ref_prefix "refs/heads/release/v1.2.3"
#   # Output: "release/v1.2.3"
#
#   _mv_strip_ref_prefix "main"
#   # Output: "main"  (no prefix present — string returned unchanged)
# ------------------------------------------------------------
_mv_strip_ref_prefix() {
	local ref="${1:-}"
	echo "${ref#${_MV_REF_PREFIX}}"
}

# ------------------------------------------------------------
# @description  Builds the merge-validator context associative array
#               from raw GitHub Actions environment values.
#               Called only from main(); all env var access is isolated here.
#
# @param $1     ctx_name    - Name of the caller's declared associative array.
# @param $2     event       - Raw GITHUB_EVENT_NAME value.
# @param $3     head_ref    - Raw GITHUB_HEAD_REF value (may be empty on push).
# @param $4     base_ref    - Raw GITHUB_BASE_REF value.
# @param $5     ref_name    - Raw GITHUB_REF_NAME value.
# @param $6     fetch_depth - INPUT_FETCH_DEPTH (optional; defaults to 50).
# @param $7     max_behind  - INPUT_MAX_BEHIND (optional; defaults to 0).
# @example
#   declare -A MV_CTX
#   ctx_build MV_CTX "pull_request" "refs/heads/release/v1.2.3" "main" "main" 50 0
#   # MV_CTX[event]="pull_request"
#   # MV_CTX[head]="release/v1.2.3"
#   # MV_CTX[base]="main"
#   # MV_CTX[fetch_depth]="50"
#   # MV_CTX[max_behind]="0"
#   # MV_CTX[freshness_result]="skipped"  (safe default; set by handler on success)
# ------------------------------------------------------------
ctx_build() {
	local -n _ctx_b="$1"
	local event="$2"
	local head_ref="$3"
	local base_ref="$4"
	local ref_name="$5"
	local fetch_depth="${6:-${MV_DEFAULT_FETCH_DEPTH}}"
	local max_behind="${7:-${MV_DEFAULT_MAX_BEHIND}}"

	_ctx_b[${MV_F_EVENT}]="${event}"
	_ctx_b[${MV_F_HEAD}]="$(_mv_strip_ref_prefix "${head_ref:-${ref_name}}")"
	_ctx_b[${MV_F_BASE}]="$(_mv_strip_ref_prefix "${base_ref}")"
	_ctx_b[${MV_F_REF_NAME}]="$(_mv_strip_ref_prefix "${ref_name}")"
	_ctx_b[${MV_F_FETCH_DEPTH}]="${fetch_depth}"
	_ctx_b[${MV_F_MAX_BEHIND}]="${max_behind}"
	_ctx_b[${MV_F_FRESHNESS_RESULT}]="skipped"
}

# ── Event predicates ─────────────────────────────────────────
# @example
#   ctx_is_pr       "pull_request"      && echo "is PR"       # prints "is PR"
#   ctx_is_push     "push"              && echo "is push"     # prints "is push"
#   ctx_is_dispatch "workflow_dispatch" && echo "is dispatch" # prints "is dispatch"

ctx_is_pr() { [[ "$1" == "${MV_EVENT_PR}" ]]; }
ctx_is_push() { [[ "$1" == "${MV_EVENT_PUSH}" ]]; }
ctx_is_dispatch() { [[ "$1" == "${MV_EVENT_DISPATCH}" ]]; }

# ── Event handlers ─────────────────────────────────────────────

# ------------------------------------------------------------
# @description  Policy for pull_request events. Validates branch freshness
#               only when the PR targets the protected main branch.
#               PRs targeting other branches (e.g. staging, develop) are
#               silently skipped — no freshness check applies there.
#               Sets freshness_result=valid on success.
#
# @param $1     ctx_name - Name of the merge-validator context associative array.
# @exitcode     1 if fetch fails, the branch is behind origin, or conflicts exist.
# @example
#   declare -A MV_CTX
#   ctx_build MV_CTX "pull_request" "release/v1.2.3" "main" "main" 50 0
#   _policy_handle_pr "MV_CTX"
#   # MV_CTX[freshness_result]="valid"  (branch is current and conflict-free)
#
#   # PR targeting 'staging' — silent skip, result stays 'skipped':
#   ctx_build MV_CTX "pull_request" "release/v1.2.3" "staging" "staging" 50 0
#   _policy_handle_pr "MV_CTX"
#   # MV_CTX[freshness_result]="skipped"
# ------------------------------------------------------------
_policy_handle_pr() {
	local ctx_name="$1"
	local -n _hpr="${ctx_name}"

	local base="${_hpr[${MV_F_BASE}]}"

	# Only enforce freshness for PRs targeting the protected origin branch.
	if [[ "${base}" != "${MV_ORIGIN_BRANCH}" ]]; then
		log_info "PR targeting '${base}' (not ${MV_ORIGIN_BRANCH}). Validation not applicable."
		return 0
	fi

	git_validate_branch_freshness \
		"${_hpr[${MV_F_HEAD}]}" \
		"${_hpr[${MV_F_FETCH_DEPTH}]}" \
		"${MV_ORIGIN_BRANCH}" \
		"${_hpr[${MV_F_MAX_BEHIND}]}" \
		"PR → ${MV_ORIGIN_BRANCH}"

	_hpr[${MV_F_FRESHNESS_RESULT}]="valid"
}

# ------------------------------------------------------------
# @description  Policy for push events. Branch freshness is not applicable
#               on push-to-main because the code already landed — the merge
#               itself proves the branch was accepted. Result is left as
#               'skipped' (the ctx_build default).
#
# @param $1     ctx_name - Name of the merge-validator context associative array.
# @example
#   declare -A MV_CTX
#   ctx_build MV_CTX "push" "" "" "main" 50 0
#   _policy_handle_push "MV_CTX"
#   # MV_CTX[freshness_result]="skipped"  (no validation runs on push)
# ------------------------------------------------------------
_policy_handle_push() {
	local ctx_name="$1"
	local -n _hpush="${ctx_name}"
	log_info "Push to '${_hpush[${MV_F_REF_NAME}]}'. Validation not applicable."
	# freshness_result intentionally remains 'skipped' (set in ctx_build).
}

# ------------------------------------------------------------
# @description  Policy for workflow_dispatch events. Validates the dispatched
#               branch for freshness before allowing manual promotion.
#               Operators may dispatch from long-lived branches, so we verify
#               the branch is current with main and has no conflicts before
#               allowing the pipeline to proceed.
#               Sets freshness_result=valid on success.
#
# @param $1     ctx_name - Name of the merge-validator context associative array.
# @exitcode     1 if fetch fails, the branch is behind origin, or conflicts exist.
# @example
#   declare -A MV_CTX
#   ctx_build MV_CTX "workflow_dispatch" "" "" "release/v1.2.3" 50 0
#   _policy_handle_dispatch "MV_CTX"
#   # MV_CTX[freshness_result]="valid"  (branch is current and conflict-free)
#
#   # Branch is 2 commits behind main — exits 1:
#   # ❌ [workflow_dispatch] 'release/v1.2.3' is 2 commit(s) behind 'main'
# ------------------------------------------------------------
_policy_handle_dispatch() {
	local ctx_name="$1"
	local -n _hdisp="${ctx_name}"

	git_validate_branch_freshness \
		"${_hdisp[${MV_F_REF_NAME}]}" \
		"${_hdisp[${MV_F_FETCH_DEPTH}]}" \
		"${MV_ORIGIN_BRANCH}" \
		"${_hdisp[${MV_F_MAX_BEHIND}]}" \
		"workflow_dispatch"

	_hdisp[${MV_F_FRESHNESS_RESULT}]="valid"
}

# ── Registry dispatch ─────────────────────────────────────────

# ------------------------------------------------------------
# @description  Evaluates the branch freshness policy for the current event
#               using a registry (dispatch table). Maps each known event type
#               to its handler. Unknown events result in freshness_result=skipped.
#
# @param $1     ctx_name - Name of the merge-validator context associative array.
# @example
#   declare -A MV_CTX
#   ctx_build MV_CTX "pull_request" "release/v1.2.3" "main" "main" 50 0
#   policy_evaluate "MV_CTX"
#   # Dispatches to _policy_handle_pr
#   # MV_CTX[freshness_result]="valid" on success
#
#   # Unknown event — warning, result stays 'skipped':
#   ctx_build MV_CTX "schedule" ...
#   policy_evaluate "MV_CTX"
#   # ℹ️  Event 'schedule' has no validation policy. Skipping.
# ------------------------------------------------------------
policy_evaluate() {
	local ctx_name="$1"
	local -n _pe_ctx="${ctx_name}"

	local event="${_pe_ctx[${MV_F_EVENT}]}"

	declare -A _MV_HANDLER_REGISTRY=(
		["${MV_EVENT_PR}"]="_policy_handle_pr"
		["${MV_EVENT_PUSH}"]="_policy_handle_push"
		["${MV_EVENT_DISPATCH}"]="_policy_handle_dispatch"
	)

	local handler="${_MV_HANDLER_REGISTRY[${event}]:-}"

	if [[ -z "${handler}" ]]; then
		log_info "Event '${event}' has no validation policy. Skipping."
		return 0
	fi

	"${handler}" "${ctx_name}"
}

# ── Output ────────────────────────────────────────────────────

# ------------------------------------------------------------
# @description  Writes the branch_freshness_check result to the
#               GitHub Actions output file.
# @param $1     ctx_name    - Name of the context associative array.
# @param $2     output_file - Absolute path to GITHUB_OUTPUT file.
# @example
#   output_export "MV_CTX" "${GITHUB_OUTPUT}"
#   # Appends to GITHUB_OUTPUT:
#   #   branch_freshness_check=valid    (PR/dispatch after passing validation)
#   #   branch_freshness_check=skipped  (push event)
# ------------------------------------------------------------
output_export() {
	local ctx_name="$1"
	local output_file="$2"
	local -n _oe_ctx="${ctx_name}"

	echo "branch_freshness_check=${_oe_ctx[${MV_F_FRESHNESS_RESULT}]}" >>"${output_file}"
}

# ------------------------------------------------------------
# @description  Prints a human-readable branch freshness validation
#               summary to stderr for GitHub Actions log visibility.
# @param $1     ctx_name - Name of the context associative array.
# @example
#   output_summary "MV_CTX"
#   # Prints to stderr:
#   # ════════════════════════════════════════
#   #   Branch Freshness Validation Summary
#   # ════════════════════════════════════════
#   #   event             = pull_request
#   #   head              = release/v1.2.3
#   #   base              = main
#   #   ref               = release/v1.2.3
#   #   origin_branch     = main
#   #   max_behind        = 0
#   #   result            = valid
#   # ════════════════════════════════════════
# ------------------------------------------------------------
output_summary() {
	local ctx_name="$1"
	local -n _os_ctx="${ctx_name}"

	cat >&2 <<EOF

════════════════════════════════════════
  Branch Freshness Validation Summary
════════════════════════════════════════
  event             = ${_os_ctx[${MV_F_EVENT}]}
  head              = ${_os_ctx[${MV_F_HEAD}]}
  base              = ${_os_ctx[${MV_F_BASE}]}
  ref               = ${_os_ctx[${MV_F_REF_NAME}]}
  origin_branch     = ${MV_ORIGIN_BRANCH}
  max_behind        = ${_os_ctx[${MV_F_MAX_BEHIND}]}
  result            = ${_os_ctx[${MV_F_FRESHNESS_RESULT}]}
════════════════════════════════════════
EOF
}
