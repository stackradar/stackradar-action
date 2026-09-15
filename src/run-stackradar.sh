#!/usr/bin/env bash
set -euo pipefail

ACTION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/lib.sh
source "$ACTION_DIR/lib.sh"

cli_path="${STACKRADAR_CLI_PATH:-}"
mode="${INPUT_MODE:-bundle-and-upload}"
scan_path="${INPUT_PATH:-.}"
api_url="${INPUT_API_URL:-https://stackradar.com}"
bundle_path="${INPUT_BUNDLE_PATH:-}"
dry_run="${INPUT_DRY_RUN:-false}"
fail_on_error="${INPUT_FAIL_ON_ERROR:-true}"
token_override="${INPUT_TOKEN:-}"
oidc_token="${STACKRADAR_OIDC_TOKEN:-}"
exclude_patterns="${INPUT_EXCLUDE:-}"
github_event_name="${GITHUB_EVENT_NAME:-}"
github_event_path="${GITHUB_EVENT_PATH:-}"
github_sha="${GITHUB_SHA:-}"
repository_root="${STACKRADAR_REPOSITORY_ROOT:-}"
git_dir="${STACKRADAR_GIT_DIR:-}"
scan_scope="${STACKRADAR_SCAN_SCOPE:-.}"

unset INPUT_TOKEN
unset STACKRADAR_OIDC_TOKEN

require_value "STACKRADAR_CLI_PATH" "$cli_path"

if [ -z "$bundle_path" ]; then
  runner_temp="$(to_posix_path "${RUNNER_TEMP:-${TMPDIR:-/tmp}}")"
  mkdir -p "$runner_temp"
  bundle_dir="$(mktemp -d "$runner_temp/stackradar-action.XXXXXX")"
  bundle_path="$bundle_dir/stackradar.zip"
fi

handle_failure() {
  local status="$1"
  local message="$2"

  if [ "$fail_on_error" = "false" ]; then
    warn "$message"
    write_output "status" "$status"
    exit 0
  fi

  die "$message"
}

run_bundle() {
  local args=("$cli_path" bundle --path "$scan_path" --output "$bundle_path")
  local pattern

  if [ -n "$repository_root" ]; then
    args+=(--repository-root "$repository_root")
  fi

  while IFS= read -r pattern; do
    if [ -n "$pattern" ]; then
      args+=(--exclude "$pattern")
    fi
  done <<< "$exclude_patterns"

  if output="$("${args[@]}" 2>&1)"; then
    printf '%s\n' "$output"
    return
  fi

  if [ "$github_event_name" = "pull_request" ]; then
    local pull_request_args=("${args[@]}" --allow-empty)

    if output="$("${pull_request_args[@]}" 2>&1)"; then
      printf '%s\n' "$output"
      return
    fi
  fi

  printf '%s\n' "$output" >&2
  handle_failure "bundle-failed" "StackRadar bundle failed. No supported dependency files were found under $scan_path, or discovery failed."
}

read_collection() {
  require_command jq
  require_command unzip
  local expected_paths

  if ! expected_paths="$(unzip -p "$bundle_path" stackradar-manifest.json | jq -c '[.files[].path] | sort')"; then
    die "Unable to read dependency paths from the StackRadar bundle manifest."
  fi

  jq -cn \
    --argjson expected_paths "$expected_paths" \
    --arg scope "$scan_scope" \
    '{complete: true, expected_paths: $expected_paths, errors: [], scope: $scope}'
}

read_merge_commit() {
  require_command git
  require_command base64

  local object_base64
  if ! object_base64="$(git --git-dir="$git_dir" cat-file commit "$github_sha" | base64 | tr -d '\r\n')"; then
    die "Unable to read the GitHub-attested pull request merge commit."
  fi

  if [ -z "$object_base64" ]; then
    die "The GitHub-attested pull request merge commit was empty."
  fi

  jq -cn --arg object_base64 "$object_base64" '{object_base64: $object_base64}'
}

build_upload_context() {
  local context_path collection merge_commit
  collection="$(read_collection)"
  context_path="${bundle_path}.context.json"

  if [ "$github_event_name" != "pull_request" ]; then
    jq -n --argjson collection "$collection" \
      '{purpose: "inventory", collection: $collection}' > "$context_path"
    printf '%s\n' "$context_path"
    return
  fi

  require_value "GITHUB_EVENT_PATH" "$github_event_path"
  require_value "GITHUB_SHA" "$github_sha"

  merge_commit="null"
  if [ -n "$git_dir" ]; then
    merge_commit="$(read_merge_commit)"
  fi

  if ! jq -n \
    --argjson number "$(jq '.pull_request.number' "$github_event_path")" \
    --arg url "$(jq -r '.pull_request.html_url // empty' "$github_event_path")" \
    --arg head_sha "$github_sha" \
    --arg head_ref "$(jq -r '.pull_request.head.ref // empty' "$github_event_path")" \
    --arg head_repository_id "$(jq -r '.pull_request.head.repo.id // empty' "$github_event_path")" \
    --arg base_sha "$(jq -r '.pull_request.base.sha // empty' "$github_event_path")" \
    --arg base_ref "$(jq -r '.pull_request.base.ref // empty' "$github_event_path")" \
    --arg default_branch "$(jq -r '.repository.default_branch // .pull_request.base.ref // empty' "$github_event_path")" \
    --argjson merge_commit "$merge_commit" \
    --argjson collection "$collection" \
    '{purpose: "pull_request", collection: $collection, pull_request: ({number: $number, url: $url, head_sha: $head_sha, head_ref: $head_ref, head_repository_id: $head_repository_id, base_sha: $base_sha, base_ref: $base_ref, default_branch: $default_branch, changes: [], collection: $collection} + (if $merge_commit == null then {} else {merge_commit: $merge_commit} end))}' \
    > "$context_path"; then
    die "Unable to write the StackRadar pull request context."
  fi

  printf '%s\n' "$context_path"
}

run_upload() {
  local args=("$cli_path" upload "$bundle_path" --api-url "$api_url")
  local token=""
  local context_path=""

  if [ "$dry_run" != "true" ] && { [ "$github_event_name" = "pull_request" ] || [ -n "$repository_root" ]; }; then
    if ! context_path="$(build_upload_context)"; then
      handle_failure "context-failed" "StackRadar could not collect upload context."
    fi

    args+=(--context-file "$context_path")
  fi

  if [ "$dry_run" = "true" ]; then
    args+=(--dry-run)
  else
    if [ -n "$token_override" ]; then
      token="$token_override"
    elif [ -n "$oidc_token" ]; then
      token="$oidc_token"
    else
      handle_failure "upload-failed" "Unable to upload without a token. Add permissions: id-token: write, or provide token for non-standard testing."
    fi

    mask_secret "$token"
  fi

  if ! output="$(STACKRADAR_TOKEN="$token" "${args[@]}" 2>&1)"; then
    printf '%s\n' "$output" >&2
    handle_failure "upload-failed" "StackRadar upload failed."
  fi

  printf '%s\n' "$output"

  upload_id="$(printf '%s\n' "$output" | awk -F': ' '/upload_id:/ { print $2; exit }')"
  artifact_id="$(printf '%s\n' "$output" | awk -F': ' '/artifact_id:/ { print $2; exit }')"
  status="$(printf '%s\n' "$output" | awk -F': ' '/status:/ { print $2; exit }')"

  if [ "$dry_run" = "true" ]; then
    status="dry-run"
  fi

  write_output "upload-id" "$upload_id"
  write_output "artifact-id" "$artifact_id"
  write_output "status" "$status"
}

case "$mode" in
  bundle-and-upload)
    run_bundle
    ;;
  bundle)
    run_bundle
    write_output "bundle-path" "$bundle_path"
    write_output "bundle-sha256" "$(sha256_file "$bundle_path")"
    write_output "status" "bundled"
    exit 0
    ;;
  upload)
    require_value "bundle-path" "$bundle_path"
    ;;
  *)
    die "mode must be one of: bundle-and-upload, bundle, upload."
    ;;
esac

if [ ! -f "$bundle_path" ]; then
  handle_failure "bundle-missing" "Bundle file does not exist at $bundle_path."
fi

write_output "bundle-path" "$bundle_path"
write_output "bundle-sha256" "$(sha256_file "$bundle_path")"
run_upload
