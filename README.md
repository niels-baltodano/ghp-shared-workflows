# GHP Shared Workflows

Reusable GitHub workflows and composite actions for pipelines, CI/CD, and container delivery.

This repo is the shared toolkit used by downstream repositories through `workflow_call` and composite actions under `.github/actions`.

## What is here

- Reusable workflows in `.github/workflows`
- Composite actions in `.github/actions`
- Shell implementations in `.github/scripts/shell`

## Repository layout

```text
.github/
  workflows/
    ci-cd.yml
    container-build-push.yml
    container-pr-verifications.yml
    container-create-tag-and-release.yml
  actions/
    resolve-ci-context/
    build-and-push-container-image/
    gitops-merge-validator/
    gitops-tag-and-release-validator/
    gitops-tag-and-release-creator/
  scripts/
    shell/
      resolve-ci-context/
      container/
      gitops/
        merge-validator/
        tag-release-creator/
        tag-release-validator/
docs/
  workflows.md
  actions.md
```

## Main flows

### CI/CD dispatcher

`ci-cd.yml` is the entrypoint. It resolves CI context and dispatches to the appropriate sub-workflow based on event type:

| Event | Dispatches to |
|---|---|
| `workflow_dispatch` from release branch | `container-build-push.yml` |
| `pull_request` → main | `container-pr-verifications.yml` |
| `push` to main | `container-create-tag-and-release.yml` |

### Container build and push

`container-build-push.yml` builds, scans, and pushes a container image to GHCR. Runs on `workflow_dispatch`.

### Container PR verifications

`container-pr-verifications.yml` validates that the release tag does not already exist before a PR is merged to `main`.

### Container tag and release creation

`container-create-tag-and-release.yml` creates the git tag and GitHub release after the merge commit lands on `main`.

## Quick usage

Replace `OWNER/REPO` and version tags with your real values.

```yaml
jobs:
  ci-cd:
    uses: OWNER/ghp-shared-workflows/.github/workflows/ci-cd.yml@v1
    with:
      target_action: container
    secrets: inherit
```

If you need to call the build workflow directly:

```yaml
jobs:
  container-build-push:
    uses: OWNER/ghp-shared-workflows/.github/workflows/container-build-push.yml@v1
    with:
      release_version: 1.2.3
      security_allow_push_to_ghcr: "false"
      environment: dev
    secrets: inherit
```

## Reference docs

- `docs/workflows.md`
- `docs/actions.md`

## Conventions

- `target_action` currently supports `container` and `flutter`
- Branch policy is enforced in `resolve-ci-context.sh`
  - Container: `(release|hotfix|bugfix)/vX.Y.Z`
  - Flutter: `(release|hotfix|bugfix)/vX.Y.Z+BUILD`
- Container publishing is GHCR-based
- Trivy scanning is part of the container flow; push is blocked unless scan passes or `security_allow_push_to_ghcr=true`
- Project type is auto-detected: `Dockerfile` → container, `pubspec.yaml` → Flutter

## Known caveats

These are current implementation mismatches worth fixing later:

- `container-build-push.yml` declares `is_single_branch_deployment`, but it is not forwarded to the action
- `ci-cd.yml` exposes `client_repo_sha` as a workflow output, but the `resolve-ci-context` job does not surface it as a job output, so it always resolves empty

## If you are extending this repo

Document the consumer contract first, then change the implementation.
That keeps downstream repos from breaking silently.
