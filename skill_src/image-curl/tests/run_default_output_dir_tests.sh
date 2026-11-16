#!/usr/bin/env bash
# Default output dir picks a writable location when CODEX_HOME is not writable (sandbox).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill_root="$(cd "$script_dir/.." && pwd)"
# shellcheck source=../scripts/common.sh
source "${skill_root}/scripts/common.sh"
generate_script="${skill_root}/scripts/generate_image.sh"

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

test_fallback_when_codex_home_readonly() {
  local workdir readonly_home out resolved
  workdir="$(mktemp -d "${TMPDIR:-/tmp}/image-curl-out-fallback.XXXXXX")"
  readonly_home="$(mktemp -d "${TMPDIR:-/tmp}/image-curl-readonly-codex.XXXXXX")"
  chmod 555 "$readonly_home"

  (
    cd "$workdir"
    export CODEX_HOME="$readonly_home"
    unset IMAGE_CURL_OUTPUT_DIR CODEX_THREAD_ID CODEX_SESSION_ID 2>/dev/null || true
    out="$("$generate_script" --dry-run --prompt 'sandbox fallback' --name fallback-test 2>&1)"
    resolved="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["output"])' "$out")"
    case "$resolved" in
      "$workdir"/.image-curl-output/*) ;;
      *) return 1 ;;
    esac
  )

  chmod 755 "$readonly_home"
  rm -rf "$workdir" "$readonly_home"
}

test_image_curl_output_dir_override() {
  local workdir override out resolved
  workdir="$(mktemp -d "${TMPDIR:-/tmp}/image-curl-out-override.XXXXXX")"
  override="${workdir}/custom-out"

  (
    cd "$workdir"
    export IMAGE_CURL_OUTPUT_DIR="$override"
    unset CODEX_HOME CODEX_THREAD_ID CODEX_SESSION_ID 2>/dev/null || true
    out="$("$generate_script" --dry-run --prompt 'override dir' --name override-test 2>&1)"
    resolved="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["output"])' "$out")"
    case "$resolved" in
      "$override"/manual/*) ;;
      *) return 1 ;;
    esac
  )

  rm -rf "$workdir"
}

assert_test 'dry-run falls back to ./.image-curl-output when CODEX_HOME readonly' test_fallback_when_codex_home_readonly
assert_test 'IMAGE_CURL_OUTPUT_DIR overrides default base' test_image_curl_output_dir_override

if ((failures > 0)); then
  printf '\n%d/%d default output dir tests failed.\n' "$failures" "$total" >&2
  exit 1
fi

printf '\nAll %d default output dir tests passed.\n' "$total"