# Workflows Reference

## `ci-cd.yml`

Reusable dispatcher workflow. Entry point for all downstream consumers.

**Trigger**

- `workflow_call`

**Input**

- `target_action` required string — currently supports `container` and `flutter`

**Outputs**

- `container_image_name_ghcr`
- `container_image_digest_ghcr`
- `client_repo_sha` ⚠️ — declared but the `resolve-ci-context` job does not surface this output; always resolves empty

**Flow**

1. Checkout the caller repo (full history).
2. Checkout this shared repo into `.ci-toolkit`.
3. Run `resolve-ci-context` action → produces `should_run`, `is_pr`, `is_push`, `is_dispatch`, `is_container`, `release_version`, etc.
4. Run `gitops-merge-validator` when `should_run == true` and event is PR or dispatch.
5. Dispatch to one of the following based on flags:

| Condition | Dispatches to |
|---|---|
| `should_run && is_container && is_dispatch` | `container-build-push.yml` |
| `should_run && is_container && is_pr` | `container-pr-verifications.yml` |
| `should_run && is_container && is_push` | `container-create-tag-and-release.yml` |

**Notes**

- `secrets: inherit` is passed to all dispatched workflows.
- Runs on `ubuntu-slim`.

---

## `container-build-push.yml`

Builds, scans, and pushes a container image to GHCR. Triggered by `workflow_dispatch` events via `ci-cd.yml`.

**Trigger**

- `workflow_call`

**Inputs**

- `release_version` required string
- `project_language` optional string
- `security_allow_push_to_ghcr` optional string, default `false`
- `is_single_branch_deployment` optional string, default `false` ⚠️ — declared but not forwarded to the action
- `environment` optional string, default `dev`

**Outputs**

- `container_image_name_ghcr`
- `container_image_digest_ghcr`
- `client_repo_sha`

**Flow**

1. Checkout the caller repo.
2. Checkout this shared repo into `.ci-toolkit`.
3. Run `build-and-push-container-image` composite action.

**Notes**

- Runs on `ubuntu-latest`.
- No explicit `permissions` block — inherits defaults from the calling workflow.

---

## `container-pr-verifications.yml`

Runs pre-merge validation checks on PRs targeting `main` for container projects.

**Trigger**

- `workflow_call`

**Input**

- `release_version` required string

**Flow**

1. Checkout the caller repo (full history).
2. Checkout this shared repo into `.ci-toolkit`.
3. Run `gitops-tag-and-release-validator` — validates that the tag does not already exist and the version follows semver.

**Notes**

- Runs on `ubuntu-slim`.
- Exits non-zero if the tag or release already exists, or if the version is not valid semver.

---

## `container-create-tag-and-release.yml`

Creates the git tag and GitHub release after a merge to `main`. Triggered by push events via `ci-cd.yml`.

**Trigger**

- `workflow_call`

**Input**

- `release_version` required string

**Flow**

1. Checkout the caller repo (full history).
2. Checkout this shared repo into `.ci-toolkit`.
3. Run `gitops-tag-and-release-creator` — creates the tag and release with a commit-range changelog.

**Notes**

- Runs on `ubuntu-slim`.
- Requires the `gh` CLI and a token with write access to tags and releases.

---

## Consumer guidance

- Use `secrets: inherit` only when the caller repo trusts the shared workflow fully.
- Prefer a pinned release tag over a branch ref when calling these workflows.
- Keep branch naming policy aligned with `resolve-ci-context.sh`:
  - Container: `(release|hotfix|bugfix)/vX.Y.Z`
  - Flutter: `(release|hotfix|bugfix)/vX.Y.Z+BUILD`
- The typical integration is to call `ci-cd.yml` only — it dispatches all sub-workflows automatically.
