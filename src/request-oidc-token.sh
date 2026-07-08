#!/usr/bin/env bash
set -euo pipefail

ACTION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/lib.sh
source "$ACTION_DIR/lib.sh"

audience="${INPUT_OIDC_AUDIENCE:-stackradar.com}"
request_url="${ACTIONS_ID_TOKEN_REQUEST_URL:-}"
request_token="${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}"

require_value "oidc-audience" "$audience"

if [ -z "$request_url" ] || [ -z "$request_token" ]; then
  die "Unable to request a GitHub Actions OIDC token. Add permissions: id-token: write, or provide token for non-standard testing."
fi

response="$(
  curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --proto '=https' \
    --tlsv1.2 \
    --retry 3 \
    --max-time 300 \
    -H "Authorization: bearer $request_token" \
    --get \
    --data-urlencode "audience=$audience" \
    "$request_url"
)"

require_command jq
token="$(printf '%s\n' "$response" | jq -r '.value // empty')"

if [ -z "$token" ] || [ "$token" = "null" ]; then
  die "GitHub OIDC response did not include a token value."
fi

mask_secret "$token"
write_output "token" "$token"
