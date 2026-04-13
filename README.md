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
  actions/
    resolve-ci-context/
    build-and-push-container-image/
  scripts/
    shell/
      resolve-ci-context/
      container/
docs/
  workflows.md
  actions.md
```

## Main flows

### CI/CD dispatcher

`ci-cd.yml` is the entrypoint. It resolves CI context and dispatches container publishing when the branch/event policy allows it.

### Container build and push

`container-build-push.yml` builds, scans, and pushes a container image to GHCR.

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

```yaml
jobs:
  container-build-push:
    uses: OWNER/ghp-shared-workflows/.github/workflows/container-build-push.yml@v1
    with:
      release_version: 1.2.3
      security_allow_push_to_ghcr: "false"
      is_single_branch_deployment: "false"
      environment: dev
    secrets: inherit
```

## Reference docs

- `docs/workflows.md`
- `docs/actions.md`

## Conventions

- `target_action` currently supports `container` and `flutter`
- branch policy is enforced in `resolve-ci-context.sh`
- container publishing is GHCR-based
- Trivy scanning is part of the container flow

## Known caveats

These are current implementation mismatches worth fixing later:

- `container-build-push.yml` declares `project_language`, but the action currently reads `projectlanguage`
- `container-build-push.yml` declares `is_single_branch_deployment`, but it is not forwarded to the action
- `ci-cd.yml` exposes `client_repo_sha` as a workflow output, but the job does not currently surface it cleanly
- `build-and-push-container-image/action.yml` does not define top-level `outputs`

## If you are extending this repo

Document the consumer contract first, then change the implementation.
That keeps downstream repos from breaking silently.
