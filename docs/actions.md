# Actions Reference

## `run-script`

Generic script runner used by all domain composite actions. Eliminates the shared boilerplate (SCRIPTS_PATH setup, `chmod +x`, env-var wiring) that was previously duplicated across every action.

**Inputs**

- `script` required string — path relative to `.github/scripts/shell/` (e.g. `container/build-and-push.sh`)
- `args` optional string — space-separated positional arguments passed to the script (e.g. `build`, `scan`, `push`)
- `env_vars` optional multiline string — `KEY=VALUE` lines exported into the process environment before the script runs

**Behavior**

1. Exports each line from `env_vars` as a process environment variable (expansion is safe — values are read from an env var, not interpolated into the shell body).
2. Resolves the full script path under `.ci-toolkit/.github/scripts/shell/`.
3. Makes the script executable and runs it, forwarding any positional `args`.

**Outputs**

Declares the union of all script outputs across every domain so callers can reference them via `steps.<id>.outputs.<name>`:

| Domain | Output keys |
|---|---|
| resolve-ci-context | `should_run`, `is_pr`, `is_push`, `is_dispatch`, `is_hotfix`, `is_container`, `is_flutter`, `release_version`, `release_version_number`, `build_number`, `active_branch` |
| merge-validator | `branch_freshness_check` |
| tag-release-validator | `validation_result`, `tag_exists`, `release_exists` |
| tag-release-creator | `tag_created`, `release_created`, `release_url` |
| build-and-push | `container_image_name_ghcr`, `client_repo_sha`, `container_image_digest_ghcr`, `trivy_scan_result` |

---

## `resolve-ci-context`

Composite action that decides whether the pipeline should run and which path to take.

**Inputs**

- `target_action` optional string, defaults to `container`
- `github_token` required string

**Outputs**

- `should_run`
- `is_pr`
- `is_push`
- `is_dispatch`
- `is_hotfix`
- `is_container`
- `is_flutter`
- `release_version`
- `release_version_number`
- `build_number`
- `active_branch`

**Purpose**

- Normalize event and branch metadata.
- Gate execution by branch policy.
- Detect whether the repo is container-based or Flutter-based.

---

## `build-and-push-container-image`

Composite action that builds, scans, and pushes the container image.

**Inputs**

- `github_token` required string
- `trivy_severity` optional string, default `CRITICAL,HIGH`
- `trivy_ignore_unfixed` optional string, default `true`
- `trivy_exit_code` optional string, default `1`
- `project_language` optional string, default `N/A`
- `security_allow_push_to_ghcr` optional string, default `false`
- `is_single_branch_deployment` optional string, default `false`

**Behavior**

1. Set up Docker Buildx.
2. Log in to GHCR.
3. Install Trivy — delegates to `run-script` with `script: tools/trivy.sh`.
4. Build the image — delegates to `run-script` with `script: container/build-and-push.sh`, `args: build`.
5. Scan the image — delegates to `run-script` with `args: scan`. Runs with `continue-on-error: true`.
6. Push the image — delegates to `run-script` with `args: push`. Runs only when `trivy_scan_result == 'passed'` or `== 'skipped'`, or `security_allow_push_to_ghcr == 'true'`.

**Outputs**

- `container_image_name_ghcr` — image name with short SHA tag
- `container_image_digest_ghcr` — full digest after push
- `client_repo_sha` — commit SHA that triggered the build

---

## `gitops-merge-validator`

Composite action that validates a PR's release branch is up to date with `main` before allowing a merge.

**Inputs**

- `github_token` required string

**Outputs**

- `branch_freshness_check` — `valid`, `skipped`, or exits with error

**Behavior**

- On PR → main: fetches both branches, checks divergence (`MAX_BEHIND`, default 0), detects merge conflicts via `git merge-tree` dry-run.
- On push to main or unknown event: skips (result = `skipped`).
- On `workflow_dispatch`: validates the dispatched branch.

---

## `gitops-tag-and-release-validator`

Composite action that validates a tag follows semver and that neither the tag nor a release with that name already exist in the repository.

**Inputs**

- `release_version` optional string — must match `v?MAJOR.MINOR.PATCH[-pre][+build]`

**Outputs**

- `validation_result` — `passed` or `failed`
- `tag_exists` — `true` or `false`
- `release_exists` — `true` or `false`

**Behavior**

- Semver format is a hard precondition (exits on failure).
- Tag and release checks both run independently so the caller always gets both states.
- Exits non-zero when `validation_result == failed`.

---

## `gitops-tag-and-release-creator`

Composite action that creates a git tag and a GitHub release for the given version.

**Inputs**

- `release_version` optional string
- `github_token` optional string
- `environment` optional string, default `dev`

**Behavior**

1. Validates the tag does not already exist.
2. Creates the tag at `GITHUB_SHA`.
3. Looks up the previous tag to build a commit-range changelog.
4. Creates a GitHub release with an auto-generated body listing commits since the previous tag.

**Outputs** (written to `GITHUB_OUTPUT`)

- `tag_created` — `true`
- `release_created` — `true`
- `release_url` — URL of the created release

---

## Shell scripts

### `tools/trivy.sh`

Idempotent Trivy installer with a safety-first version selection strategy.

- Skips installation if Trivy is already in PATH.
- Queries the GitHub Releases API for the latest version.
- Checks each candidate against the OSV.dev advisory database; skips versions with known vulnerabilities.
- Falls back to `TRIVY_FALLBACK_VERSION` (`v0.69.3`) when the API is unreachable or no safe release is found within `TRIVY_MAX_LOOKBACK` (5) releases.
- Downloads the tarball, verifies its SHA-256 checksum against the official checksums file, then installs to `/usr/local/bin`.

### `resolve-ci-context.sh`

- Requires `GITHUB_EVENT_NAME`, `GITHUB_REF_NAME`, and `GITHUB_OUTPUT`
- Uses `GITHUB_HEAD_REF`, `GITHUB_BASE_REF`, `GITHUB_WORKSPACE`, optional `INPUT_TARGET_ACTION`
- Supports `container` and `flutter`
- For Flutter: validates `pubspec.yaml` version matches the branch version string

### `build-and-push.sh`

Commands: `build`, `scan`, `push`

- **build**: resolves image name (`ghcr.io/<repo>:<short-sha>`), reads `.env` for `--build-arg`, adds OCI labels, runs `docker buildx build --load`
- **scan**: runs Trivy; writes `trivy_scan_result=passed/failed/skipped` to `GITHUB_OUTPUT`
- **push**: runs `docker push`, resolves digest via inspect or imagetools, prunes dangling images

### `merge-validator.sh`

- Requires `GITHUB_EVENT_NAME`, `GITHUB_HEAD_REF`, `GITHUB_BASE_REF`, `GITHUB_REF_NAME`
- Configurable via `INPUT_FETCH_DEPTH` (default 50) and `INPUT_MAX_BEHIND` (default 0)

### `tag-and-release-creator.sh`

- Requires `INPUT_RELEASE_VERSION`, `GITHUB_REPOSITORY`, `GITHUB_SHA`, `INPUT_ENVIRONMENT`, `GH_TOKEN`

### `tag-and-release-validator.sh`

- Requires `INPUT_RELEASE_VERSION`, `GITHUB_REPOSITORY`, `GITHUB_OUTPUT`
- Uses `gh` CLI for tag and release existence checks
