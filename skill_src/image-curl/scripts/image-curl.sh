#!/usr/bin/env bash
# Unified entry: generate | edit | generate-batch | models | help (see lib/image_curl.py).
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$script_dir/common.sh"
image_curl_exec ${1+"$@"}
