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

## Trusted evidence workflow rollout and rotation

The reusable workflow at `.github/workflows/evidence.yml` is the complete trusted
job. It accepts no inputs and pins this composite action to an immutable commit.
Use a full 40-character workflow commit SHA in customer callers, never a branch
or floating tag. The normal composite-action push-only workflow remains supported.

Roll out in this order:

1. Merge and release the CLI supporting `--pull-request-context`, `--allow-empty`,
   and `--ignore-gitignore` through its existing verified release pipeline.
2. Merge this action and reusable workflow, verify CI, and record the final
   reusable-workflow commit SHA. Keep the internal composite-action pin immutable.
3. Configure the limited GitHub App with **Metadata: read** and **Checks: write**
   only. Do not grant Contents, Pull requests, or Issues. Existing installations
   must approve the permission update in their GitHub installation settings.
4. Deploy the app's additive migration and PR upload processing, then set
   `EVIDENCE_UPLOADS_WORKFLOW_RELEASES` to a JSON SHA-to-retirement mapping. The
   recommended release has a `null` deadline. An empty map disables PR uploads.
5. Confirm a default-branch upload, PR-head evidence isolation, and check publishing
   on a test installation before asking customers to replace their workflow stub.

For rotations, publish the old SHA's retirement date in release notes at least
30 days in advance. Add the new SHA with a `null` deadline and keep the previous
SHA with that ISO-8601 retirement timestamp. The app accepts it until the deadline
and prompts installations with older observed pins to upgrade. Retain retired
entries so the UI can explain the deadline. Do not silently repoint a pinned ref.

Example configuration (substitute actual tested workflow commits):
`{"<new-40-character-sha>":null,"<previous-40-character-sha>":"2026-12-01T00:00:00Z"}`.

No `check_suite` subscription is needed: checks are created from authenticated
uploads. A deleted/broken workflow produces no app check. Require **StackRadar**
in branch protection and select the **StackRadar Limited Access app** as the
expected source; requiring an identically named Actions job is not sufficient.
Fork and Dependabot PRs get an Actions summary, not a synthetic passing app check.


## Failed Releases

If the release workflow fails, do not manually move the major tag or publish a
replacement release from a workstation.

Fix the issue in a new commit on `main`, wait for CI to pass, then let the
draft release workflow update the draft again. If a failed release or typo tag
is visible and mutable, delete it so the release list reflects only valid
attempts.
