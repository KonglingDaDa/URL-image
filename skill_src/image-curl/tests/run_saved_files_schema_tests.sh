#!/usr/bin/env bash
# saved_files / saved_file result JSON uses canonical "file" field (Bash + PS parity).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill_root="$(cd "$script_dir/.." && pwd)"
# shellcheck source=../scripts/common.sh
source "$skill_root/scripts/common.sh"

failures=0
total=0

assert_test() {
  local name="$1"
  shift
  total=$((total + 1))
  if "$@"; then
    printf 'OK   %s\n' "$name"
  else
    failures=$((failures + 1))
    printf 'FAIL %s\n' "$name" >&2
  fi
}

test_extract_paths_file_field() {
  local result paths
  result='{"saved_files":[{"file":"/tmp/a.png","bytes":1},{"file":"/tmp/b.png","bytes":2}]}'
  read_lines_into_array paths extract_saved_paths_from_result "$result"
  [[ "${#paths[@]}" == "2" && "${paths[0]}" == "/tmp/a.png" && "${paths[1]}" == "/tmp/b.png" ]]
}

test_extract_paths_legacy_path_field() {
  local result paths
  result='{"saved_files":[{"path":"/tmp/legacy.png","bytes":1}]}'
  read_lines_into_array paths extract_saved_paths_from_result "$result"
  [[ "${#paths[@]}" == "1" && "${paths[0]}" == "/tmp/legacy.png" ]]
}

test_extract_paths_saved_file_scalar() {
  local result paths
  result='{"saved_file":"/tmp/single.png","bytes":99}'
  read_lines_into_array paths extract_saved_paths_from_result "$result"
  [[ "${#paths[@]}" == "1" && "${paths[0]}" == "/tmp/single.png" ]]
}

test_save_image_response_uses_file_field() {
  local response_file output_file result
  response_file="$(mktemp "${TMPDIR:-/tmp}/image-curl-schema-resp.XXXXXX.json")"
  output_file="$(mktemp "${TMPDIR:-/tmp}/image-curl-schema-out.XXXXXX.png")"
  python3 - "$response_file" <<'PY'
import base64
import json
import sys
from pathlib import Path

png = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
)
payload = {"data": [{"b64_json": base64.b64encode(png).decode("ascii")}]}
Path(sys.argv[1]).write_text(json.dumps(payload), encoding="utf-8")
PY
  result="$(save_image_response "$response_file" "$output_file" "" "png" "1")"
  rm -f "$response_file"
  python3 -c 'import json,sys
data=json.loads(sys.argv[1])
assert "saved_file" in data
assert "path" not in data.get("saved_files", [{}])[0] if isinstance(data.get("saved_files"), list) else True
if isinstance(data.get("saved_files"), list) and data["saved_files"]:
    assert data["saved_files"][0].get("file")
' "$result"
  rm -f "$output_file"
}

test_save_image_response_accepts_url() {
  local response_file output_file png_file result
  response_file="$(mktemp "${TMPDIR:-/tmp}/image-curl-schema-url-resp.XXXXXX.json")"
  output_file="$(mktemp "${TMPDIR:-/tmp}/image-curl-schema-url-out.XXXXXX.png")"
  png_file="$(mktemp "${TMPDIR:-/tmp}/image-curl-schema-url-src.XXXXXX.png")"
  python3 - "$png_file" "$response_file" <<'PY'
import base64
import json
import sys
from pathlib import Path

png = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
)
src = Path(sys.argv[1])
src.write_bytes(png)
# data: URL exercises the url branch without needing a network server.
payload = {
    "data": [
        {
            "url": "data:image/png;base64,"
            + base64.b64encode(png).decode("ascii")
        }
    ]
}
Path(sys.argv[2]).write_text(json.dumps(payload), encoding="utf-8")
PY
  result="$(save_image_response "$response_file" "$output_file" "" "png" "1")"
  rm -f "$response_file" "$png_file"
  python3 -c 'import json,sys
from pathlib import Path
data=json.loads(sys.argv[1])
out=Path(sys.argv[2])
assert "saved_file" in data
assert out.is_file() and out.stat().st_size > 0
assert data["bytes"] == out.stat().st_size
' "$result" "$output_file"
  rm -f "$output_file"
}

test_save_image_response_url_missing_fields_message() {
  local response_file output_file
  response_file="$(mktemp "${TMPDIR:-/tmp}/image-curl-schema-empty-resp.XXXXXX.json")"
  output_file="$(mktemp "${TMPDIR:-/tmp}/image-curl-schema-empty-out.XXXXXX.png")"
  printf '%s\n' '{"data":[{"revised_prompt":"x"}]}' >"$response_file"
  if save_image_response "$response_file" "$output_file" "" "png" "1" 2>/tmp/image-curl-schema-empty.err; then
    rm -f "$response_file" "$output_file" /tmp/image-curl-schema-empty.err
    return 1
  fi
  grep -q 'b64_json' /tmp/image-curl-schema-empty.err
  grep -q 'url' /tmp/image-curl-schema-empty.err
  rm -f "$response_file" "$output_file" /tmp/image-curl-schema-empty.err
}

assert_test 'extract_saved_paths_from_result reads file field' test_extract_paths_file_field
assert_test 'extract_saved_paths_from_result accepts legacy path field' test_extract_paths_legacy_path_field
assert_test 'extract_saved_paths_from_result reads saved_file scalar' test_extract_paths_saved_file_scalar
assert_test 'save_image_response emits file field not path' test_save_image_response_uses_file_field
assert_test 'save_image_response accepts data[].url (data URL)' test_save_image_response_accepts_url
assert_test 'save_image_response missing fields mentions b64_json and url' test_save_image_response_url_missing_fields_message

if ((failures > 0)); then
  printf '\n%d/%d saved_files schema tests failed.\n' "$failures" "$total" >&2
  exit 1
fi

printf '\nAll %d saved_files schema tests passed.\n' "$total"