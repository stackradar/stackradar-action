#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="${TMPDIR:-/tmp}/stackradar-action-tests"

unset GITHUB_EVENT_NAME
unset GITHUB_EVENT_PATH
unset GITHUB_REPOSITORY
unset GITHUB_SERVER_URL
unset GITHUB_SHA

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
    allow_empty="0"
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "--output" ]; then
        shift
        output="$1"
      fi
      if [ "$1" = "--allow-empty" ]; then
        allow_empty="1"
      fi
      shift || true
    done
    if [ "${FAKE_BUNDLE_FAIL:-}" = "1" ]; then
      echo "no supported dependency files found" >&2
      exit 2
    fi
    if [ "${FAKE_BUNDLE_EMPTY:-}" = "1" ] && [ "$allow_empty" != "1" ]; then
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

create_fixture_repository() {
  local source="$TMP_ROOT/repository"
  local origin="$TMP_ROOT/origin.git"

  git init --quiet "$source"
  git -C "$source" config user.email "tests@stackradar.com"
  git -C "$source" config user.name "StackRadar Tests"

  printf '%s\n' '{"name":"fixture"}' >"$source/package-old.json"
  printf '%s\n' '{"lockfileVersion":3,"packages":{}}' >"$source/package-lock.json"
  git -C "$source" add package-old.json package-lock.json
  git -C "$source" commit --quiet -m "base"
  FIXTURE_BASE_SHA="$(git -C "$source" rev-parse HEAD)"

  mv "$source/package-old.json" "$source/package.json"
  rm "$source/package-lock.json"
  mkdir -p "$source/packages/web" "$source/vendored"
  printf '%s\n' 'lockfileVersion: 9' >"$source/packages/web/pnpm-lock.yaml"
  printf '%s\n' '# yarn lockfile v1' >"$source/vendored/yarn.lock"
  printf '%s\n' 'vendored/ export-ignore' >"$source/.gitattributes"
  git -C "$source" add --all
  git -C "$source" commit --quiet -m "head"
  FIXTURE_HEAD_SHA="$(git -C "$source" rev-parse HEAD)"
  FIXTURE_MERGE_SHA="$(printf '%s\n' 'merge' | git -C "$source" commit-tree "${FIXTURE_HEAD_SHA}^{tree}" -p "$FIXTURE_BASE_SHA" -p "$FIXTURE_HEAD_SHA")"

  git clone --bare --quiet "$source" "$origin"
  git --git-dir="$origin" update-ref refs/pull/42/merge "$FIXTURE_MERGE_SHA"
  FIXTURE_ORIGIN="$origin"
}

create_deletion_only_fixture_repository() {
  local source="$TMP_ROOT/deletion-repository"
  local origin="$TMP_ROOT/deletion-origin.git"

  git init --quiet "$source"
  git -C "$source" config user.email "tests@stackradar.com"
  git -C "$source" config user.name "StackRadar Tests"

  printf '%s\n' '{"lockfileVersion":3,"packages":{}}' >"$source/package-lock.json"
  printf '%s\n' '# Fixture' >"$source/README.md"
  git -C "$source" add package-lock.json README.md
  git -C "$source" commit --quiet -m "base"
  FIXTURE_BASE_SHA="$(git -C "$source" rev-parse HEAD)"

  rm "$source/package-lock.json"
  git -C "$source" add --all
  git -C "$source" commit --quiet -m "delete lockfile"
  FIXTURE_HEAD_SHA="$(git -C "$source" rev-parse HEAD)"
  FIXTURE_MERGE_SHA="$(printf '%s\n' 'merge' | git -C "$source" commit-tree "${FIXTURE_HEAD_SHA}^{tree}" -p "$FIXTURE_BASE_SHA" -p "$FIXTURE_HEAD_SHA")"

  git clone --bare --quiet "$source" "$origin"
  git --git-dir="$origin" update-ref refs/pull/42/merge "$FIXTURE_MERGE_SHA"
  FIXTURE_ORIGIN="$origin"
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

test_prepare_pull_request_uses_isolated_exact_head() {
  reset_tmp
  create_fixture_repository
  local workspace="$TMP_ROOT/caller-workspace"
  mkdir -p "$workspace"
  printf '%s\n' "caller state" >"$workspace/sentinel.txt"

  cat >"$TMP_ROOT/event.json" <<JSON
{
  "repository": {"id": 20002, "full_name": "acme/radar", "default_branch": "main"},
  "pull_request": {
    "number": 42,
    "head": {"sha": "$FIXTURE_HEAD_SHA", "repo": {"id": 20002, "full_name": "acme/radar"}},
    "base": {"sha": "$FIXTURE_BASE_SHA", "repo": {"id": 20002, "full_name": "acme/radar"}}
  }
}
JSON

  GITHUB_EVENT_NAME="pull_request" \
    GITHUB_EVENT_PATH="$TMP_ROOT/event.json" \
    GITHUB_REPOSITORY="acme/radar" \
    GITHUB_SHA="$FIXTURE_MERGE_SHA" \
    GITHUB_WORKSPACE="$workspace" \
    RUNNER_TEMP="$TMP_ROOT/runner" \
    INPUT_PATH="." \
    run_with_outputs "$ROOT/src/prepare-repository.sh" \
      --repository-url "$FIXTURE_ORIGIN" \
      --skip-auth-for-test \
      >"$TMP_ROOT/stdout"

  local prepared_path prepared_repository_root prepared_git_dir checkout_root
  prepared_path="$(sed -n 's/^path=//p' "$TMP_ROOT/out/github-output")"
  prepared_repository_root="$(sed -n 's/^repository-root=//p' "$TMP_ROOT/out/github-output")"
  prepared_git_dir="$(sed -n 's/^git-dir=//p' "$TMP_ROOT/out/github-output")"
  checkout_root="$(sed -n 's/^checkout-root=//p' "$TMP_ROOT/out/github-output")"

  test -f "$prepared_path/package.json" || fail "prepared PR source did not contain the exact head tree"
  test -f "$prepared_path/packages/web/pnpm-lock.yaml" || fail "prepared PR source omitted a head dependency file"
  test ! -e "$prepared_path/package-lock.json" || fail "prepared PR source retained a file deleted at the head"
  test "$(git -C "$prepared_repository_root" rev-parse HEAD)" = "$FIXTURE_MERGE_SHA" || fail "prepared source did not expose the analyzed Git merge commit"
  test "$(cat "$workspace/sentinel.txt")" = "caller state" || fail "preparing PR source modified the caller workspace"
  test "$(find "$workspace" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" = "1" || fail "preparing PR source added files to the caller workspace"

  if git --git-dir="$prepared_git_dir" rev-parse --verify --quiet refs/stackradar/base >/dev/null; then
    fail "PR preparation fetched base code even though collection comparison is server-side"
  fi

  RUNNER_TEMP="$TMP_ROOT/runner" \
    STACKRADAR_CHECKOUT_ROOT="$checkout_root" \
    "$ROOT/src/cleanup-repository.sh"
  test ! -e "$checkout_root" || fail "prepared repository was not cleaned up"

  ok "prepare repository isolates only the attested PR revision"
}

test_prepare_push_uses_event_commit_without_workspace_checkout() {
  reset_tmp
  create_fixture_repository
  local workspace="$TMP_ROOT/empty-workspace"
  mkdir -p "$workspace"

  GITHUB_EVENT_NAME="push" \
    GITHUB_REPOSITORY="acme/radar" \
    GITHUB_SHA="$FIXTURE_HEAD_SHA" \
    GITHUB_WORKSPACE="$workspace" \
    RUNNER_TEMP="$TMP_ROOT/runner" \
    INPUT_PATH="packages/web" \
    run_with_outputs "$ROOT/src/prepare-repository.sh" \
      --repository-url "$FIXTURE_ORIGIN" \
      --skip-auth-for-test \
      >"$TMP_ROOT/stdout"

  local prepared_path
  prepared_path="$(sed -n 's/^path=//p' "$TMP_ROOT/out/github-output")"
  test -f "$prepared_path/pnpm-lock.yaml" || fail "push preparation did not scan the requested path at GITHUB_SHA"
  assert_output_contains "scope=packages/web"
  test -z "$(find "$workspace" -mindepth 1 -maxdepth 1 -print -quit)" || fail "push preparation modified the caller workspace"

  ok "prepare repository fetches the push commit without a workspace checkout"
}

test_prepare_repository_skips_fork_pull_requests() {
  reset_tmp
  cat >"$TMP_ROOT/event.json" <<'JSON'
{
  "repository": {"id": 20002, "full_name": "acme/radar"},
  "pull_request": {
    "head": {"sha": "cccccccccccccccccccccccccccccccccccccccc", "repo": {"id": 30003, "full_name": "contributor/radar"}},
    "base": {"sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "repo": {"id": 20002, "full_name": "acme/radar"}}
  }
}
JSON

  GITHUB_EVENT_NAME="pull_request" \
    GITHUB_EVENT_PATH="$TMP_ROOT/event.json" \
    GITHUB_REPOSITORY="acme/radar" \
    RUNNER_TEMP="$TMP_ROOT/runner" \
    INPUT_PATH="." \
    run_with_outputs "$ROOT/src/prepare-repository.sh" >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr"

  assert_output_contains "skip=true"
  assert_output_contains "status=skipped"
  test ! -d "$TMP_ROOT/runner" || fail "fork PR preparation should not create a checkout"

  ok "prepare repository skips fork pull requests"
}

test_prepare_materializes_export_ignored_paths() {
  reset_tmp
  create_fixture_repository
  local workspace="$TMP_ROOT/empty-workspace"
  mkdir -p "$workspace"

  GITHUB_EVENT_NAME="push" \
    GITHUB_REPOSITORY="acme/radar" \
    GITHUB_SHA="$FIXTURE_HEAD_SHA" \
    GITHUB_WORKSPACE="$workspace" \
    RUNNER_TEMP="$TMP_ROOT/runner" \
    INPUT_PATH="." \
    run_with_outputs "$ROOT/src/prepare-repository.sh" \
      --repository-url "$FIXTURE_ORIGIN" \
      --skip-auth-for-test \
      >"$TMP_ROOT/stdout"

  local prepared_path
  prepared_path="$(sed -n 's/^path=//p' "$TMP_ROOT/out/github-output")"

  test -f "$prepared_path/vendored/yarn.lock" ||
    fail "preparation dropped a dependency file marked export-ignore in .gitattributes"
  test -f "$prepared_path/packages/web/pnpm-lock.yaml" ||
    fail "preparation omitted a tracked dependency file"

  ok "prepare repository materializes export-ignored dependency files"
}

test_prepare_does_not_fetch_pull_request_base() {
  reset_tmp
  create_fixture_repository
  local missing_base="dddddddddddddddddddddddddddddddddddddddd"

  cat >"$TMP_ROOT/event.json" <<JSON
{
  "repository": {"id": 20002, "full_name": "acme/radar", "default_branch": "main"},
  "pull_request": {
    "number": 42,
    "head": {"sha": "$FIXTURE_HEAD_SHA", "repo": {"id": 20002, "full_name": "acme/radar"}},
    "base": {"sha": "$missing_base", "repo": {"id": 20002, "full_name": "acme/radar"}}
  }
}
JSON

  GITHUB_EVENT_NAME="pull_request" \
    GITHUB_EVENT_PATH="$TMP_ROOT/event.json" \
    GITHUB_REPOSITORY="acme/radar" \
    GITHUB_SHA="$FIXTURE_MERGE_SHA" \
    RUNNER_TEMP="$TMP_ROOT/runner" \
    INPUT_PATH="." \
    run_with_outputs "$ROOT/src/prepare-repository.sh" \
      --repository-url "$FIXTURE_ORIGIN" \
      --skip-auth-for-test \
      >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr"

  assert_output_contains "skip=false"

  local prepared_path prepared_git_dir
  prepared_path="$(sed -n 's/^path=//p' "$TMP_ROOT/out/github-output")"
  prepared_git_dir="$(sed -n 's/^git-dir=//p' "$TMP_ROOT/out/github-output")"

  test -f "$prepared_path/package.json" ||
    fail "the attested pull request revision was not materialized"
  if git --git-dir="$prepared_git_dir" rev-parse --verify --quiet refs/stackradar/base >/dev/null; then
    fail "an unreachable base commit should leave no base ref"
  fi

  ok "prepare repository does not fetch pull request base code"
}

test_prepare_fail_on_error_false_suppresses_fetch_failure() {
  reset_tmp
  create_fixture_repository
  local missing_head="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

  if GITHUB_EVENT_NAME="push" \
    GITHUB_REPOSITORY="acme/radar" \
    GITHUB_SHA="$missing_head" \
    RUNNER_TEMP="$TMP_ROOT/runner" \
    INPUT_PATH="." \
    INPUT_FAIL_ON_ERROR="true" \
    run_with_outputs "$ROOT/src/prepare-repository.sh" \
      --repository-url "$FIXTURE_ORIGIN" \
      --skip-auth-for-test \
      >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr"; then
    fail "an unfetchable analyzed commit should fail when fail-on-error is true"
  fi

  GITHUB_EVENT_NAME="push" \
    GITHUB_REPOSITORY="acme/radar" \
    GITHUB_SHA="$missing_head" \
    RUNNER_TEMP="$TMP_ROOT/runner" \
    INPUT_PATH="." \
    INPUT_FAIL_ON_ERROR="false" \
    run_with_outputs "$ROOT/src/prepare-repository.sh" \
      --repository-url "$FIXTURE_ORIGIN" \
      --skip-auth-for-test \
      >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr" ||
    fail "fail-on-error false should suppress an unfetchable analyzed commit"

  assert_output_contains "skip=true"
  assert_output_contains "status=prepare-failed"
  test -z "$(find "$TMP_ROOT/runner" -mindepth 1 -maxdepth 1 -print -quit)" ||
    fail "a failed preparation left its partial checkout behind"

  ok "prepare repository honors fail-on-error for fetch failures"
}

test_cleanup_rejects_unexpected_path() {
  reset_tmp
  printf '%s\n' "keep" >"$TMP_ROOT/work/sentinel.txt"

  if RUNNER_TEMP="$TMP_ROOT/runner" \
    STACKRADAR_CHECKOUT_ROOT="$TMP_ROOT/work" \
    "$ROOT/src/cleanup-repository.sh" >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr"; then
    fail "cleanup should reject a path outside its temporary checkout pattern"
  fi

  test -f "$TMP_ROOT/work/sentinel.txt" || fail "cleanup removed an unexpected path"
  grep -Fq "Refusing to clean an unexpected repository checkout path" "$TMP_ROOT/stderr" || fail "unsafe cleanup rejection was unclear"

  ok "cleanup rejects unexpected paths"
}

test_cleanup_rejects_traversal_out_of_runner_temp() {
  reset_tmp
  mkdir -p "$TMP_ROOT/runner/stackradar-source.abc123"
  printf '%s\n' "keep" >"$TMP_ROOT/work/sentinel.txt"

  if RUNNER_TEMP="$TMP_ROOT/runner" \
    STACKRADAR_CHECKOUT_ROOT="$TMP_ROOT/runner/stackradar-source.abc123/../../work" \
    "$ROOT/src/cleanup-repository.sh" >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr"; then
    fail "cleanup should reject a checkout path that traverses out of RUNNER_TEMP"
  fi

  test -f "$TMP_ROOT/work/sentinel.txt" || fail "cleanup followed .. out of RUNNER_TEMP and removed an unrelated path"
  grep -Fq "Refusing to clean an unexpected repository checkout path" "$TMP_ROOT/stderr" || fail "unsafe cleanup rejection was unclear"

  ok "cleanup rejects traversal out of RUNNER_TEMP"
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

test_default_branch_run_attaches_inventory_collection() {
  reset_tmp
  write_fake_cli

  cat >"$TMP_ROOT/bin/unzip" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '{"files":[{"path":"packages/web/pnpm-lock.yaml"}]}'
SH
  chmod +x "$TMP_ROOT/bin/unzip"

  PATH="$TMP_ROOT/bin:$PATH" \
    FAKE_CLI_LOG="$TMP_ROOT/cli.log" \
    STACKRADAR_CLI_PATH="$TMP_ROOT/bin/stackradar" \
    STACKRADAR_REPOSITORY_ROOT="$TMP_ROOT/work" \
    STACKRADAR_SCAN_SCOPE="packages/web" \
    STACKRADAR_OIDC_TOKEN="oidc-token" \
    GITHUB_EVENT_NAME="push" \
    INPUT_MODE="bundle-and-upload" \
    INPUT_PATH="$TMP_ROOT/work" \
    INPUT_API_URL="https://stackradar.com" \
    INPUT_BUNDLE_PATH="$TMP_ROOT/work/stackradar.zip" \
    INPUT_DRY_RUN="false" \
    INPUT_FAIL_ON_ERROR="true" \
    INPUT_TOKEN="" \
    INPUT_EXCLUDE="" \
    run_with_outputs "$ROOT/src/run-stackradar.sh" >"$TMP_ROOT/stdout"

  local context_path
  context_path="$(awk '{for (i = 1; i <= NF; i++) if ($i == "--context-file") { print $(i + 1); exit }}' "$TMP_ROOT/cli.log")"
  test "$(jq -r '.purpose' "$context_path")" = "inventory" || fail "default-branch upload purpose was not inventory"
  test "$(jq -r '.collection.scope' "$context_path")" = "packages/web" || fail "default-branch collection scope was not attached"
  test "$(jq -r '.collection.expected_paths[0]' "$context_path")" = "packages/web/pnpm-lock.yaml" || fail "default-branch evidence paths were not attached"
  ok "default branch run attaches complete inventory collection"
}

test_pull_request_run_attaches_exact_head_context() {
  reset_tmp
  write_fake_cli

  cat >"$TMP_ROOT/bin/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == *"cat-file commit"* ]]; then
  printf '%s\n' \
    'tree aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    'parent bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
    'parent cccccccccccccccccccccccccccccccccccccccc' \
    '' \
    'Merge pull request #42'
  exit 0
fi

printf 'M\0package-lock.json\0R100\0package-old.json\0package.json\0'
SH
  chmod +x "$TMP_ROOT/bin/git"

  cat >"$TMP_ROOT/bin/unzip" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '{"files":[{"path":"package-lock.json"},{"path":"package.json"}]}'
SH
  chmod +x "$TMP_ROOT/bin/unzip"

  cat >"$TMP_ROOT/event.json" <<'JSON'
{
  "repository": {"default_branch": "main"},
  "pull_request": {
    "number": 42,
    "html_url": "https://github.com/acme/radar/pull/42",
    "head": {"sha": "cccccccccccccccccccccccccccccccccccccccc", "ref": "deps", "repo": {"id": 20002}},
    "base": {"sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "ref": "main"}
  }
}
JSON

  local merge_sha expected_object_base64
  merge_sha="$("$TMP_ROOT/bin/git" --git-dir="$TMP_ROOT/repository.git" cat-file commit ignored | git hash-object -t commit --stdin)"
  expected_object_base64="$("$TMP_ROOT/bin/git" --git-dir="$TMP_ROOT/repository.git" cat-file commit ignored | base64 | tr -d '\r\n')"

  PATH="$TMP_ROOT/bin:$PATH" \
    FAKE_CLI_LOG="$TMP_ROOT/cli.log" \
    FAKE_BUNDLE_EMPTY="1" \
    STACKRADAR_CLI_PATH="$TMP_ROOT/bin/stackradar" \
    STACKRADAR_GIT_DIR="$TMP_ROOT/repository.git" \
    STACKRADAR_SCAN_SCOPE="." \
    STACKRADAR_OIDC_TOKEN="oidc-token" \
    GITHUB_EVENT_NAME="pull_request" \
    GITHUB_EVENT_PATH="$TMP_ROOT/event.json" \
    GITHUB_SHA="$merge_sha" \
    INPUT_MODE="bundle-and-upload" \
    INPUT_PATH="$TMP_ROOT/work" \
    INPUT_API_URL="https://stackradar.com" \
    INPUT_BUNDLE_PATH="$TMP_ROOT/work/stackradar.zip" \
    INPUT_DRY_RUN="false" \
    INPUT_FAIL_ON_ERROR="true" \
    INPUT_TOKEN="" \
    INPUT_EXCLUDE="" \
    run_with_outputs "$ROOT/src/run-stackradar.sh" >"$TMP_ROOT/stdout"

  grep -Fq -- "bundle --path $TMP_ROOT/work --output $TMP_ROOT/work/stackradar.zip" "$TMP_ROOT/cli.log" || fail "PR bundle was not attempted with released CLI arguments"
  grep -Fq -- "bundle --path $TMP_ROOT/work --output $TMP_ROOT/work/stackradar.zip --allow-empty" "$TMP_ROOT/cli.log" || fail "PR bundle did not retry for deletion-only evidence"
  context_path="$(awk '{for (i = 1; i <= NF; i++) if ($i == "--context-file") { print $(i + 1); exit }}' "$TMP_ROOT/cli.log")"
  test -f "$context_path" || fail "PR upload context file was not created"
  test "$(jq -r '.purpose' "$context_path")" = "pull_request" || fail "PR upload purpose was not set"
  test "$(jq -r '.pull_request.head_sha' "$context_path")" = "$merge_sha" || fail "PR merge SHA was not bound"
  test "$(jq -r '.pull_request.merge_commit.object_base64' "$context_path")" = "$expected_object_base64" || fail "PR merge commit proof did not match GITHUB_SHA"
  test "$(jq -r '.pull_request.changes | length' "$context_path")" = "0" || fail "untrusted changed paths were attached"
  test "$(jq -r '.pull_request.collection.expected_paths | length' "$context_path")" = "2" || fail "evidence coverage was not recorded"
  test "$(jq -r '.pull_request.collection.scope' "$context_path")" = "." || fail "repository scan scope was not recorded"
  test "$(jq -r '.collection.expected_paths | length' "$context_path")" = "2" || fail "top-level collection contract was not attached"
  ok "pull request run attaches attested merge and collection context"
}

test_real_cli_preserves_scoped_repository_contract() {
  reset_tmp
  create_fixture_repository
  local cli_path="${STACKRADAR_REAL_CLI_PATH:?STACKRADAR_REAL_CLI_PATH is required for the cross-repository contract test}"

  cat >"$TMP_ROOT/event.json" <<JSON
{
  "repository": {"id": 20002, "full_name": "acme/radar", "default_branch": "main"},
  "pull_request": {
    "number": 42,
    "head": {"sha": "$FIXTURE_HEAD_SHA", "repo": {"id": 20002, "full_name": "acme/radar"}},
    "base": {"sha": "$FIXTURE_BASE_SHA", "repo": {"id": 20002, "full_name": "acme/radar"}}
  }
}
JSON

  GITHUB_EVENT_NAME="pull_request" \
    GITHUB_EVENT_PATH="$TMP_ROOT/event.json" \
    GITHUB_REPOSITORY="acme/radar" \
    GITHUB_SHA="$FIXTURE_MERGE_SHA" \
    RUNNER_TEMP="$TMP_ROOT/runner" \
    INPUT_PATH="packages/web" \
    run_with_outputs "$ROOT/src/prepare-repository.sh" \
      --repository-url "$FIXTURE_ORIGIN" \
      --skip-auth-for-test \
      >"$TMP_ROOT/stdout"

  local prepared_path repository_root git_dir scope bundle_path
  prepared_path="$(sed -n 's/^path=//p' "$TMP_ROOT/out/github-output")"
  repository_root="$(sed -n 's/^repository-root=//p' "$TMP_ROOT/out/github-output")"
  git_dir="$(sed -n 's/^git-dir=//p' "$TMP_ROOT/out/github-output")"
  scope="$(sed -n 's/^scope=//p' "$TMP_ROOT/out/github-output")"
  bundle_path="$TMP_ROOT/work/scoped.zip"

  STACKRADAR_CLI_PATH="$cli_path" \
    STACKRADAR_GIT_DIR="$git_dir" \
    STACKRADAR_REPOSITORY_ROOT="$repository_root" \
    STACKRADAR_SCAN_SCOPE="$scope" \
    GITHUB_EVENT_NAME="pull_request" \
    GITHUB_EVENT_PATH="$TMP_ROOT/event.json" \
    INPUT_MODE="bundle" \
    INPUT_PATH="$prepared_path" \
    INPUT_BUNDLE_PATH="$bundle_path" \
    INPUT_FAIL_ON_ERROR="true" \
    INPUT_EXCLUDE="" \
    run_with_outputs "$ROOT/src/run-stackradar.sh" >"$TMP_ROOT/stdout"

  test "$(unzip -p "$bundle_path" stackradar-manifest.json | jq -r '.git.commit_sha')" = "$FIXTURE_MERGE_SHA" ||
    fail "real CLI bundle did not carry the prepared merge commit"
  test "$(unzip -p "$bundle_path" stackradar-manifest.json | jq -r '.files[0].path')" = "packages/web/pnpm-lock.yaml" ||
    fail "real CLI bundle did not use a repository-relative scoped path"
  unzip -Z1 "$bundle_path" | grep -Fxq "packages/web/pnpm-lock.yaml" ||
    fail "real CLI zip entry did not use the canonical repository path"

  ok "real CLI and action preserve the scoped repository contract"
}

test_real_cli_bundles_deletion_only_pull_request() {
  reset_tmp
  create_deletion_only_fixture_repository
  local cli_path="${STACKRADAR_REAL_CLI_PATH:?STACKRADAR_REAL_CLI_PATH is required for the cross-repository contract test}"

  cat >"$TMP_ROOT/event.json" <<JSON
{
  "repository": {"id": 20002, "full_name": "acme/radar", "default_branch": "main"},
  "pull_request": {
    "number": 42,
    "head": {"sha": "$FIXTURE_HEAD_SHA", "repo": {"id": 20002, "full_name": "acme/radar"}},
    "base": {"sha": "$FIXTURE_BASE_SHA", "repo": {"id": 20002, "full_name": "acme/radar"}}
  }
}
JSON

  GITHUB_EVENT_NAME="pull_request" \
    GITHUB_EVENT_PATH="$TMP_ROOT/event.json" \
    GITHUB_REPOSITORY="acme/radar" \
    GITHUB_SHA="$FIXTURE_MERGE_SHA" \
    RUNNER_TEMP="$TMP_ROOT/runner" \
    INPUT_PATH="." \
    run_with_outputs "$ROOT/src/prepare-repository.sh" \
      --repository-url "$FIXTURE_ORIGIN" \
      --skip-auth-for-test \
      >"$TMP_ROOT/stdout"

  local prepared_path repository_root git_dir bundle_path
  prepared_path="$(sed -n 's/^path=//p' "$TMP_ROOT/out/github-output")"
  repository_root="$(sed -n 's/^repository-root=//p' "$TMP_ROOT/out/github-output")"
  git_dir="$(sed -n 's/^git-dir=//p' "$TMP_ROOT/out/github-output")"
  bundle_path="$TMP_ROOT/work/deletion-only.zip"

  STACKRADAR_CLI_PATH="$cli_path" \
    STACKRADAR_GIT_DIR="$git_dir" \
    STACKRADAR_REPOSITORY_ROOT="$repository_root" \
    STACKRADAR_SCAN_SCOPE="." \
    GITHUB_EVENT_NAME="pull_request" \
    GITHUB_EVENT_PATH="$TMP_ROOT/event.json" \
    INPUT_MODE="bundle" \
    INPUT_PATH="$prepared_path" \
    INPUT_BUNDLE_PATH="$bundle_path" \
    INPUT_FAIL_ON_ERROR="true" \
    INPUT_EXCLUDE="" \
    run_with_outputs "$ROOT/src/run-stackradar.sh" >"$TMP_ROOT/stdout"

  test "$(unzip -p "$bundle_path" stackradar-manifest.json | jq -r '.git.commit_sha')" = "$FIXTURE_MERGE_SHA" ||
    fail "deletion-only bundle did not carry the PR merge commit"
  test "$(unzip -p "$bundle_path" stackradar-manifest.json | jq -r '.files | length')" = "0" ||
    fail "deletion-only bundle should contain no dependency files"

  ok "real CLI and action bundle deletion-only pull requests"
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

test_fail_on_error_false_suppresses_pull_request_context_failure() {
  reset_tmp
  write_fake_cli
  printf "bundle-bytes" >"$TMP_ROOT/work/stackradar.zip"

  cat >"$TMP_ROOT/bin/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
exit 0
SH
  chmod +x "$TMP_ROOT/bin/git"

  cat >"$TMP_ROOT/bin/unzip" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
exit 9
SH
  chmod +x "$TMP_ROOT/bin/unzip"

  cat >"$TMP_ROOT/event.json" <<'JSON'
{
  "repository": {"default_branch": "main"},
  "pull_request": {
    "number": 42,
    "html_url": "https://github.com/acme/radar/pull/42",
    "head": {"sha": "cccccccccccccccccccccccccccccccccccccccc", "ref": "deps", "repo": {"id": 20002}},
    "base": {"sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "ref": "main"}
  }
}
JSON

  PATH="$TMP_ROOT/bin:$PATH" \
    FAKE_CLI_LOG="$TMP_ROOT/cli.log" \
    STACKRADAR_CLI_PATH="$TMP_ROOT/bin/stackradar" \
    STACKRADAR_OIDC_TOKEN="oidc-token" \
    GITHUB_EVENT_NAME="pull_request" \
    GITHUB_EVENT_PATH="$TMP_ROOT/event.json" \
    INPUT_MODE="upload" \
    INPUT_PATH="$TMP_ROOT/work" \
    INPUT_API_URL="https://stackradar.com" \
    INPUT_BUNDLE_PATH="$TMP_ROOT/work/stackradar.zip" \
    INPUT_DRY_RUN="false" \
    INPUT_FAIL_ON_ERROR="false" \
    INPUT_TOKEN="" \
    INPUT_EXCLUDE="" \
    run_with_outputs "$ROOT/src/run-stackradar.sh" >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr"

  grep -Fq "::warning::StackRadar could not collect upload context." "$TMP_ROOT/stderr" || fail "context failure was not downgraded to a warning"
  assert_output_contains "status=context-failed"
  if [ -f "$TMP_ROOT/cli.log" ] && grep -Fq "upload" "$TMP_ROOT/cli.log"; then
    fail "context failure should not continue to upload"
  fi
  ok "fail-on-error false suppresses pull request context failure"
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
test_prepare_pull_request_uses_isolated_exact_head
test_prepare_push_uses_event_commit_without_workspace_checkout
test_prepare_repository_skips_fork_pull_requests
test_prepare_materializes_export_ignored_paths
test_prepare_does_not_fetch_pull_request_base
test_prepare_fail_on_error_false_suppresses_fetch_failure
test_cleanup_rejects_unexpected_path
test_cleanup_rejects_traversal_out_of_runner_temp
test_request_oidc_masks_token
test_run_bundle_mode_does_not_upload
test_run_upload_mode_uses_oidc_token_and_masks_it
test_run_upload_mode_uses_input_token_without_cli_argument
test_default_branch_run_attaches_inventory_collection
test_pull_request_run_attaches_exact_head_context
test_real_cli_preserves_scoped_repository_contract
test_real_cli_bundles_deletion_only_pull_request
test_run_dry_run_calls_cli_upload_dry_run_without_token
test_fail_on_error_false_suppresses_upload_failure
test_fail_on_error_false_suppresses_bundle_failure
test_fail_on_error_false_suppresses_pull_request_context_failure
test_install_maps_platform_and_outputs_cli_version
test_install_rejects_ambient_trust_overrides

echo "$pass_count tests passed"
