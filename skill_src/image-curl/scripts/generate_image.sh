#!/usr/bin/env bash
# Thin wrapper: see lib/image_curl.py (generate).
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$script_dir/common.sh"
image_curl_exec generate ${1+"$@"}
