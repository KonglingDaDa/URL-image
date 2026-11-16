# image-curl: shared bash helpers for the thin entry scripts.
# All behaviour lives in lib/image_curl.py; these scripts only find Python 3.8+.
# Keep Bash 3.2 compatible (macOS /bin/bash): no local -n, mapfile, ${var,,}.

image_curl_python() {
  local candidate
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 \
      && "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  printf '错误：未找到 Python 3.8+。请安装 Python 3，并确保 python3 在 PATH 中。\n' >&2
  return 1
}

# Usage: image_curl_exec SUBCOMMAND [ARGS...]
image_curl_exec() {
  local lib_dir python_bin
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
  python_bin="$(image_curl_python)" || exit 1
  exec "$python_bin" "$lib_dir/image_curl.py" ${1+"$@"}
}
