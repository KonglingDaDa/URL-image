#!/usr/bin/env bash
# Thread placeholders through the real entry script (edit_image.sh --dry-run).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill_root="$(cd "$script_dir/.." && pwd)"
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

unset IMAGE_CURL_API_KEY IMAGE_CURL_GEMINI_API_KEY OPENAI_API_KEY CLIPROXY_API_KEY CODEX_THREAD_ID CODEX_SESSION_ID 2>/dev/null || true
export IMAGE_CURL_ENV_FILE="${TMPDIR:-/tmp}/image-curl-tests-no-local.env"

write_minimal_png() {
  python3 -c 'import base64,sys; open(sys.argv[1],"wb").write(base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))' "$1"
}

# Prints the dry-run image[] list, one path per line.
dry_run_images() {
  python3 -c 'import json,sys; [print(p) for p in json.loads(sys.stdin.read())["multipart"]["image[]"]]'
}

test_last_output_index() {
  local codex_home thread_dir first second out
  codex_home="$(mktemp -d "${TMPDIR:-/tmp}/image-curl-thread-test.XXXXXX")"
  thread_dir="${codex_home}/generated_images/manual"
  mkdir -p "$thread_dir"
  first="${thread_dir}/first-out.png"
  second="${thread_dir}/second-out.png"
  write_minimal_png "$first"
  write_minimal_png "$second"
  python3 -c 'import json,sys; open(sys.argv[1],"w").write(json.dumps({"thread_id":"manual","images":sys.argv[2:]}))' \
    "${thread_dir}/last_output_set.json" "$first" "$second"
  out="$(CODEX_HOME="$codex_home" "$edit_script" --image '[Last Output #2]' --prompt t --name t --dry-run)" || {
    rm -rf "$codex_home"
    return 1
  }
  rm -rf "$codex_home"
  [[ "$(dry_run_images <<<"$out")" == "$second" ]]
}

test_rollout_requires_thread() {
  local codex_home err
  codex_home="$(mktemp -d "${TMPDIR:-/tmp}/image-curl-thread-test.XXXXXX")"
  if err="$(CODEX_HOME="$codex_home" "$edit_script" --image '[Image #1]' --prompt t --name t --dry-run 2>&1)"; then
    rm -rf "$codex_home"
    return 1
  fi
  rm -rf "$codex_home"
  grep -q 'CODEX_THREAD_ID' <<<"$err"
}

test_hash_in_file_name() {
  local dir img out
  dir="$(mktemp -d "${TMPDIR:-/tmp}/image-curl-hash.XXXXXX")"
  img="${dir}/img#2.png"
  write_minimal_png "$img"
  out="$(CODEX_HOME="$dir" "$edit_script" --image "$img" --prompt t --name t --dry-run)" || {
    rm -rf "$dir"
    return 1
  }
  rm -rf "$dir"
  [[ "$(dry_run_images <<<"$out")" == "$img" ]]
}

assert_test "edit resolves [Last Output #2] from manual fixture" test_last_output_index
assert_test "rollout placeholder fails without thread env" test_rollout_requires_thread
assert_test "local path containing # survives the wrapper" test_hash_in_file_name

if ((failures > 0)); then
  printf '\n%d/%d thread state tests failed.\n' "$failures" "$total" >&2
  exit 1
fi

printf '\nAll %d thread state tests passed.\n' "$total"
