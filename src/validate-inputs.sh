#!/usr/bin/env bash
set -euo pipefail

ACTION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/lib.sh
source "$ACTION_DIR/lib.sh"

mode="${INPUT_MODE:-bundle-and-upload}"
verify="${INPUT_VERIFY:-strict}"
dry_run="${INPUT_DRY_RUN:-false}"
fail_on_error="${INPUT_FAIL_ON_ERROR:-true}"
api_url="${INPUT_API_URL:-https://stackradar.com}"

case "$mode" in
  bundle-and-upload|bundle|upload)
    ;;
  *)
    die "mode must be one of: bundle-and-upload, bundle, upload."
    ;;
esac

case "$verify" in
  strict|checksum|false)
    ;;
  *)
    die "verify must be one of: strict, checksum, false."
    ;;
esac

if ! is_bool "$dry_run"; then
  die "dry-run must be true or false."
fi

if ! is_bool "$fail_on_error"; then
  die "fail-on-error must be true or false."
fi

require_value "api-url" "$api_url"

if [ "$mode" = "upload" ]; then
  require_value "bundle-path" "${INPUT_BUNDLE_PATH:-}"
fi

if [ "$verify" = "false" ]; then
  warn "CLI release verification is disabled. This is not recommended."
fi
