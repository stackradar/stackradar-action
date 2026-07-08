# StackRadar GitHub Action

Upload deterministic dependency-evidence bundles to StackRadar from GitHub Actions.

The action is intentionally thin: it downloads a released `stackradar` CLI binary, verifies it, requests a GitHub Actions OIDC token when uploading, then calls the CLI.
CLI binaries are downloaded from [`stackradar/stackradar-cli`](https://github.com/stackradar/stackradar-cli) releases.

## Default Workflow

```yaml
name: StackRadar

on:
  push:
    branches:
      - main

permissions:
  contents: read
  id-token: write

jobs:
  stackradar:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v7
      - uses: stackradar/stackradar-action@v1
```

By default, the action uses the latest published StackRadar CLI release and strict binary verification.

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
      - uses: actions/checkout@v7
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
| `path` | `.` | Repository path to scan when bundling. |
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
