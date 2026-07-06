#!/usr/bin/env bash
# Acceptance: edit_image.sh --dry-run with local --image (no --image-set) and last-output fixture.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill_root="$(cd "$script_dir/.." && pwd)"
# shellcheck source=../scripts/common.sh
source "${skill_root}/scripts/common.sh"
edit_script="${skill_root}/scripts/edit_image.sh"

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

saved_key="${IMAGE_CURL_API_KEY-}"
unset IMAGE_CURL_API_KEY OPENAI_API_KEY CLIPROXY_API_KEY 2>/dev/null || true

cleanup() {
  if [[ -n "${saved_key:-}" ]]; then
    export IMAGE_CURL_API_KEY="$saved_key"
  fi
}
trap cleanup EXIT

test_edit_local_image_dry_run() {
  local img out
  img="$(mktemp "${TMPDIR:-/tmp}/edit-dry-local.XXXXXX.png")"
  python3 -c 'import base64,sys; sys.stdout.buffer.write(base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))' >"$img"
  out="$("$edit_script" --image "$img" --prompt 'install check' --name dry-local --dry-run 2>&1)" || {
    rm -f "$img"
    return 1
  }
  rm -f "$img"
  python3 -c 'import json,sys; data=json.loads(sys.argv[1]); imgs=data.get("multipart",{}).get("image[]",[]); sys.exit(0 if imgs else 1)' "$out"
}

test_edit_last_output_fixture() {
  local codex_home thread_dir first out
  codex_home="$(mktemp -d "${TMPDIR:-/tmp}/image-curl-edit-dry.XXXXXX")"
  thread_dir="${codex_home}/generated_images/manual"
  mkdir -p "$thread_dir"
  first="${thread_dir}/first-out.png"
  python3 -c 'import base64,sys; sys.stdout.buffer.write(base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))' >"$first"
  python3 - "$first" <<'PY' >"${thread_dir}/last_output_set.json"
import json, os, sys
path = os.path.abspath(sys.argv[1])
print(json.dumps({"thread_id": "manual", "images": [path]}, ensure_ascii=False))
PY

  out="$(
    export CODEX_HOME="$codex_home"
    unset CODEX_THREAD_ID CODEX_SESSION_ID 2>/dev/null || true
    "$edit_script" --image-set last-output --prompt test --name dry-test --dry-run 2>&1
  )" || {
    rm -rf "$codex_home"
    return 1
  }
  rm -rf "$codex_home"
  python3 - "$out" "$first" <<'PY'
import json, os, sys
data = json.loads(sys.argv[1])
expected = os.path.abspath(sys.argv[2]).replace("\\", "/")
images = data.get("multipart", {}).get("image[]", [])
if len(images) != 1:
    raise SystemExit(1)
if images[0].replace("\\", "/") != expected:
    raise SystemExit(1)
PY
}

test_bash_array_to_json_empty() {
  local json
  json="$(bash_array_to_json)"
  [[ "$json" == "[]" ]]
}

test_bash_array_to_json_items() {
  local json
  json="$(bash_array_to_json 'alpha' 'beta')"
  python3 -c 'import json,sys; data=json.loads(sys.argv[1]); sys.exit(0 if data==["alpha","beta"] else 1)' "$json"
}

assert_test 'edit_image.sh --image only dry-run (no --image-set)' test_edit_local_image_dry_run
assert_test 'edit_image.sh --image-set last-output dry-run fixture' test_edit_last_output_fixture
assert_test 'bash_array_to_json empty array' test_bash_array_to_json_empty
assert_test 'bash_array_to_json with items' test_bash_array_to_json_items

if ((failures > 0)); then
  printf '\n%d/%d edit dry-run fixture tests failed.\n' "$failures" "$total" >&2
  exit 1
fi

printf '\nAll %d edit dry-run fixture tests passed.\n' "$total"