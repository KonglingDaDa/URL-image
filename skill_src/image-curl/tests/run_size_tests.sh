#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill_root="$(cd "$script_dir/.." && pwd)"
normalize_py="${skill_root}/scripts/lib/normalize_size.py"
fixtures="${script_dir}/size_fixtures.json"
PYTHON_BIN="${PYTHON:-python3}"
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  if command -v python >/dev/null 2>&1; then
    PYTHON_BIN="python"
  else
    printf '错误：未找到 python3 或 python，可设置 PYTHON 环境变量。\n' >&2
    exit 1
  fi
fi

if [[ ! -f "$normalize_py" ]]; then
  printf '错误：未找到 %s\n' "$normalize_py" >&2
  exit 1
fi
if [[ ! -f "$fixtures" ]]; then
  printf '错误：未找到 %s\n' "$fixtures" >&2
  exit 1
fi

failures=0
total=0

while IFS= read -r case_json; do
  [[ -n "$case_json" ]] || continue
  total=$((total + 1))
  input="$("$PYTHON_BIN" -c 'import json,sys; print(json.loads(sys.argv[1])["input"])' "$case_json")"
  expected_api="$("$PYTHON_BIN" -c 'import json,sys; print(json.loads(sys.argv[1])["api_size"])' "$case_json")"
  expected_note="$("$PYTHON_BIN" -c 'import json,sys; v=json.loads(sys.argv[1])["size_note"]; print("" if v is None else v)' "$case_json")"
  expected_explicit="$("$PYTHON_BIN" -c 'import json,sys; print("true" if json.loads(sys.argv[1])["is_explicit_dimension"] else "false")' "$case_json")"

  actual_json="$("$PYTHON_BIN" "$normalize_py" "$input")"
  actual_api="$("$PYTHON_BIN" -c 'import json,sys; print(json.loads(sys.argv[1])["api_size"])' "$actual_json")"
  actual_note="$("$PYTHON_BIN" -c 'import json,sys; v=json.loads(sys.argv[1]).get("size_note"); print("" if v is None else v)' "$actual_json")"
  actual_explicit="$("$PYTHON_BIN" -c 'import json,sys; print("true" if json.loads(sys.argv[1])["is_explicit_dimension"] else "false")' "$actual_json")"

  if [[ "$actual_api" != "$expected_api" || "$actual_note" != "$expected_note" || "$actual_explicit" != "$expected_explicit" ]]; then
    failures=$((failures + 1))
    printf 'FAIL %s\n' "$input" >&2
    printf '  expected api_size=%s size_note=%q is_explicit=%s\n' "$expected_api" "$expected_note" "$expected_explicit" >&2
    printf '  actual   api_size=%s size_note=%q is_explicit=%s\n' "$actual_api" "$actual_note" "$actual_explicit" >&2
  else
    printf 'OK   %s -> %s\n' "$input" "$actual_api"
  fi
done < <("$PYTHON_BIN" -c 'import json,sys; print("\n".join(json.dumps(c) for c in json.load(open(sys.argv[1], encoding="utf-8"))))' "$fixtures")

if (( failures > 0 )); then
  printf '\n%d/%d size normalization tests failed.\n' "$failures" "$total" >&2
  exit 1
fi

printf '\nAll %d size normalization tests passed.\n' "$total"