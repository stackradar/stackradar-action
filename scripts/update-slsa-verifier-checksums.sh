#!/usr/bin/env bash
set -euo pipefail

file="src/install-slsa-verifier.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required." >&2
  exit 1
fi

version="$(awk -F'"' '/^version=/ { print $2; exit }' "$file")"
if [[ ! "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Could not read a stable slsa-verifier version from $file." >&2
  exit 1
fi

release_json="$(
  curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --proto '=https' \
    --tlsv1.2 \
    --retry 3 \
    --max-time 300 \
    "https://api.github.com/repos/slsa-framework/slsa-verifier/releases/tags/$version"
)"

asset_digest() {
  local asset="$1"
  local digest

  digest="$(jq --raw-output --arg asset "$asset" '.assets[] | select(.name == $asset) | .digest // empty' <<< "$release_json")"
  digest="${digest#sha256:}"

  if [[ ! "$digest" =~ ^[a-f0-9]{64}$ ]]; then
    echo "Could not find SHA-256 digest for $asset in slsa-verifier $version." >&2
    exit 1
  fi

  printf '%s\n' "$digest"
}

darwin_amd64="$(asset_digest "slsa-verifier-darwin-amd64")"
darwin_arm64="$(asset_digest "slsa-verifier-darwin-arm64")"
linux_amd64="$(asset_digest "slsa-verifier-linux-amd64")"
linux_arm64="$(asset_digest "slsa-verifier-linux-arm64")"
windows_amd64="$(asset_digest "slsa-verifier-windows-amd64.exe")"
windows_arm64="$(asset_digest "slsa-verifier-windows-arm64.exe")"

tmp="$(mktemp)"
awk \
  -v darwin_amd64="$darwin_amd64" \
  -v darwin_arm64="$darwin_arm64" \
  -v linux_amd64="$linux_amd64" \
  -v linux_arm64="$linux_arm64" \
  -v windows_amd64="$windows_amd64" \
  -v windows_arm64="$windows_arm64" \
  '
  /slsa-verifier-darwin-amd64\)/ {
    print
    getline
    sub(/expected_sha256="[a-f0-9]+"/, "expected_sha256=\"" darwin_amd64 "\"")
    print
    next
  }
  /slsa-verifier-darwin-arm64\)/ {
    print
    getline
    sub(/expected_sha256="[a-f0-9]+"/, "expected_sha256=\"" darwin_arm64 "\"")
    print
    next
  }
  /slsa-verifier-linux-amd64\)/ {
    print
    getline
    sub(/expected_sha256="[a-f0-9]+"/, "expected_sha256=\"" linux_amd64 "\"")
    print
    next
  }
  /slsa-verifier-linux-arm64\)/ {
    print
    getline
    sub(/expected_sha256="[a-f0-9]+"/, "expected_sha256=\"" linux_arm64 "\"")
    print
    next
  }
  /slsa-verifier-windows-amd64\.exe\)/ {
    print
    getline
    sub(/expected_sha256="[a-f0-9]+"/, "expected_sha256=\"" windows_amd64 "\"")
    print
    next
  }
  /slsa-verifier-windows-arm64\.exe\)/ {
    print
    getline
    sub(/expected_sha256="[a-f0-9]+"/, "expected_sha256=\"" windows_arm64 "\"")
    print
    next
  }
  { print }
  ' "$file" > "$tmp"

mv "$tmp" "$file"
