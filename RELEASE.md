# Release Process

Only maintainers with release rights may create `vMAJOR.MINOR.PATCH` tags.
Release tags should be protected by a repository ruleset for `refs/tags/v*`.
Until a dedicated release team exists, restrict tag creation, updates, and
deletion to organization admins or a small release role.

All changes to `main` must go through a pull request. The `main` branch ruleset
should block deletions and non-fast-forward updates, require pull requests, and
require the `test` and `Integration` CI status checks to pass before merge.

Tags must point to a commit that is reachable from `main`, and `ci.yml` must
already have completed successfully for that exact commit. The release workflow
verifies both conditions before creating a release.

## Releasing

1. Merge the release candidate to `main`.
2. Wait for `ci.yml` to pass on `main`.
3. Create and push a stable semver tag from that exact commit, such as
   `v1.2.3`.

The release workflow creates a GitHub Release for the exact version tag and
moves the floating major tag, such as `v1`, to the same commit. Consumers who
want security fixes automatically can use `stackradar/stackradar-action@v1`.
Consumers who want maximum reproducibility can pin a full commit SHA.

## Failed Releases

If the release workflow fails, do not manually move the major tag or publish a
replacement release from a workstation.

Fix the issue in a new commit on `main`, wait for CI to pass, then create a new
version tag. If a failed release or typo tag is visible and mutable, delete it
so the release list reflects only valid attempts.
