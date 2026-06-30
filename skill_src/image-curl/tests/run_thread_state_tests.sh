#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill_root="$(cd "$script_dir/.." && pwd)"
# shellcheck source=../scripts/common.sh
source "$skill_root/scripts/common.sh"

thread_state_py="${skill_root}/scripts/lib/thread_state.py"
[[ -f "$thread_state_py" ]] || die "未找到 $thread_state_py"

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

new_temp_codex_home() {
  mktemp -d "${TMPDIR:-/tmp}/image-curl-thread-test.XXXXXX"
}

write_minimal_png() {
  python3 - "$1" <<'PY'
import base64
import sys
from pathlib import Path
png = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
)
Path(sys.argv[1]).write_bytes(png)
PY
}

test_resolve_last_output() {
  local codex_home
  codex_home="$(new_temp_codex_home)"
  local thread_dir="${codex_home}/generated_images/manual"
  mkdir -p "$thread_dir"
  local first="${thread_dir}/first-out.png"
  local second="${thread_dir}/second-out.png"
  write_minimal_png "$first"
  write_minimal_png "$second"
  python3 - "$thread_dir" "$first" "$second" <<'PY'
import json
import sys
from pathlib import Path

thread_dir, first, second = sys.argv[1:4]
payload = {
    "thread_id": "manual",
    "images": [str(Path(first).resolve()), str(Path(second).resolve())],
}
Path(thread_dir, "last_output_set.json").write_text(
    json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
PY

  CODEX_HOME="$codex_home" unset CODEX_THREAD_ID CODEX_SESSION_ID
  export CODEX_HOME
  local result
  result="$(resolve_image_refs manual --image "[Last Output #2]")"
  local count
  count="$(python3 -c 'import json,sys; print(len(json.loads(sys.stdin.read())))' <<<"$result")"
  [[ "$count" == "1" ]] || return 1
  rm -rf "$codex_home"
}

test_rollout_requires_thread() {
  local codex_home
  codex_home="$(new_temp_codex_home)"
  CODEX_HOME="$codex_home" unset CODEX_THREAD_ID CODEX_SESSION_ID
  export CODEX_HOME
  if resolve_image_refs manual --image "[Image #1]" >/dev/null 2>&1; then
    rm -rf "$codex_home"
    return 1
  fi
  rm -rf "$codex_home"
}

assert_test "resolve [Last Output] from manual fixture" test_resolve_last_output
assert_test "rollout placeholder fails without thread env" test_rollout_requires_thread

if ((failures > 0)); then
  printf '\n%d/%d thread state tests failed.\n' "$failures" "$total" >&2
  exit 1
fi

printf '\nAll %d thread state tests passed.\n' "$total"