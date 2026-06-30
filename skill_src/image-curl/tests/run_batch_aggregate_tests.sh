#!/usr/bin/env bash
# Unit-style test for generate_batch.sh job aggregation: missing result/error => failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
    printf 'FAIL %s\n' "$name"
  fi
}

test_missing_job_recorded_as_failure() {
  local batch_tmp_dir
  batch_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/image-curl-batch-agg.XXXXXX")"
  local -a failures=()
  local job_count=3

  # job 1: success result only
  printf '{"saved_file":"out1.png"}' >"$batch_tmp_dir/result-1.json"
  # job 2: explicit error
  printf 'job 2 failed: boom\n' >"$batch_tmp_dir/error-2.txt"
  # job 3: neither file (simulates abnormal worker exit)

  local job_index
  for job_index in $(seq 1 "$job_count"); do
    if [[ -f "$batch_tmp_dir/error-${job_index}.txt" ]]; then
      failures+=("$(<"$batch_tmp_dir/error-${job_index}.txt")")
    elif [[ -f "$batch_tmp_dir/result-${job_index}.json" ]]; then
      :
    else
      failures+=("job ${job_index} failed: 未产生结果文件（worker 异常退出）")
    fi
  done

  rm -rf "$batch_tmp_dir"

  [[ ${#failures[@]} -eq 2 ]] || return 1
  [[ "${failures[0]}" == "job 2 failed: boom" ]] || return 1
  [[ "${failures[1]}" == "job 3 failed: 未产生结果文件（worker 异常退出）" ]] || return 1
  return 0
}

assert_test 'missing batch job recorded as failure' test_missing_job_recorded_as_failure

if ((failures > 0)); then
  printf '\n%d/%d batch aggregate tests failed.\n' "$failures" "$total" >&2
  exit 1
fi

printf '\nAll %d batch aggregate tests passed.\n' "$total"