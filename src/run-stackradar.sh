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

  while IFS= read -r pattern; do
    if [ -n "$pattern" ]; then
      args+=(--exclude "$pattern")
    fi
  done <<< "$exclude_patterns"

  if ! output="$("${args[@]}" 2>&1)"; then
    printf '%s\n' "$output" >&2
    handle_failure "bundle-failed" "StackRadar bundle failed. No supported dependency files were found under $scan_path, or discovery failed."
  fi

  printf '%s\n' "$output"
}

run_upload() {
  local args=("$cli_path" upload "$bundle_path" --api-url "$api_url")
  local token=""

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
