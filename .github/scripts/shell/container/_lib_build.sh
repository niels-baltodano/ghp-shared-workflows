#!/usr/bin/env bash
# ============================================================
# Domain: Build — pre-flight validation, OCI label generation,
#         docker buildx execution, and cmd_build orchestration
# ============================================================

# ── Pre-flight validation (pure: params only) ────────────────

# ------------------------------------------------------------
# @description  Checks that a Dockerfile exists at the expected path.
# @param $1     dockerfile_path - Absolute path to the Dockerfile.
# @return       0 if present, 1 otherwise.
# @example
#   build_validate_dockerfile "/workspace/Dockerfile"
#   # return 0  (file exists — continues)
#
#   build_validate_dockerfile "/workspace/Dockerfile"
#   # return 1  — ❌ Dockerfile not found at '/workspace/Dockerfile'
# ------------------------------------------------------------
build_validate_dockerfile() {
	local dockerfile_path="$1"
	[[ -f "${dockerfile_path}" ]] && return 0
	log_error "Dockerfile not found at '${dockerfile_path}'"
	return 1
}

# ------------------------------------------------------------
# @description  Checks that the Docker daemon is reachable.
# @return       0 if docker info succeeds, 1 otherwise.
# @example
#   build_validate_docker_daemon
#   # return 0  (daemon running — continues)
#
#   build_validate_docker_daemon
#   # return 1  — ❌ Docker daemon is not available.
# ------------------------------------------------------------
build_validate_docker_daemon() {
	docker info &>/dev/null && return 0
	log_error "Docker daemon is not available."
	return 1
}

# ── OCI label generation ──────────────────────────────────────

# ------------------------------------------------------------
# @description  Populates a --label array with standard OCI image
#               annotations that associate the image with its source
#               repository and build run in GitHub.
# @param $1     ctx_name   - Name of the BP context associative array.
# @param $2     labels_ref - Nameref: indexed array to append --label entries.
# @example
#   declare -A BP_CTX  # ... populated by ctx_build
#   local labels=()
#   build_oci_labels "BP_CTX" labels
#   # labels=(
#   #   --label "org.opencontainers.image.source=https://github.com/owner/repo"
#   #   --label "org.opencontainers.image.revision=abc1234def..."
#   #   --label "org.opencontainers.image.created=2026-04-16T10:00:00Z"
#   #   --label "org.opencontainers.image.description=Built from owner/repo"
#   #   --label "org.opencontainers.image.branch=release/v1.2.3"
#   #   --label "org.opencontainers.image.authors=github-actor"
#   #   --label "org.opencontainers.image.github.action.url=https://github.com/owner/repo/actions/runs/12345678"
#   # )
# ------------------------------------------------------------
build_oci_labels() {
	local ctx_name="$1"
	local -n _bol_ctx="${ctx_name}"
	local -n _bol_labels="$2"

	local created_at
	created_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
	local repo="${_bol_ctx[${BP_F_REPOSITORY}]}"
	local run_url="https://github.com/${repo}/actions/runs/${_bol_ctx[${BP_F_RUN_ID}]}"

	_bol_labels+=(
		--label "org.opencontainers.image.source=https://github.com/${repo}"
		--label "org.opencontainers.image.revision=${_bol_ctx[${BP_F_SHA}]}"
		--label "org.opencontainers.image.created=${created_at}"
		--label "org.opencontainers.image.description=Built from ${repo}"
		--label "org.opencontainers.image.branch=${_bol_ctx[${BP_F_REF_NAME}]}"
		--label "org.opencontainers.image.authors=${_bol_ctx[${BP_F_ACTOR}]}"
		--label "org.opencontainers.image.github.action.url=${run_url}"
	)

	log_info "OCI labels configured for: https://github.com/${repo}"
}

# ── Docker build (pure) ───────────────────────────────────────

# ------------------------------------------------------------
# @description  Runs docker buildx build with --load so the image is
#               available locally for scanning before pushing.
# @param $1     image_name - Full image reference including tag.
# @param $2     platform   - Target platform (e.g. 'linux/amd64').
# @param $3     context    - Build context path (GITHUB_WORKSPACE).
# @param $@     extra_args - --build-arg and --label flag arrays.
# @example
#   local extra=(--build-arg "API_KEY=secret" --label "env=dev")
#   build_run_docker "ghcr.io/owner/my-repo:abc1234" "linux/amd64" "/workspace" "${extra[@]}"
#   # Runs:
#   #   docker buildx build \
#   #     --platform linux/amd64 \
#   #     --provenance=false \
#   #     --load \
#   #     -t ghcr.io/owner/my-repo:abc1234 \
#   #     --build-arg API_KEY=secret \
#   #     --label env=dev \
#   #     /workspace
#
#   # Without extra args:
#   build_run_docker "ghcr.io/owner/my-repo:abc1234" "linux/amd64" "/workspace"
# ------------------------------------------------------------
build_run_docker() {
	local image_name="$1"
	local platform="$2"
	local context="$3"
	shift 3
	local extra_args=("$@")

	log_info "Building image: ${image_name}"
	docker buildx build \
		--platform "${platform}" \
		--provenance=false \
		--load \
		-t "${image_name}" \
		"${extra_args[@]+"${extra_args[@]}"}" \
		"${context}"
}

# ── Orchestrator ──────────────────────────────────────────────

# ------------------------------------------------------------
# @description  Resolves the image name, validates pre-conditions,
#               loads .env build args via env_build_args, generates OCI
#               labels, runs docker buildx, and writes GITHUB_OUTPUT.
#               Sets BP_F_IMAGE_NAME in the context for downstream steps.
# @param $1     ctx_name - Name of the BP context associative array.
# @exitcode     1 on missing Dockerfile, unavailable Docker daemon,
#               or docker build failure.
# @example
#   declare -A BP_CTX  # ... populated by ctx_build
#   cmd_build "BP_CTX"
#   # Step 1: build_validate_dockerfile "/workspace/Dockerfile"
#   # Step 2: build_validate_docker_daemon
#   # Step 3: ctx_resolve_repository_name → ctx_resolve_image_name
#   # Step 4: env_build_args "/workspace/.env" build_args
#   # Step 5: build_oci_labels "BP_CTX" label_args
#   # Step 6: build_run_docker "ghcr.io/owner/my-repo:abc1234" ...
#   # BP_CTX[image_name]="ghcr.io/owner/my-repo:abc1234"
#   # Writes to GITHUB_OUTPUT:
#   #   container_image_name_ghcr=ghcr.io/owner/my-repo:abc1234
#   #   client_repo_sha=abc1234def...
# ------------------------------------------------------------
cmd_build() {
	local ctx_name="$1"
	local -n _cmd_b="${ctx_name}"

	local workspace="${_cmd_b[${BP_F_WORKSPACE}]}"

	build_validate_dockerfile "${workspace}/Dockerfile" || exit 1
	build_validate_docker_daemon || exit 1

	local repo_name
	repo_name="$(ctx_resolve_repository_name \
		"${_cmd_b[${BP_F_REPOSITORY}]}" \
		"${_cmd_b[${BP_F_IS_SINGLE_BRANCH}]}" \
		"${_cmd_b[${BP_F_REF_NAME}]}")"

	local image_name
	image_name="$(ctx_resolve_image_name \
		"${_cmd_b[${BP_F_REGISTRY}]}" \
		"${repo_name}" \
		"${_cmd_b[${BP_F_SHA}]:0:7}")"

	local build_args=() label_args=()
	env_build_args "${workspace}/.env" build_args
	build_oci_labels "${ctx_name}" label_args

	build_run_docker \
		"${image_name}" \
		"${_cmd_b[${BP_F_PLATFORM}]}" \
		"${workspace}" \
		"${build_args[@]+"${build_args[@]}"}" \
		"${label_args[@]}"

	log_ok "Image built: ${image_name}"

	_cmd_b[${BP_F_IMAGE_NAME}]="${image_name}"
	output_write_build "${ctx_name}"
}
