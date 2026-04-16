# Workflows Reference

## `ci-cd.yml`

Reusable dispatcher workflow. Entry point for all downstream consumers. Every job is a `uses:` call — no inline steps.

**Trigger**

- `workflow_call`

**Input**

- `target_action` required string — high-level pipeline intent. Valid values: `container` | `flutter`

**Outputs**

- `container_image_name_ghcr`
- `container_image_digest_ghcr`
- `client_repo_sha`

**Flow**

1. Call `resolve-ci-context.yml` (always runs — produces event/branch flags).
2. Dispatch to one of the following based on flags from step 1:

| Condition | Dispatches to |
|---|---|
| `should_run && is_container && is_dispatch` | `container-build-push.yml` |
| `should_run && is_container && is_pr` | `container-pr-verifications.yml` |
| `should_run && is_container && is_push` | `container-create-tag-and-release.yml` |

**Notes**

- `secrets: inherit` is passed to all dispatched workflows.
- No `permissions` block — inherits permissions declared by the caller.
- `client_repo_sha` is sourced from `container-build-and-push` outputs.

---

## `resolve-ci-context.yml`

Reusable workflow that inspects the GitHub event and branch, validates branch policy, detects project type, resolves the release version, and runs the merge validator when appropriate. Called unconditionally as the first job in `ci-cd.yml`.

**Trigger**

- `workflow_call`

**Input**

- `target_action` required string — passed through to the `resolve-ci-context` composite action

**Outputs**

- `should_run` — master gate; `false` short-circuits all downstream jobs
- `is_pr` — true for `pull_request` events
- `is_push` — true for `push` events to `main`
- `is_dispatch` — true for `workflow_dispatch` events
- `is_container` — true when a `Dockerfile` is detected at repo root
- `is_hotfix` — true when the active branch has a `hotfix/` prefix
- `release_version` — full version string inferred from the branch (e.g. `v1.2.3`)
- `release_version_number` — numeric part only (e.g. `1.2.3`)
- `branch_freshness_check` — result of the merge-validator (`passed` / `skipped`)

**Flow**

1. Checkout the caller repo (full history, `fetch-depth: 0`).
2. Checkout this shared repo into `.ci-toolkit` (`fetch-depth: 1`).
3. Run `resolve-ci-context` composite action → produces all event/branch/version flags.
4. Run `gitops-merge-validator` when `should_run == true` and event is `is_pr` or `is_dispatch`.
   - Push is excluded: code reaching `main` has already passed the PR freshness check.

**Notes**

- Runs on `ubuntu-slim`.
- No `permissions` block — inherits from the caller.

---

## `container-build-push.yml`

Builds, scans, and pushes a container image to GHCR. Triggered by `workflow_dispatch` events via `ci-cd.yml`.

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
2. Checkout this shared repo into `.ci-toolkit` (`fetch-depth: 1`).
3. Run `build-and-push-container-image` composite action.

**Notes**

- Runs on `ubuntu-latest`.
- No explicit `permissions` block — inherits from the calling workflow.

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
- Declare `permissions` (`contents: write`, `packages: write`, `pull-requests: read`) in the caller workflow; reusable workflows inherit them via `secrets: inherit`.
