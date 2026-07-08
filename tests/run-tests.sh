#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="${TMPDIR:-/tmp}/stackradar-action-tests"

pass_count=0

fail() {
  echo "not ok - $1" >&2
  exit 1
}

ok() {
  pass_count=$((pass_count + 1))
  echo "ok $pass_count - $1"
}

reset_tmp() {
  rm -rf "$TMP_ROOT"
  mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/work" "$TMP_ROOT/out"
}

write_fake_cli() {
  local path="$TMP_ROOT/bin/stackradar"
  cat >"$path" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

echo "$*" >> "${FAKE_CLI_LOG:?}"

case "$1" in
  version)
    echo "stackradar 9.8.7 (commit test, built now)"
    ;;
  bundle)
    output=""
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "--output" ]; then
        shift
        output="$1"
      fi
      shift || true
    done
    if [ "${FAKE_BUNDLE_FAIL:-}" = "1" ]; then
      echo "no supported dependency files found" >&2
      exit 2
    fi
    mkdir -p "$(dirname "$output")"
    printf "bundle-bytes" > "$output"
    echo "Bundle:"
    echo "  output: $output"
    echo "  sha256: fake-sha"
    ;;
  upload)
    dry_run="0"
    for arg in "$@"; do
      if [ "$arg" = "--dry-run" ]; then
        dry_run="1"
      fi
    done
    if [ "$dry_run" = "1" ]; then
      echo "Upload dry run:"
      echo "  status: dry-run"
      exit 0
    fi
    if [ -n "${FAKE_TOKEN_LOG:-}" ]; then
      printf '%s\n' "${STACKRADAR_TOKEN:-}" > "$FAKE_TOKEN_LOG"
    fi
    if [ "${FAKE_UPLOAD_FAIL:-}" = "1" ]; then
      echo "initialize upload failed with HTTP 403: denied" >&2
      exit 3
    fi
    echo "Bundle uploaded:"
    echo "  upload_id: run-123"
    echo "  artifact_id: artifact-456"
    echo "  status: processing"
    ;;
  *)
    echo "unexpected command: $*" >&2
    exit 99
    ;;
esac
SH
  chmod +x "$path"
}

run_with_outputs() {
  local script="$1"
  shift
  local output="$TMP_ROOT/out/github-output"
  local envfile="$TMP_ROOT/out/github-env"
  : >"$output"
  : >"$envfile"
  GITHUB_OUTPUT="$output" GITHUB_ENV="$envfile" "$script" "$@"
}

assert_output_contains() {
  local expected="$1"
  grep -Fq "$expected" "$TMP_ROOT/out/github-output" || {
    echo "GITHUB_OUTPUT:" >&2
    cat "$TMP_ROOT/out/github-output" >&2
    fail "expected GITHUB_OUTPUT to contain $expected"
  }
}

assert_output_matches() {
  local pattern="$1"
  grep -Eq "$pattern" "$TMP_ROOT/out/github-output" || {
    echo "GITHUB_OUTPUT:" >&2
    cat "$TMP_ROOT/out/github-output" >&2
    fail "expected GITHUB_OUTPUT to match $pattern"
  }
}

test_validate_rejects_bad_mode() {
  reset_tmp
  if INPUT_MODE="scan" \
    INPUT_VERIFY="strict" \
    INPUT_DRY_RUN="false" \
    INPUT_FAIL_ON_ERROR="true" \
    INPUT_API_URL="https://stackradar.com" \
    "$ROOT/src/validate-inputs.sh" >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr"; then
    fail "validate-inputs should reject invalid mode"
  fi
  grep -Fq "mode must be one of" "$TMP_ROOT/stderr" || fail "invalid mode error was unclear"
  ok "validate-inputs rejects invalid mode"
}

test_request_oidc_masks_token() {
  reset_tmp
  local response="$TMP_ROOT/oidc-response.json"
  printf '{"value":"header.payload.signature"}' >"$response"
  cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat "${FAKE_OIDC_RESPONSE:?}"
SH
  chmod +x "$TMP_ROOT/bin/curl"
  PATH="$TMP_ROOT/bin:$PATH" \
    ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token" \
    ACTIONS_ID_TOKEN_REQUEST_URL="https://token.actions.githubusercontent.com/id" \
    INPUT_OIDC_AUDIENCE="stackradar.com" \
    FAKE_OIDC_RESPONSE="$response" \
    run_with_outputs "$ROOT/src/request-oidc-token.sh" >"$TMP_ROOT/stdout"

  grep -Fq "::add-mask::header.payload.signature" "$TMP_ROOT/stdout" || fail "OIDC token was not masked"
  assert_output_contains "token=header.payload.signature"
  ok "request-oidc-token masks and outputs token"
}

test_run_bundle_mode_does_not_upload() {
  reset_tmp
  write_fake_cli
  FAKE_CLI_LOG="$TMP_ROOT/cli.log" \
    STACKRADAR_CLI_PATH="$TMP_ROOT/bin/stackradar" \
    INPUT_MODE="bundle" \
    INPUT_PATH="$TMP_ROOT/work" \
    INPUT_API_URL="https://stackradar.com" \
    INPUT_BUNDLE_PATH="$TMP_ROOT/work/stackradar.zip" \
    INPUT_DRY_RUN="false" \
    INPUT_FAIL_ON_ERROR="true" \
    INPUT_TOKEN="" \
    INPUT_EXCLUDE=$'vendor/**\nnode_modules/**' \
    run_with_outputs "$ROOT/src/run-stackradar.sh" >"$TMP_ROOT/stdout"

  grep -Fq "bundle --path $TMP_ROOT/work --output $TMP_ROOT/work/stackradar.zip --exclude vendor/** --exclude node_modules/**" "$TMP_ROOT/cli.log" || fail "bundle command was not called with expected args"
  if grep -Fq "upload" "$TMP_ROOT/cli.log"; then
    fail "bundle mode should not call upload"
  fi
  assert_output_contains "status=bundled"
  ok "bundle mode only bundles"
}

test_run_upload_mode_uses_oidc_token_and_masks_it() {
  reset_tmp
  write_fake_cli
  printf "bundle-bytes" >"$TMP_ROOT/work/stackradar.zip"
  FAKE_CLI_LOG="$TMP_ROOT/cli.log" \
    FAKE_TOKEN_LOG="$TMP_ROOT/token.log" \
    STACKRADAR_CLI_PATH="$TMP_ROOT/bin/stackradar" \
    STACKRADAR_OIDC_TOKEN="oidc-token" \
    INPUT_MODE="upload" \
    INPUT_PATH="." \
    INPUT_API_URL="https://stackradar.com" \
    INPUT_BUNDLE_PATH="$TMP_ROOT/work/stackradar.zip" \
    INPUT_DRY_RUN="false" \
    INPUT_FAIL_ON_ERROR="true" \
    INPUT_TOKEN="" \
    INPUT_EXCLUDE="" \
    run_with_outputs "$ROOT/src/run-stackradar.sh" >"$TMP_ROOT/stdout"

  grep -Fq "::add-mask::oidc-token" "$TMP_ROOT/stdout" || fail "OIDC upload token was not masked"
  grep -Fq "upload $TMP_ROOT/work/stackradar.zip --api-url https://stackradar.com" "$TMP_ROOT/cli.log" || fail "upload command did not call CLI upload"
  if grep -Fq -- "--token" "$TMP_ROOT/cli.log"; then
    fail "upload token should not be passed as a CLI argument"
  fi
  grep -Fxq "oidc-token" "$TMP_ROOT/token.log" || fail "OIDC token was not passed through STACKRADAR_TOKEN"
  assert_output_contains "upload-id=run-123"
  assert_output_contains "artifact-id=artifact-456"
  assert_output_contains "status=processing"
  ok "upload mode uses OIDC token"
}

test_run_upload_mode_uses_input_token_without_cli_argument() {
  reset_tmp
  write_fake_cli
  printf "bundle-bytes" >"$TMP_ROOT/work/stackradar.zip"
  FAKE_CLI_LOG="$TMP_ROOT/cli.log" \
    FAKE_TOKEN_LOG="$TMP_ROOT/token.log" \
    STACKRADAR_CLI_PATH="$TMP_ROOT/bin/stackradar" \
    STACKRADAR_OIDC_TOKEN="" \
    INPUT_MODE="upload" \
    INPUT_PATH="." \
    INPUT_API_URL="https://stackradar.com" \
    INPUT_BUNDLE_PATH="$TMP_ROOT/work/stackradar.zip" \
    INPUT_DRY_RUN="false" \
    INPUT_FAIL_ON_ERROR="true" \
    INPUT_TOKEN="static-token" \
    INPUT_EXCLUDE="" \
    run_with_outputs "$ROOT/src/run-stackradar.sh" >"$TMP_ROOT/stdout"

  grep -Fq "::add-mask::static-token" "$TMP_ROOT/stdout" || fail "input upload token was not masked"
  if grep -Fq -- "--token" "$TMP_ROOT/cli.log"; then
    fail "input token should not be passed as a CLI argument"
  fi
  grep -Fxq "static-token" "$TMP_ROOT/token.log" || fail "input token was not passed through STACKRADAR_TOKEN"
  ok "upload mode uses input token without CLI argument"
}

test_run_dry_run_calls_cli_upload_dry_run_without_token() {
  reset_tmp
  write_fake_cli
  FAKE_CLI_LOG="$TMP_ROOT/cli.log" \
    STACKRADAR_CLI_PATH="$TMP_ROOT/bin/stackradar" \
    INPUT_MODE="bundle-and-upload" \
    INPUT_PATH="$TMP_ROOT/work" \
    INPUT_API_URL="https://stackradar.com" \
    INPUT_BUNDLE_PATH="$TMP_ROOT/work/stackradar.zip" \
    INPUT_DRY_RUN="true" \
    INPUT_FAIL_ON_ERROR="true" \
    INPUT_TOKEN="" \
    INPUT_EXCLUDE="" \
    run_with_outputs "$ROOT/src/run-stackradar.sh" >"$TMP_ROOT/stdout"

  grep -Fq "upload $TMP_ROOT/work/stackradar.zip --api-url https://stackradar.com --dry-run" "$TMP_ROOT/cli.log" || fail "dry-run did not call CLI upload --dry-run"
  if grep -Fq -- "--token" "$TMP_ROOT/cli.log"; then
    fail "dry-run should not pass a token"
  fi
  assert_output_contains "status=dry-run"
  ok "dry-run delegates to CLI upload --dry-run without token"
}

test_fail_on_error_false_suppresses_upload_failure() {
  reset_tmp
  write_fake_cli
  printf "bundle-bytes" >"$TMP_ROOT/work/stackradar.zip"

  FAKE_CLI_LOG="$TMP_ROOT/cli.log" \
    FAKE_UPLOAD_FAIL="1" \
    STACKRADAR_CLI_PATH="$TMP_ROOT/bin/stackradar" \
    STACKRADAR_OIDC_TOKEN="oidc-token" \
    INPUT_MODE="upload" \
    INPUT_PATH="." \
    INPUT_API_URL="https://stackradar.com" \
    INPUT_BUNDLE_PATH="$TMP_ROOT/work/stackradar.zip" \
    INPUT_DRY_RUN="false" \
    INPUT_FAIL_ON_ERROR="false" \
    INPUT_TOKEN="" \
    INPUT_EXCLUDE="" \
    run_with_outputs "$ROOT/src/run-stackradar.sh" >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr"

  grep -Fq "::warning::StackRadar upload failed." "$TMP_ROOT/stderr" || fail "upload failure was not downgraded to a warning"
  assert_output_contains "status=upload-failed"
  ok "fail-on-error false suppresses upload failure"
}

test_fail_on_error_false_suppresses_bundle_failure() {
  reset_tmp
  write_fake_cli

  FAKE_CLI_LOG="$TMP_ROOT/cli.log" \
    FAKE_BUNDLE_FAIL="1" \
    STACKRADAR_CLI_PATH="$TMP_ROOT/bin/stackradar" \
    INPUT_MODE="bundle-and-upload" \
    INPUT_PATH="$TMP_ROOT/work" \
    INPUT_API_URL="https://stackradar.com" \
    INPUT_BUNDLE_PATH="$TMP_ROOT/work/stackradar.zip" \
    INPUT_DRY_RUN="false" \
    INPUT_FAIL_ON_ERROR="false" \
    INPUT_TOKEN="" \
    INPUT_EXCLUDE="" \
    run_with_outputs "$ROOT/src/run-stackradar.sh" >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr"

  grep -Fq "::warning::StackRadar bundle failed." "$TMP_ROOT/stderr" || fail "bundle failure was not downgraded to a warning"
  assert_output_contains "status=bundle-failed"
  if grep -Fq "upload" "$TMP_ROOT/cli.log"; then
    fail "bundle failure should not continue to upload"
  fi
  ok "fail-on-error false suppresses bundle failure"
}

test_install_maps_platform_and_outputs_cli_version() {
  reset_tmp
  local archive_name="stackradar_1.2.3_linux_amd64.tar.gz"
  local release_dir="$TMP_ROOT/release"
  mkdir -p "$release_dir/archive/bin"
  write_fake_cli
  cp "$TMP_ROOT/bin/stackradar" "$release_dir/archive/stackradar"
  tar -C "$release_dir/archive" -czf "$release_dir/$archive_name" stackradar
  local checksum
  checksum="$(shasum -a 256 "$release_dir/$archive_name" | awk '{print $1}')"
  printf '%s  %s\n' "$checksum" "$archive_name" >"$release_dir/stackradar_1.2.3_checksums.txt"
  printf '{}' >"$release_dir/stackradar_1.2.3_checksums.txt.sigstore.json"

cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|--output)
      shift
      out="${1:?missing output value}"
      ;;
    -o*)
      out="${1#-o}"
      ;;
    --url)
      shift
      url="${1:?missing url value}"
      ;;
    -H|--header|-X|--request|-w|--write-out|--connect-timeout|--data|--data-binary|--data-raw|--max-time|--proto|--retry|--retry-delay|--retry-max-time)
      shift
      ;;
    --fail|--head|--location|--show-error|--silent|--tlsv1.2)
      ;;
    -*)
      ;;
    *)
      url="$1"
      ;;
  esac
  shift || true
done
test -n "$out" || { echo "missing curl output" >&2; exit 2; }
test -n "$url" || { echo "missing curl url" >&2; exit 2; }
name="${url##*/}"
cp "${FAKE_RELEASE_DIR:?}/$name" "$out"
SH
  chmod +x "$TMP_ROOT/bin/curl"

  PATH="$TMP_ROOT/bin:$PATH" \
    RUNNER_OS="Linux" \
    RUNNER_ARCH="X64" \
    RUNNER_TEMP="$TMP_ROOT/runner" \
    INPUT_CLI_VERSION="v1.2.3" \
    INPUT_VERIFY="checksum" \
    FAKE_RELEASE_DIR="$release_dir" \
    FAKE_CLI_LOG="$TMP_ROOT/cli.log" \
    run_with_outputs "$ROOT/src/install-cli.sh" \
      --release-base-url "https://example.test/releases" \
      --skip-cosign-verify-for-test \
      >"$TMP_ROOT/stdout"

  assert_output_contains "cli-version=1.2.3"
  assert_output_matches "^cli-path=$TMP_ROOT/runner/stackradar-action[.][^/]+/bin/stackradar$"
  ok "install maps platform, verifies checksum, and outputs CLI path"
}

test_install_rejects_ambient_trust_overrides() {
  reset_tmp

  if STACKRADAR_CLI_REPOSITORY="attacker/fork" \
    STACKRADAR_RELEASE_BASE_URL="https://example.test/releases" \
    STACKRADAR_SKIP_COSIGN_VERIFY="true" \
    RUNNER_OS="Linux" \
    RUNNER_ARCH="X64" \
    RUNNER_TEMP="$TMP_ROOT/runner" \
    INPUT_CLI_VERSION="v1.2.3" \
    INPUT_VERIFY="checksum" \
    "$ROOT/src/install-cli.sh" >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr"; then
    fail "install should reject hidden ambient trust overrides"
  fi

  grep -Fq "Unsupported environment override" "$TMP_ROOT/stderr" || {
    echo "stderr:" >&2
    cat "$TMP_ROOT/stderr" >&2
    fail "hidden override rejection message was unclear"
  }

  ok "install rejects ambient trust overrides"
}

test_validate_rejects_bad_mode
test_request_oidc_masks_token
test_run_bundle_mode_does_not_upload
test_run_upload_mode_uses_oidc_token_and_masks_it
test_run_upload_mode_uses_input_token_without_cli_argument
test_run_dry_run_calls_cli_upload_dry_run_without_token
test_fail_on_error_false_suppresses_upload_failure
test_fail_on_error_false_suppresses_bundle_failure
test_install_maps_platform_and_outputs_cli_version
test_install_rejects_ambient_trust_overrides

echo "$pass_count tests passed"
