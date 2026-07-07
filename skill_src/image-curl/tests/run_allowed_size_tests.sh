#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill_root="$(cd "$script_dir/.." && pwd)"
allowed_json="${skill_root}/scripts/lib/allowed_sizes.json"
normalize_py="${skill_root}/scripts/lib/normalize_size.py"
gen="${skill_root}/scripts/generate_image.sh"
PYTHON_BIN="${PYTHON:-python3}"

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  if command -v python >/dev/null 2>&1; then
    PYTHON_BIN="python"
  else
    printf '错误：未找到 python3 或 python。\n' >&2
    exit 1
  fi
fi

failures=0

while IFS= read -r input; do
  [[ -n "$input" ]] || continue
  if ! bash "$gen" --dry-run --prompt t --size "$input" --name t >/dev/null 2>&1; then
    printf 'FAIL allowed rejected: %s\n' "$input" >&2
    failures=$((failures + 1))
  else
    printf 'OK   allowed: %s\n' "$input"
  fi
done < <("$PYTHON_BIN" -c 'import json,sys; [print(item["input"]) for item in json.load(open(sys.argv[1], encoding="utf-8"))["allowed"]]' "$allowed_json")

while IFS= read -r forbidden; do
  [[ -n "$forbidden" ]] || continue
  if bash "$gen" --dry-run --prompt t --size "$forbidden" --name t >/dev/null 2>&1; then
    printf 'FAIL forbidden accepted: %s\n' "$forbidden" >&2
    failures=$((failures + 1))
  else
    printf 'OK   forbidden: %s\n' "$forbidden"
  fi
done < <("$PYTHON_BIN" -c 'import json,sys; [print(item["input"]) for item in json.load(open(sys.argv[1], encoding="utf-8"))["forbidden"]]' "$allowed_json")

# Generic forbidden case not listed in catalog (non-allowlisted WxH).
forbidden_extra="1344x768"
if bash "$gen" --dry-run --prompt t --size "$forbidden_extra" --name t >/dev/null 2>&1; then
  printf 'FAIL forbidden accepted: %s\n' "$forbidden_extra" >&2
  failures=$((failures + 1))
else
  printf 'OK   forbidden: %s\n' "$forbidden_extra"
fi

while IFS= read -r case_json; do
  [[ -n "$case_json" ]] || continue
  input="$("$PYTHON_BIN" -c 'import json,sys; print(json.loads(sys.argv[1])["input"])' "$case_json")"
  expected_api="$("$PYTHON_BIN" -c 'import json,sys; print(json.loads(sys.argv[1])["api_size"])' "$case_json")"
  actual_api="$("$PYTHON_BIN" "$normalize_py" "$input" | "$PYTHON_BIN" -c 'import json,sys; print(json.load(sys.stdin)["api_size"])')"
  if [[ "$actual_api" != "$expected_api" ]]; then
    printf 'FAIL catalog normalize mismatch: %s expected=%s actual=%s\n' "$input" "$expected_api" "$actual_api" >&2
    failures=$((failures + 1))
  else
    printf 'OK   catalog normalize: %s -> %s\n' "$input" "$actual_api"
  fi
done < <("$PYTHON_BIN" -c 'import json,sys; print("\n".join(json.dumps(c) for c in json.load(open(sys.argv[1], encoding="utf-8"))["allowed"]))' "$allowed_json")

if (( failures > 0 )); then
  printf '\n%d allowed-size tests failed.\n' "$failures" >&2
  exit 1
fi

printf '\nAll allowed-size tests passed.\n'