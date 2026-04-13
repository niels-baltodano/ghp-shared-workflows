# Actions Reference

## `resolve-ci-context`

Composite action that decides whether the pipeline should run and which path to take.

**Input**

- `target_action` optional string, defaults to `container`

**Outputs**

- `should_run`
- `is_pr`
- `is_push`
- `is_dispatch`
- `is_hotfix`
- `is_container`
- `release_version`
- `release_version_number`
- `build_number`
- `is_flutter`
- `active_branch`

**Purpose**

- Normalize event and branch metadata.
- Gate execution by branch policy.
- Detect whether the repo is container-based or Flutter-based.

## `build-and-push-container-image`

Composite action that builds, scans, and pushes the container image.

**Inputs**

- `github_token` required
- `trivy_severity` optional string, default `CRITICAL,HIGH`
- `trivy_ignore_unfixed` optional string, default `true`
- `trivy_exit_code` optional string, default `1`
- `projectlanguage` optional string, default `N/A`
- `security_allow_push_to_ghcr` optional string, default `false`
- `is_single_branch_deployment` optional string, default `false`

**Behavior**

1. Set up Docker Buildx.
2. Log in to GHCR.
3. Install Trivy when needed.
4. Build the image.
5. Scan the image.
6. Push the image when policy allows it.

**Outputs**

- The action currently depends on shell-script outputs for:
  - `container_image_name_ghcr`
  - `container_image_digest_ghcr`
  - `client_repo_sha`

## Shell scripts

### `resolve-ci-context.sh`

- Requires `GITHUB_EVENT_NAME`, `GITHUB_REF_NAME`, and `GITHUB_OUTPUT`
- Uses `GITHUB_HEAD_REF`, `GITHUB_BASE_REF`, `GITHUB_WORKSPACE`, and optional `INPUT_TARGET_ACTION`
- Supports `container` and `flutter`

### `build-and-push.sh`

- Commands: `build`, `scan`, `push`
- Depends on Docker, GHCR auth, and Trivy for scanning

## Contract warnings

- `project_language` vs `projectlanguage` is inconsistent today
- `is_single_branch_deployment` is not fully wired through today
- top-level action outputs are not declared, so workflow chaining is fragile
