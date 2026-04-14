#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Constants
# ============================================================

readonly EVENT_PULL_REQUEST="pull_request"
readonly EVENT_PUSH="push"
readonly EVENT_WORKFLOW_DISPATCH="workflow_dispatch"

readonly ORIGIN_BRANCH="main"
readonly REF_PREFIX_HEADS="refs/heads/"
readonly FETCH_DEPTH="${INPUT_FETCH_DEPTH:-50}"
readonly MAX_BEHIND="${INPUT_MAX_BEHIND:-0}"

readonly EXIT_ERROR=1

# ============================================================
# Logging
# ============================================================

log_info() { echo "ℹ️  $*" >&2; }
log_ok() { echo "✅ $*" >&2; }
log_warn() { echo "⚠️  $*" >&2; }
log_error() { echo "❌ $*" >&2; }

# ============================================================
# Context Resolution
# ============================================================

resolve_context() {
	readonly EVENT="${GITHUB_EVENT_NAME}"
	readonly HEAD="$(echo "${GITHUB_HEAD_REF:-${GITHUB_REF_NAME}}" | sed "s|^${REF_PREFIX_HEADS}||")"
	readonly BASE="$(echo "${GITHUB_BASE_REF:-}" | sed "s|^${REF_PREFIX_HEADS}||")"
	readonly REF_NAME="$(echo "${GITHUB_REF_NAME}" | sed "s|^${REF_PREFIX_HEADS}||")"

	log_info "Context: event=${EVENT} head=${HEAD} base=${BASE} ref=${REF_NAME}"
}

# ============================================================
# Event Type Checks
# ============================================================

is_pull_request() { [[ "${EVENT}" == "${EVENT_PULL_REQUEST}" ]]; }
is_push() { [[ "${EVENT}" == "${EVENT_PUSH}" ]]; }
is_dispatch() { [[ "${EVENT}" == "${EVENT_WORKFLOW_DISPATCH}" ]]; }

# ============================================================
# Git Operations
# ============================================================

fetch_branches() {
	local branch="$1"

	log_info "Fetching '${ORIGIN_BRANCH}' y '${branch}' (depth=${FETCH_DEPTH})..."

	git fetch --depth="${FETCH_DEPTH}" origin "${ORIGIN_BRANCH}" 2>/dev/null || {
		log_error "No se pudo hacer fetch de '${ORIGIN_BRANCH}'."
		exit ${EXIT_ERROR}
	}

	if [[ "${branch}" != "${ORIGIN_BRANCH}" ]]; then
		git fetch --depth="${FETCH_DEPTH}" origin "${branch}" 2>/dev/null || {
			log_error "No se pudo hacer fetch de '${branch}'."
			exit ${EXIT_ERROR}
		}
	fi
}

# ============================================================
# Divergence Check
# ============================================================

##
# Checks the divergence between a branch and the origin branch.
#
# Calculates how many commits the branch is ahead of or behind
# the origin branch. If the branch is behind by more than the
# maximum allowed (MAX_BEHIND), exits with an error.
#
# @param $1 branch - The branch name to check divergence for
# @param $2 context - A GHA event context string for logging (e.g., "workflow_dispatch", "pull_request")
#
# @exit EXIT_ERROR if branch is behind more than MAX_BEHIND commits
#
# @output Logs the ahead/behind counts and validation results
#
check_divergence() {
	local branch="$1"
	local context="$2"

	local behind
	behind="$(git rev-list --count "origin/${branch}..origin/${ORIGIN_BRANCH}")"

	local ahead
	ahead="$(git rev-list --count "origin/${ORIGIN_BRANCH}..origin/${branch}")"

	log_info "[${context}] '${branch}' vs '${ORIGIN_BRANCH}': ahead=${ahead}, behind=${behind}"

	if [[ "${behind}" -gt "${MAX_BEHIND}" ]]; then
		log_error "[${context}] '${branch}' está ${behind} commit(s) detrás de '${ORIGIN_BRANCH}' (máximo permitido: ${MAX_BEHIND})."
		log_error "La rama no está actualizada. Ejecuta: git rebase origin/${ORIGIN_BRANCH}"
		exit ${EXIT_ERROR}
	fi

	log_ok "[${context}] Rama al día con '${ORIGIN_BRANCH}'."
}

# ============================================================
# Conflict Detection
# ============================================================

##
# Detects merge conflicts between a branch and the origin branch.
#
# Performs a dry-run merge using git merge-tree to check for conflicts
# without modifying the working tree. If conflicts are detected, logs
# an error and exits the script with EXIT_ERROR status.
#
# @param $1 branch - The branch name to check for merge conflicts
# @param $2 context - A GHA event context string for logging (e.g., "workflow_dispatch", "pull_request")
#
# @exit 0 if no conflicts are detected
# @exit EXIT_ERROR if conflicts are found
#
# @output Logs merge conflict detection results and instructions
#
# @example
#   check_merge_conflicts "feature-branch" "PR → main"
#
check_merge_conflicts() {
	local branch="$1"
	local context="$2"

	log_info "[${context}] Verificando conflictos entre '${branch}' y '${ORIGIN_BRANCH}'..."

	# Merge trial en modo dry-run (no modifica working tree)
	if ! git merge-tree "$(git merge-base "origin/${ORIGIN_BRANCH}" "origin/${branch}")" \
		"origin/${ORIGIN_BRANCH}" "origin/${branch}" | grep -q '<<<<<<<'; then
		log_ok "[${context}] Sin conflictos detectados."
		return 0
	fi

	log_error "[${context}] Se detectaron conflictos entre '${branch}' y '${ORIGIN_BRANCH}'."
	log_error "Resuelve los conflictos localmente antes de continuar."
	exit ${EXIT_ERROR}
}

# ============================================================
# Branch Freshness Validation
# ============================================================

validate_branch_freshness() {
	local branch="$1"
	local context="$2"

	fetch_branches "${branch}"
	check_divergence "${branch}" "${context}"
	check_merge_conflicts "${branch}" "${context}"
}

# ============================================================
# Policy: decide qué rama validar según evento
# ============================================================

evaluate() {

	# ── PR hacia main: validar frescura de HEAD ──
	if is_pull_request; then
		if [[ "${BASE}" != "${ORIGIN_BRANCH}" ]]; then
			log_info "PR hacia '${BASE}' (no ${ORIGIN_BRANCH}). Validación no aplica."
			FRESHNESS_RESULT="skipped"
			return 0
		fi

		validate_branch_freshness "${HEAD}" "PR → ${ORIGIN_BRANCH}"
		FRESHNESS_RESULT="valid"
		return 0
	fi

	# ── Push a main: no requiere validación ──
	if is_push && [[ "${REF_NAME}" == "${ORIGIN_BRANCH}" ]]; then
		log_info "Push a '${ORIGIN_BRANCH}'. Validación no aplica."
		FRESHNESS_RESULT="skipped"
		return 0
	fi

	# ── workflow_dispatch: validar frescura de REF ──
	if is_dispatch; then
		validate_branch_freshness "${REF_NAME}" "workflow_dispatch"
		FRESHNESS_RESULT="valid"
		return 0
	fi

	log_info "Evento '${EVENT}' sin política de validación."
	FRESHNESS_RESULT="skipped"
	return 0
}

# ============================================================
# Outputs
# ============================================================

export_outputs() {
	local result="$1"

	{
		echo "branch_freshness_check=${result}"
	} >>"${GITHUB_OUTPUT}"
}

print_summary() {
	local result="$1"

	echo ""
	echo "════════════════════════════════════════"
	echo "  Branch Freshness Validation Summary"
	echo "════════════════════════════════════════"
	echo "  event             = ${EVENT}"
	echo "  head              = ${HEAD}"
	echo "  base              = ${BASE}"
	echo "  ref               = ${REF_NAME}"
	echo "  origin_branch     = ${ORIGIN_BRANCH}"
	echo "  max_behind        = ${MAX_BEHIND}"
	echo "  result            = ${result}"
	echo "════════════════════════════════════════"
}

# ============================================================
# Main
# ============================================================

main() {
	resolve_context

	FRESHNESS_RESULT="skipped"
	evaluate

	export_outputs "${FRESHNESS_RESULT}"
	print_summary "${FRESHNESS_RESULT}"
}

main
