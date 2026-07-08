#!/usr/bin/env bash

set -euo pipefail

die() {
  echo "::error::$*" >&2
  exit 1
}

warn() {
  echo "::warning::$*" >&2
}

require_value() {
  local name="$1"
  local value="$2"

  if [ -z "$value" ]; then
    die "$name is required."
  fi
}

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    die "$command_name is required but was not found on PATH."
  fi
}

write_output() {
  local name="$1"
  local value="$2"

  if [ -z "${GITHUB_OUTPUT:-}" ]; then
    return 0
  fi

  printf '%s=%s\n' "$name" "$value" >> "$GITHUB_OUTPUT"
}

write_path() {
  local path="$1"

  if [ -z "${GITHUB_PATH:-}" ]; then
    return 0
  fi

  printf '%s\n' "$path" >> "$GITHUB_PATH"
}

mask_secret() {
  local secret="$1"

  if [ -n "$secret" ]; then
    echo "::add-mask::$secret"
  fi
}

is_bool() {
  local value="$1"

  [ "$value" = "true" ] || [ "$value" = "false" ]
}

normalize_tag() {
  local raw_version="$1"

  require_value "cli-version" "$raw_version"

  if [ "$raw_version" = "latest" ]; then
    echo "latest"
    return 0
  fi

  if [[ "$raw_version" =~ ^v?[0-9]+[.][0-9]+[.][0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
    if [[ "$raw_version" == v* ]]; then
      echo "$raw_version"
    else
      echo "v$raw_version"
    fi
    return 0
  fi

  die "cli-version must be latest or a semantic version tag such as v0.1.0."
}

version_from_tag() {
  local tag="$1"

  echo "${tag#v}"
}

to_posix_path() {
  local path="$1"

  if command -v cygpath >/dev/null 2>&1; then
    cygpath -u "$path"
    return 0
  fi

  echo "$path"
}

map_runner_os() {
  case "${1:-}" in
    Linux)
      echo "linux"
      ;;
    macOS)
      echo "darwin"
      ;;
    Windows)
      echo "windows"
      ;;
    *)
      die "No StackRadar CLI archive is published for RUNNER_OS=${1:-unset}. Supported: Linux, macOS, Windows."
      ;;
  esac
}

map_runner_arch() {
  case "${1:-}" in
    X64)
      echo "amd64"
      ;;
    ARM64)
      echo "arm64"
      ;;
    *)
      die "No StackRadar CLI archive is published for RUNNER_ARCH=${1:-unset}. Supported: X64, ARM64."
      ;;
  esac
}

sha256_file() {
  local file="$1"

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
    return 0
  fi

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
    return 0
  fi

  die "shasum or sha256sum is required to compute SHA-256."
}

verify_checksum_line() {
  local checksums_file="$1"
  local artifact_path="$2"
  local artifact_name="$3"
  local expected
  local actual

  expected="$(awk -v name="$artifact_name" '$2 == name { print $1 }' "$checksums_file")"
  if [ -z "$expected" ]; then
    die "Checksum manifest does not contain $artifact_name."
  fi

  actual="$(sha256_file "$artifact_path")"
  if [ "$actual" != "$expected" ]; then
    die "Checksum verification failed for $artifact_name."
  fi
}

download_file() {
  local url="$1"
  local output="$2"

  require_command curl
  curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --proto '=https' \
    --tlsv1.2 \
    --retry 3 \
    --max-time 300 \
    "$url" \
    --output "$output"
}
