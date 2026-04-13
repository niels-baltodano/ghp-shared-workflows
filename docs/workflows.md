# Workflows Reference

## `ci-cd.yml`

Reusable dispatcher workflow.

**Trigger**

- `workflow_call`

**Input**

- `target_action` required string

**Outputs**

- `container_image_name_ghcr`
- `container_image_digest_ghcr`
- `client_repo_sha`

**Flow**

1. Checkout the caller repo.
2. Checkout this shared repo into `.ci-toolkit`.
3. Run `resolve-ci-context`.
4. If the policy allows it and the target is container dispatch, call `container-build-push.yml`.

**Notes**

- The workflow relies on default `GITHUB_TOKEN` permissions.
- `secrets: inherit` is passed to the container workflow.

## `container-build-push.yml`

Reusable workflow for building, scanning, and pushing a container image.

**Trigger**

- `workflow_call`

**Inputs**

- `release_version` required string
- `project_language` optional string
- `security_allow_push_to_ghcr` optional string, default `false`
- `is_single_branch_deployment` optional string, default `false`
- `environment` optional string, default `dev`

**Outputs**

- `container_image_name_ghcr`
- `container_image_digest_ghcr`
- `client_repo_sha`

**Flow**

1. Checkout the caller repo.
2. Checkout this shared repo into `.ci-toolkit`.
3. Run the `build-and-push-container-image` composite action.

**Notes**

- The workflow currently does not declare explicit `permissions`.
- Inputs must match the action contract exactly or they will be dropped.

## Consumer guidance

- Use `secrets: inherit` only when the caller repo trusts the shared workflow fully.
- Prefer a pinned release tag over a branch ref.
- Keep branch naming policy aligned with `resolve-ci-context.sh`.
