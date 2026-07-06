#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill_root="$(cd "$script_dir/.." && pwd)"
allowed_json="${skill_root}/scripts/lib/allowed_sizes.json"
fixtures_json="${script_dir}/size_fixtures.json"
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

missing_inputs="$("$PYTHON_BIN" -c '
import json, sys

catalog = json.load(open(sys.argv[1], encoding="utf-8"))
fixtures = json.load(open(sys.argv[2], encoding="utf-8"))
catalog_inputs = {item["input"] for item in catalog["allowed"]}
fixture_inputs = {item["input"] for item in fixtures}
missing = sorted(catalog_inputs - fixture_inputs)
if missing:
    print(",".join(missing))
' "$allowed_json" "$fixtures_json")"
if [[ -n "$missing_inputs" ]]; then
  printf 'FAIL allowed_sizes.json 白名单条目未出现在 size_fixtures.json：%s\n' "$missing_inputs" >&2
  failures=$((failures + 1))
fi

if (( failures > 0 )); then
  printf '\n%d allowed-size tests failed.\n' "$failures" >&2
  exit 1
fi

printf '\nAll allowed-size tests passed.\n'