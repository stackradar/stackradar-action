# Release Process

Only maintainers with release rights may publish `vMAJOR.MINOR.PATCH` releases.
Release tags should be protected by a repository ruleset for `refs/tags/v*`.
Until a dedicated release team exists, restrict tag creation, updates, and
deletion to organization admins or a small release role.

All changes to `main` must go through a pull request. The `main` branch ruleset
should block deletions and non-fast-forward updates, require pull requests, and
require the `test` and `Integration` CI status checks to pass before merge.

Draft releases are maintained automatically by Release Drafter after pushes to
`main`. The draft release workflow waits for `ci.yml` to pass for the same
commit before it lets Release Drafter update the draft. Release Drafter collects
pull requests merged since the latest published stable release and resolves the
next version from labels:

- `semver:major` creates the next major version.
- `semver:minor` creates the next minor version unless a major label is present.
- `semver:patch` creates the next patch version.
- `semver:chore` is grouped as maintenance and resolves to a patch version.

CI requires exactly one of these labels on every pull request. Label changes
rerun the PR workflow, so correcting a missing or duplicate release label is
enough to unblock the PR.

Published release tags must point to a commit that is reachable from `main`,
and `ci.yml` must already have completed successfully for that exact commit.
The release workflow verifies both conditions before moving the floating major
tag.

## Releasing

1. Merge the release candidate to `main`.
2. Wait for `ci.yml` to pass on `main`.
3. Review the automatically updated draft release.
4. Publish the draft release.

Publishing the draft release creates the exact version tag and triggers the
release workflow. The workflow verifies the tag and moves the floating major
tag, such as `v1`, to the same commit. Consumers who want security fixes
automatically can use `stackradar/stackradar-action@v1`. Consumers who want
maximum reproducibility can pin a full commit SHA.

## Failed Releases

If the release workflow fails, do not manually move the major tag or publish a
replacement release from a workstation.

Fix the issue in a new commit on `main`, wait for CI to pass, then let the
draft release workflow update the draft again. If a failed release or typo tag
is visible and mutable, delete it so the release list reflects only valid
attempts.
