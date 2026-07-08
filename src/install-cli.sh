#!/usr/bin/env bash
set -euo pipefail

ACTION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/lib.sh
source "$ACTION_DIR/lib.sh"

repo="stackradar/stackradar-cli"
release_base_url=""
skip_cosign_verify_for_test="false"
raw_version="${INPUT_CLI_VERSION:-latest}"
verify="${INPUT_VERIFY:-strict}"
runner_os="${RUNNER_OS:-}"
runner_arch="${RUNNER_ARCH:-}"
runner_temp="$(to_posix_path "${RUNNER_TEMP:-${TMPDIR:-/tmp}}")"

reject_unsupported_env_override() {
  local name="$1"

  if [ -n "${!name:-}" ]; then
    die "Unsupported environment override $name is set. The StackRadar action does not allow overriding the trusted CLI release source."
  fi
}

reject_unsupported_env_override "STACKRADAR_CLI_REPOSITORY"
reject_unsupported_env_override "STACKRADAR_RELEASE_BASE_URL"
reject_unsupported_env_override "STACKRADAR_SKIP_COSIGN_VERIFY"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --release-base-url)
      shift
      require_value "--release-base-url" "${1:-}"
      release_base_url="$1"
      ;;
    --skip-cosign-verify-for-test)
      skip_cosign_verify_for_test="true"
      ;;
    *)
      die "Unknown install-cli argument: $1"
      ;;
  esac
  shift
done

if [ -z "$release_base_url" ]; then
  release_base_url="https://github.com/$repo/releases/download"
fi

tag="$(normalize_tag "$raw_version")"

if [ "$tag" = "latest" ]; then
  latest_url="$(
    curl \
      --fail \
      --silent \
      --show-error \
      --location \
      --head \
      --proto '=https' \
      --tlsv1.2 \
      --retry 3 \
      --max-time 300 \
      --output /dev/null \
      --write-out '%{url_effective}' \
      "https://github.com/$repo/releases/latest"
  )"
  tag="${latest_url##*/}"
  if [ -z "$tag" ] || [ "$tag" = "latest" ]; then
    die "Unable to resolve the latest StackRadar CLI release."
  fi
fi

version="$(version_from_tag "$tag")"
goos="$(map_runner_os "$runner_os")"
goarch="$(map_runner_arch "$runner_arch")"

archive="stackradar_${version}_${goos}_${goarch}.tar.gz"
if [ "$goos" = "windows" ]; then
  archive="stackradar_${version}_${goos}_${goarch}.zip"
fi

checksums="stackradar_${version}_checksums.txt"
checksum_bundle="${checksums}.sigstore.json"
sbom="${archive}.sbom.spdx.json"
provenance="stackradar_${version}_multiple.intoto.jsonl"

mkdir -p "$runner_temp"
work_root="$(mktemp -d "$runner_temp/stackradar-action.XXXXXX")"
work_dir="$work_root/download"
bin_dir="$work_root/bin"
mkdir -p "$work_dir" "$bin_dir"

download_file "$release_base_url/$tag/$archive" "$work_dir/$archive"

if [ "$verify" != "false" ]; then
  download_file "$release_base_url/$tag/$checksums" "$work_dir/$checksums"
  download_file "$release_base_url/$tag/$checksum_bundle" "$work_dir/$checksum_bundle"

  if [ "$skip_cosign_verify_for_test" != "true" ]; then
    require_command cosign
    cosign verify-blob "$work_dir/$checksums" \
      --bundle "$work_dir/$checksum_bundle" \
      --certificate-identity "https://github.com/$repo/.github/workflows/release.yml@refs/tags/$tag" \
      --certificate-oidc-issuer "https://token.actions.githubusercontent.com"
  fi

  verify_checksum_line "$work_dir/$checksums" "$work_dir/$archive" "$archive"
fi

if [ "$verify" = "strict" ]; then
  download_file "$release_base_url/$tag/$sbom" "$work_dir/$sbom"
  download_file "$release_base_url/$tag/$provenance" "$work_dir/$provenance"
  verify_checksum_line "$work_dir/$checksums" "$work_dir/$sbom" "$sbom"

  require_command gh
  require_command slsa-verifier

  gh attestation verify "$work_dir/$archive" \
    --repo "$repo" \
    --signer-workflow "$repo/.github/workflows/release.yml" \
    --source-ref "refs/tags/$tag"

  gh attestation verify "$work_dir/$sbom" \
    --repo "$repo" \
    --signer-workflow "$repo/.github/workflows/release.yml" \
    --source-ref "refs/tags/$tag"

  slsa-verifier verify-artifact "$work_dir/$archive" "$work_dir/$sbom" \
    --provenance-path "$work_dir/$provenance" \
    --source-uri "github.com/$repo" \
    --source-tag "$tag"
fi

if [ "$goos" = "windows" ]; then
  require_command unzip
  unzip -q -o "$work_dir/$archive" -d "$bin_dir"
  cli_path="$bin_dir/stackradar.exe"
else
  require_command tar
  tar -xzf "$work_dir/$archive" -C "$bin_dir"
  cli_path="$bin_dir/stackradar"
  chmod +x "$cli_path"
fi

if [ ! -x "$cli_path" ]; then
  die "Downloaded StackRadar CLI archive did not contain an executable stackradar binary."
fi

"$cli_path" version

write_output "cli-version" "$version"
write_output "cli-path" "$cli_path"
