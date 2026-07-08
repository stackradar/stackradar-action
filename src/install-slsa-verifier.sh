#!/usr/bin/env bash
set -euo pipefail

ACTION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/lib.sh
source "$ACTION_DIR/lib.sh"

version="v2.7.1"
runner_temp="$(to_posix_path "${RUNNER_TEMP:-${TMPDIR:-/tmp}}")"
goos="$(map_runner_os "${RUNNER_OS:-}")"
goarch="$(map_runner_arch "${RUNNER_ARCH:-}")"

asset="slsa-verifier-${goos}-${goarch}"
if [ "$goos" = "windows" ]; then
  asset="${asset}.exe"
fi

case "$asset" in
  slsa-verifier-darwin-amd64)
    expected_sha256="4baf25415727821f847a38bccedc86c3e5b17cbfc2eb534cd554feb6c856d6f1"
    ;;
  slsa-verifier-darwin-arm64)
    expected_sha256="39abfcf5f1d690c3e889ce3d2d6a8b87711424d83368511868d414e8f8bcb05c"
    ;;
  slsa-verifier-linux-amd64)
    expected_sha256="946dbec729094195e88ef78e1734324a27869f03e2c6bd2f61cbc06bd5350339"
    ;;
  slsa-verifier-linux-arm64)
    expected_sha256="5d3b2349ede7bfec19e7a21569f18b9f7410145ad12e9584b175370669e14061"
    ;;
  slsa-verifier-windows-amd64.exe)
    expected_sha256="1d8f61ad747ecc3d375d2a563cebf2991748b7da1a9bda9a500804c3c499e3c0"
    ;;
  slsa-verifier-windows-arm64.exe)
    expected_sha256="44144e98328d221f0490ef6b4a58a465defe8f697f387abbbf07ef5adb68d4ac"
    ;;
  *)
    die "No pinned slsa-verifier checksum is available for $asset."
    ;;
esac

mkdir -p "$runner_temp"
install_dir="$(mktemp -d "$runner_temp/stackradar-slsa-verifier.XXXXXX")"
download_path="$install_dir/$asset"

download_file "https://github.com/slsa-framework/slsa-verifier/releases/download/$version/$asset" "$download_path"

actual_sha256="$(sha256_file "$download_path")"
if [ "$actual_sha256" != "$expected_sha256" ]; then
  die "slsa-verifier checksum verification failed for $asset."
fi

chmod +x "$download_path"

if [ "$goos" = "windows" ]; then
  cat >"$install_dir/slsa-verifier" <<SH
#!/usr/bin/env bash
exec "$download_path" "\$@"
SH
  chmod +x "$install_dir/slsa-verifier"
else
  mv "$download_path" "$install_dir/slsa-verifier"
fi

write_path "$install_dir"
