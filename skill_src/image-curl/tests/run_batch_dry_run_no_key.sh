#!/usr/bin/env bash
# generate-batch --dry-run should work without API Key (install self-check).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill_root="$(cd "$script_dir/.." && pwd)"
batch_script="${skill_root}/scripts/generate_batch.sh"
fixtures="${script_dir}/fixtures/batch_sample.jsonl"
output_dir="$(mktemp -d "${TMPDIR:-/tmp}/image-curl-batch-dry.XXXXXX")"

failures=0
total=0

cleanup() {
  rm -rf "$output_dir"
}
trap cleanup EXIT

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

restore_env() {
  if [[ -n "${saved_key:-}" ]]; then
    export IMAGE_CURL_API_KEY="$saved_key"
  fi
}
trap 'restore_env; cleanup' EXIT

test_batch_dry_run() {
  local out
  out="$("$batch_script" --dry-run --input "$fixtures" --output-dir "$output_dir" 2>&1)" || {
    printf '%s\n' "$out" >&2
    return 1
  }
  python3 -c 'import json,sys
raw=sys.stdin.read().strip()
decoder=json.JSONDecoder()
idx=0
jobs=0
while idx < len(raw):
    while idx < len(raw) and raw[idx].isspace():
        idx += 1
    if idx >= len(raw):
        break
    _data, end = decoder.raw_decode(raw, idx)
    jobs += 1
    assert _data.get("endpoint"), _data
    assert _data.get("job"), _data
    idx = end
assert jobs == 3, f"expected 3 dry-run previews, got {jobs}"
' <<<"$out"
}

assert_test 'generate_batch.sh --dry-run without API key' test_batch_dry_run

if ((failures > 0)); then
  printf '\n%d/%d batch dry-run no-key tests failed.\n' "$failures" "$total" >&2
  exit 1
fi

printf '\nAll %d batch dry-run no-key tests passed.\n' "$total"