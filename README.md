# StackRadar GitHub Action

Upload deterministic dependency-evidence bundles to StackRadar from GitHub Actions.

The action prepares the analyzed Git commit in an isolated runner directory, downloads and verifies a released `stackradar` CLI binary, requests a GitHub Actions OIDC token when uploading, then calls the CLI.
CLI binaries are downloaded from [`stackradar/stackradar-cli`](https://github.com/stackradar/stackradar-cli) releases.

## Default Workflow

```yaml
name: StackRadar

on:
  push:
    branches:
      - main
  pull_request:
    types: [opened, reopened, synchronize, ready_for_review]

permissions:
  contents: read
  id-token: write

jobs:
  stackradar:
    runs-on: ubuntu-24.04
    steps:
      - uses: stackradar/stackradar-action@v1
```

The action maintains the default-branch inventory and uploads pull-request evidence from GitHub's attested PR merge commit. It prepares that exact revision in an isolated runner-temporary directory and does not modify the caller's workspace. StackRadar compares the complete scoped bundle with the last trusted default-branch bundle, so the GitHub App never reads pull-request metadata or repository code. Fork pull requests are skipped because limited-access evidence must come from the installed repository.

By default, the action uses the latest published StackRadar CLI release and strict binary verification. Repository access uses the job's short-lived `GITHUB_TOKEN`; StackRadar's limited-access GitHub App does not receive repository Contents permission.

## Release Integrity

Action releases are source releases. After a push to `main`, the draft release
workflow waits for CI to pass for the same commit, then creates or updates the
next draft release with Release Drafter. Pull request labels resolve the version
bump:
`semver:major`, `semver:minor`, `semver:patch`, or `semver:chore`.
`semver:chore` resolves to a patch release. CI requires exactly one of these
labels on every pull request.

When a draft release is published, the release workflow verifies that the
published `vMAJOR.MINOR.PATCH` tag points to a commit on `main` with a
successful `ci.yml` run for that exact commit. It then moves the floating major
tag, such as `v1`, to the same commit.

Use `stackradar/stackradar-action@v1` when you want compatible security fixes
automatically. Pin a full commit SHA when maximum workflow reproducibility is
required.

## Security Model

GitHub Actions users should prefer OIDC over stored secrets. With
`permissions: id-token: write`, this action requests a short-lived GitHub OIDC
token only when an upload is actually needed. No token is requested for
`mode: bundle` or `dry-run: true`.

Tokens are masked in logs and passed between steps only through GitHub's
step-output mechanism. Upload tokens are passed to the CLI through
`STACKRADAR_TOKEN`, not as command-line arguments, and they are never written to
the workspace.

For bundle modes, the action fetches the GitHub event commit into an isolated
directory under `RUNNER_TEMP`. Pull-request runs fetch both the authoritative
base and head SHAs from the GitHub event, materialize the exact head tree, and
calculate changes without modifying `GITHUB_WORKSPACE`. Credentials are applied
only to the fetch command and are not persisted in Git configuration.

`verify: strict` is the default. It verifies the signed checksum manifest, the
selected archive checksum, GitHub artifact attestations for the selected release
artifacts, and SLSA provenance before running the CLI.

## Pin The Action Version

Use the floating major tag for normal workflows:

```yaml
- uses: stackradar/stackradar-action@v1
```

Pin the action to a full commit SHA when maximum workflow reproducibility is
required. Pin `cli-version` separately when you want a fixed CLI release.

## Pin The CLI Version

```yaml
- uses: stackradar/stackradar-action@v1
  with:
    cli-version: vX.Y.Z
```

`cli-version: latest` is convenient for setup. Pin an exact CLI version when workflow reproducibility matters.

## Bundle And Upload In Separate Jobs

Use `mode: bundle` when you want to store the bundle as a workflow artifact, then `mode: upload` in a later job.

```yaml
jobs:
  bundle:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
    steps:
      - id: stackradar
        uses: stackradar/stackradar-action@v1
        with:
          mode: bundle
          bundle-path: stackradar.zip
      - uses: actions/upload-artifact@v5
        with:
          name: stackradar-bundle
          path: ${{ steps.stackradar.outputs.bundle-path }}

  upload:
    needs: bundle
    runs-on: ubuntu-24.04
    permissions:
      id-token: write
    steps:
      - uses: actions/download-artifact@v6
        with:
          name: stackradar-bundle
      - uses: stackradar/stackradar-action@v1
        with:
          mode: upload
          bundle-path: stackradar.zip
```

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `cli-version` | `latest` | CLI release to download. Use `latest` or a tag such as `v0.1.0`. |
| `mode` | `bundle-and-upload` | `bundle-and-upload`, `bundle`, or `upload`. |
| `path` | `.` | Repository-relative path to scan when bundling. |
| `api-url` | `https://stackradar.com` | StackRadar app/API base URL. |
| `oidc-audience` | `stackradar.com` | Audience requested for the GitHub Actions OIDC token. |
| `token` | | Upload token override for non-standard testing. Prefer OIDC in GitHub Actions. |
| `bundle-path` | runner temp file | Bundle output path, or existing bundle path in `mode: upload`. |
| `dry-run` | `false` | Calls `stackradar upload --dry-run`; no OIDC token is requested and no upload happens. |
| `fail-on-error` | `true` | When `false`, bundle/upload failures become warnings. Verification failures still fail. |
| `verify` | `strict` | `strict`, `checksum`, or `false`. |
| `exclude` | | Newline-separated glob patterns passed to `stackradar bundle --exclude`. |

## Verification

`verify: strict` is the default. It verifies the signed checksum manifest, the selected archive checksum, GitHub artifact attestations for the selected release artifacts, and SLSA provenance.

Use `verify: checksum` if strict verification is too slow or unavailable on a constrained runner. Use `verify: false` only for temporary diagnostics.

Strict verification of public `stackradar/stackradar-cli` release attestations does not require `attestations: read` in the caller workflow.

## Outputs

| Output | Description |
| --- | --- |
| `cli-version` | Resolved CLI version without the `v` prefix. |
| `cli-path` | Installed CLI path. |
| `bundle-path` | Created or uploaded bundle path. |
| `bundle-sha256` | Bundle SHA-256 digest. |
| `upload-id` | StackRadar upload/run ID. |
| `artifact-id` | StackRadar upload artifact ID. |
| `status` | Final action status. |
