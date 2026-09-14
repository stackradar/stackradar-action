#!/usr/bin/env bash
set -euo pipefail

ACTION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/lib.sh
source "$ACTION_DIR/lib.sh"

requested_path="${INPUT_PATH:-.}"
github_event_name="${GITHUB_EVENT_NAME:-}"
github_event_path="${GITHUB_EVENT_PATH:-}"
github_repository="${GITHUB_REPOSITORY:-}"
github_sha="${GITHUB_SHA:-}"
github_server_url="${GITHUB_SERVER_URL:-https://github.com}"
github_token="${STACKRADAR_GITHUB_TOKEN:-}"
fail_on_error="${INPUT_FAIL_ON_ERROR:-true}"
repository_url=""
skip_auth_for_test=false

unset STACKRADAR_GITHUB_TOKEN

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repository-url)
      shift
      repository_url="${1:-}"
      ;;
    --skip-auth-for-test)
      skip_auth_for_test=true
      ;;
    *)
      die "Unknown prepare-repository argument: $1"
      ;;
  esac
  shift
done

require_value "GITHUB_REPOSITORY" "$github_repository"

if [ "$github_event_name" = "pull_request" ]; then
  require_command jq
  require_value "GITHUB_EVENT_PATH" "$github_event_path"

  head_repository="$(jq -r '.pull_request.head.repo.full_name // empty' "$github_event_path")"
  require_value "pull request head repository" "$head_repository"

  if [ "$head_repository" != "$github_repository" ]; then
    warn "StackRadar skips pull requests from forks because the limited-access check only accepts evidence from the installed repository."
    write_output "path" "$requested_path"
    write_output "skip" "true"
    write_output "status" "skipped"
    exit 0
  fi

  base_sha="$(jq -r '.pull_request.base.sha // empty' "$github_event_path")"
  head_sha="$(jq -r '.pull_request.head.sha // empty' "$github_event_path")"
  require_value "pull request base SHA" "$base_sha"
  require_value "pull request head SHA" "$head_sha"
else
  base_sha=""
  head_sha="$github_sha"
  require_value "GITHUB_SHA" "$head_sha"
fi

if [[ ! "$head_sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
  die "GitHub head SHA must be a full 40-character commit SHA."
fi

if [ -n "$base_sha" ] && [[ ! "$base_sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
  die "GitHub base SHA must be a full 40-character commit SHA."
fi

require_command git

case "$requested_path" in
  ""|.|./)
    requested_path="."
    ;;
  /*|..|../*|*/../*|*/..)
    die "path must stay within the repository when checkout is enabled."
    ;;
esac

runner_temp="$(to_posix_path "${RUNNER_TEMP:-${TMPDIR:-/tmp}}")"
mkdir -p "$runner_temp"
checkout_root="$(mktemp -d "$runner_temp/stackradar-source.XXXXXX")"
git_dir="$checkout_root/repository.git"
source_root="$checkout_root/source"
cleanup_checkout=true

cleanup_failed_checkout() {
  if [ "$cleanup_checkout" = "true" ] && [ -n "${checkout_root:-}" ]; then
    rm -rf -- "$checkout_root"
  fi
}
trap cleanup_failed_checkout EXIT

# Preparation failures are bundle failures: honor fail-on-error the same way
# run-stackradar.sh does, and let the EXIT trap discard the partial checkout.
handle_prepare_failure() {
  local message="$1"

  if [ "$fail_on_error" = "false" ]; then
    warn "$message"
    write_output "path" "$requested_path"
    write_output "skip" "true"
    write_output "status" "prepare-failed"
    exit 0
  fi

  die "$message"
}

git init --bare --quiet "$git_dir"

if [ -z "$repository_url" ]; then
  repository_url="${github_server_url%/}/${github_repository}.git"
fi

git_fetch=(git --git-dir="$git_dir")

if [ "$skip_auth_for_test" != "true" ]; then
  require_command base64
  require_value "GitHub token" "$github_token"
  mask_secret "$github_token"
  encoded_credentials="$(printf 'x-access-token:%s' "$github_token" | base64 | tr -d '\r\n')"
  mask_secret "$encoded_credentials"
  git_fetch+=(-c "http.extraHeader=AUTHORIZATION: basic $encoded_credentials")
fi

fetch_ref() {
  local refspec="$1"

  GIT_TERMINAL_PROMPT=0 "${git_fetch[@]}" \
    fetch \
    --quiet \
    --no-tags \
    --no-recurse-submodules \
    --depth=1 \
    "$repository_url" \
    "$refspec"
}

# The head commit is required to bundle at all. The base commit only feeds the
# pull request change set, and GitHub may already have collected it after a
# force-push or rebase of the base branch, so its absence must not fail the run.
if ! fetch_ref "$head_sha:refs/stackradar/head"; then
  handle_prepare_failure "Unable to fetch the analyzed commit $head_sha from $github_repository."
fi

if [ -n "$base_sha" ] && ! fetch_ref "$base_sha:refs/stackradar/base"; then
  warn "StackRadar could not fetch pull request base commit $base_sha. The changed-path set will be reported as incomplete."
fi

unset github_token encoded_credentials git_fetch

# A detached worktree preserves the exact fetched commit while also giving the
# CLI normal Git metadata. git archive is not used because it drops paths marked
# export-ignore, including dependency evidence that still belongs in a scan.
if ! git --git-dir="$git_dir" worktree add --quiet --detach "$source_root" refs/stackradar/head; then
  handle_prepare_failure "Unable to materialize the analyzed Git commit."
fi

source_root="$(cd "$source_root" && pwd -P)"
candidate_path="$source_root"
if [ "$requested_path" != "." ]; then
  candidate_path="$source_root/$requested_path"
fi

if ! scan_path="$(cd "$candidate_path" 2>/dev/null && pwd -P)"; then
  handle_prepare_failure "path does not identify a directory in the analyzed Git commit: $requested_path"
fi

case "$scan_path/" in
  "$source_root/"*) ;;
  *) die "path must stay within the repository when checkout is enabled." ;;
esac

scan_scope="."
if [ "$scan_path" != "$source_root" ]; then
  scan_scope="${scan_path#"$source_root/"}"
fi

write_output "path" "$scan_path"
write_output "repository-root" "$source_root"
write_output "scope" "$scan_scope"
write_output "git-dir" "$git_dir"
write_output "checkout-root" "$checkout_root"
write_output "skip" "false"

cleanup_checkout=false
