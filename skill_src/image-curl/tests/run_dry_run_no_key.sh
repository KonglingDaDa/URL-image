#!/usr/bin/env bash
# generate/edit --dry-run should work without API Key (install self-check).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill_root="$(cd "$script_dir/.." && pwd)"
generate_script="${skill_root}/scripts/generate_image.sh"
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
unset IMAGE_CURL_API_KEY IMAGE_CURL_GEMINI_API_KEY OPENAI_API_KEY CLIPROXY_API_KEY 2>/dev/null || true
# Ignore the developer's real local.env so "without API key" really has no key.
export IMAGE_CURL_ENV_FILE="${TMPDIR:-/tmp}/image-curl-tests-no-local.env"

cleanup() {
  if [[ -n "${saved_key:-}" ]]; then
    export IMAGE_CURL_API_KEY="$saved_key"
  fi
}
trap cleanup EXIT

test_generate_dry_run() {
  local out
  out="$("$generate_script" --dry-run --prompt 'install check' --name dry-no-key 2>&1)" || return 1
  python3 -c 'import json,sys; data=json.loads(sys.argv[1]); sys.exit(0 if data.get("endpoint") else 1)' "$out"
}

test_edit_dry_run() {
  local img out
  img="$(mktemp "${TMPDIR:-/tmp}/dry-no-key.XXXXXX.png")"
  python3 -c 'import base64,sys; sys.stdout.buffer.write(base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))' >"$img"
  out="$("$edit_script" --image "$img" --prompt 'install check' --name dry-no-key --dry-run 2>&1)" || {
    rm -f "$img"
    return 1
  }
  rm -f "$img"
  python3 -c 'import json,sys; data=json.loads(sys.argv[1]); sys.exit(0 if data.get("endpoint") else 1)' "$out"
}

test_gemini_dry_run() {
  local out
  out="$("$generate_script" --dry-run --model gemini-nano-banana-2.1 --size 16:9@2k --prompt 'install check' --name dry-gemini 2>/dev/null)" || return 1
  python3 -c 'import json,sys
data=json.loads(sys.argv[1])
assert data["endpoint"].endswith("/v1beta/models/gemini-nano-banana-2.1:generateContent"), data["endpoint"]
assert data["authorization"] == "x-goog-api-key: ***"
assert data["payload"]["generationConfig"]["imageConfig"] == {"aspectRatio": "16:9", "imageSize": "2K"}
assert data["output"].endswith(".jpg")' "$out"
}

assert_test 'generate_image.sh --dry-run without API key' test_generate_dry_run
assert_test 'edit_image.sh --dry-run without API key' test_edit_dry_run
assert_test 'generate_image.sh --dry-run gemini without API key' test_gemini_dry_run

if ((failures > 0)); then
  printf '\n%d/%d dry-run no-key tests failed.\n' "$failures" "$total" >&2
  exit 1
fi

printf '\nAll %d dry-run no-key tests passed.\n' "$total"