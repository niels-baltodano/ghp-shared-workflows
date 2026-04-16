#!/usr/bin/env bash
# ============================================================
# Domain: Scan & Push — Trivy security gate and GHCR delivery
# ============================================================

# ── Scan ──────────────────────────────────────────────────────

# ------------------------------------------------------------
# @description  Runs a Trivy vulnerability scan against the locally
#               built image. Skips when security_allow_push is 'true'
#               and writes trivy_scan_result=skipped to outputs.
#               On failure writes trivy_scan_result=failed and exits 1.
#               On success writes trivy_scan_result=passed.
#
#               The step in action.yml uses continue-on-error: true so
#               the push step reads the trivy_scan_result output to decide
#               whether to proceed — the exit code alone is not sufficient.
#
# @param $1     ctx_name - Name of the BP context associative array.
# @exitcode     1 if vulnerabilities above the severity threshold are found.
# @example
#   # Normal scan (security_allow_push=false, no vulnerabilities):
#   cmd_scan "BP_CTX"
#   # Runs: trivy image --severity CRITICAL,HIGH --exit-code 1 --format table \
#   #         --no-progress --ignore-unfixed ghcr.io/owner/my-repo:abc1234
#   # Writes to GITHUB_OUTPUT: trivy_scan_result=passed
#
#   # Vulnerabilities found above threshold:
#   cmd_scan "BP_CTX"
#   # Writes to GITHUB_OUTPUT: trivy_scan_result=failed
#   # exit 1
#
#   # Scan bypassed (security_allow_push=true):
#   cmd_scan "BP_CTX"
#   # Writes to GITHUB_OUTPUT: trivy_scan_result=skipped
#   # No trivy invocation
# ------------------------------------------------------------
cmd_scan() {
	local ctx_name="$1"
	local -n _scan="${ctx_name}"

	local image_name="${_scan[${BP_F_IMAGE_NAME}]}"
	local output_file="${_scan[${BP_F_OUTPUT_FILE}]}"

	if [[ -z "${image_name}" ]]; then
		log_error "BP_F_IMAGE_NAME is required for scan. Was cmd_build run first?"
		exit 1
	fi

	if ! command -v trivy &>/dev/null; then
		log_error "Trivy not found in PATH."
		exit 1
	fi

	if [[ "${_scan[${BP_F_SECURITY_ALLOW_PUSH}]}" == "true" ]]; then
		log_info "security_allow_push=true. Skipping Trivy scan."
		echo "trivy_scan_result=skipped" >>"${output_file}"
		return 0
	fi

	local severity="${_scan[${BP_F_TRIVY_SEVERITY}]}"
	log_info "Scanning image (severity=${severity})..."

	local trivy_args=(
		image
		--severity "${severity}"
		--exit-code "${_scan[${BP_F_TRIVY_EXIT_CODE}]}"
		--format table
		--no-progress
	)
	[[ "${_scan[${BP_F_TRIVY_IGNORE_UNFIXED}]}" == "true" ]] && trivy_args+=(--ignore-unfixed)

	if ! trivy "${trivy_args[@]}" "${image_name}"; then
		log_error "Vulnerabilities found above threshold (${severity})."
		echo "trivy_scan_result=failed" >>"${output_file}"
		exit 1
	fi

	log_ok "Scan passed. No vulnerabilities above threshold."
	echo "trivy_scan_result=passed" >>"${output_file}"
}

# ── Push helpers (pure: params only) ─────────────────────────

# ------------------------------------------------------------
# @description  Resolves the digest of a pushed image by trying
#               docker inspect first (works when the daemon has the
#               image), then falling back to docker buildx imagetools
#               inspect (works for remote-only references).
# @param $1     image_name - Full image reference including tag.
# @stdout       The sha256:... digest string, or empty on failure.
# @example
#   push_resolve_digest "ghcr.io/owner/my-repo:abc1234"
#   # Output: "sha256:a1b2c3d4e5f6..."
#
#   # Strategy 1 — docker inspect (image still in local daemon after --load):
#   #   docker inspect --format='{{index .RepoDigests 0}}' ghcr.io/owner/my-repo:abc1234
#   #   → strips everything before '@' to extract digest
#
#   # Strategy 2 — fallback if inspect returns empty (image evicted from daemon):
#   #   docker buildx imagetools inspect ghcr.io/owner/my-repo:abc1234
#   #   → parses 'Digest: sha256:...' line from output
# ------------------------------------------------------------
push_resolve_digest() {
	local image_name="$1"

	local digest=""
	digest="$(docker inspect \
		--format='{{index .RepoDigests 0}}' \
		"${image_name}" 2>/dev/null |
		sed 's/.*@//')" || true

	if [[ -z "${digest}" ]]; then
		digest="$(docker buildx imagetools inspect "${image_name}" |
			awk '/^Digest:/{print $2; exit}')" || true
	fi

	echo "${digest}"
}

# ── Push orchestrator ─────────────────────────────────────────

# ------------------------------------------------------------
# @description  Pushes the built image to GHCR, resolves its digest,
#               writes the digest to GitHub Actions outputs, and prunes
#               dangling images. Exits if the digest cannot be resolved
#               after exhausting both inspection strategies.
# @param $1     ctx_name - Name of the BP context associative array.
# @exitcode     1 if the image digest cannot be resolved after push.
# @example
#   declare -A BP_CTX  # ... image_name set by cmd_build
#   cmd_push "BP_CTX"
#   # Step 1: docker push ghcr.io/owner/my-repo:abc1234
#   # Step 2: push_resolve_digest → digest="sha256:a1b2c3..."
#   # Step 3: ctx_resolve_repository_name → full digest ref
#   # BP_CTX[image_digest]="ghcr.io/owner/my-repo@sha256:a1b2c3..."
#   # Writes to GITHUB_OUTPUT:
#   #   container_image_digest_ghcr=ghcr.io/owner/my-repo@sha256:a1b2c3...
#   # Step 4: docker image prune -f  (clean up dangling layers)
#
#   # Digest cannot be resolved after push — exits 1:
#   # ❌ Failed to resolve image digest after push.
# ------------------------------------------------------------
cmd_push() {
	local ctx_name="$1"
	local -n _push="${ctx_name}"

	local image_name="${_push[${BP_F_IMAGE_NAME}]}"

	if [[ -z "${image_name}" ]]; then
		log_error "BP_F_IMAGE_NAME is required for push. Was cmd_build run first?"
		exit 1
	fi

	log_info "Pushing image: ${image_name}"
	docker push "${image_name}"

	local digest
	digest="$(push_resolve_digest "${image_name}")"

	if [[ -z "${digest}" ]]; then
		log_error "Failed to resolve image digest after push."
		exit 1
	fi

	local repo_name
	repo_name="$(ctx_resolve_repository_name \
		"${_push[${BP_F_REPOSITORY}]}" \
		"${_push[${BP_F_IS_SINGLE_BRANCH}]}" \
		"${_push[${BP_F_REF_NAME}]}")"

	local image_digest="${_push[${BP_F_REGISTRY}]}/${repo_name}@${digest}"
	log_ok "Image pushed. Digest: ${image_digest}"

	_push[${BP_F_IMAGE_DIGEST}]="${image_digest}"
	output_write_push "${ctx_name}"

	log_info "Pruning dangling images..."
	docker image prune -f >/dev/null 2>&1 || true
}
