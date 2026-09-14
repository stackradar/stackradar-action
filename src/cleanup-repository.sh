#!/usr/bin/env bash
set -euo pipefail

ACTION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/lib.sh
source "$ACTION_DIR/lib.sh"

checkout_root="$(to_posix_path "${STACKRADAR_CHECKOUT_ROOT:-}")"
runner_temp="$(to_posix_path "${RUNNER_TEMP:-${TMPDIR:-/tmp}}")"
runner_temp="${runner_temp%/}"

if [ -z "$checkout_root" ]; then
  exit 0
fi

# Anchor the whole path: a trailing glob would let "stackradar-source.XXXXXX/../.."
# walk out of RUNNER_TEMP. The suffix is the mktemp template, which is replaced
# with exactly six alphanumeric characters.
if [[ ! "$checkout_root" =~ ^"$runner_temp"/stackradar-source\.[A-Za-z0-9]{6}$ ]]; then
  die "Refusing to clean an unexpected repository checkout path."
fi

rm -rf -- "$checkout_root"
