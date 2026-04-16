# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Shared GitHub Actions toolkit consumed by downstream repos via `workflow_call` and composite actions. No build system — all code is YAML and bash.

## Linting / validation

```bash
# Validate shell scripts locally
shellcheck .github/scripts/shell/**/*.sh

# Validate YAML syntax
yamllint .github/workflows/ .github/actions/
```

There are no automated tests. Manual testing requires triggering the workflow from a consumer repo.

## Architecture

Three layers work together:

```
.github/workflows/        ← reusable workflows (called by downstream repos)
.github/actions/          ← composite actions (called by workflows)
.github/scripts/shell/    ← bash implementations (called by actions)
```

**Call chain for the main path:**

```
ci-cd.yml
  → resolve-ci-context (composite action)
      → resolve-ci-context.sh
  → container-build-push.yml (conditional dispatch)
      → build-and-push-container-image (composite action)
          → build-and-push.sh {build|scan|push}
```

**Toolkit bootstrap pattern:** Workflows checkout this repo into `.ci-toolkit/` at runtime so actions can reference scripts via `SCRIPTS_PATH=".ci-toolkit/.github/scripts"`. Both `ci-cd.yml` and `container-build-push.yml` do this checkout step.

## Branch policy (resolve-ci-context.sh)

`should_run=true` only when:
- PR targeting `main` from a valid release branch
- Push to `main`
- `workflow_dispatch` from a valid release branch

Valid branch format:
- Container: `(release|hotfix|bugfix)/vX.Y.Z`
- Flutter: `(release|hotfix|bugfix)/vX.Y.Z+BUILD`

Project type is auto-detected by file presence: `Dockerfile` → container, `pubspec.yaml` → Flutter.

## Known mismatches (do not silently paper over)

None currently known.

## Extension rule

Document the consumer contract (workflow inputs/outputs) before changing implementation. Downstream repos break silently if inputs are renamed without notice.

## Security gate

Push to GHCR is blocked unless Trivy scan passes (`trivy_scan_result=passed`) or `security_allow_push_to_ghcr=true` is explicitly set. Scan runs with `continue-on-error: true` and the push step reads `steps.scan.outputs.trivy_scan_result`.
