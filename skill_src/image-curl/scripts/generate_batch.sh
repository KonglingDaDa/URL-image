#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$script_dir/common.sh"
skill_dir="$(cd "$script_dir/.." && pwd)"
load_image_curl_local_env "$skill_dir"

usage() {
  cat <<'USAGE'
用法：
  generate_batch.sh --input prompts.jsonl --output-dir 目录 [选项]

选项：
  --input FILE          JSONL 批量任务文件（每行一个字符串 prompt 或 job 对象）
  --output-dir DIR      批量输出目录（必填）
  --concurrency N       并发请求数，默认 4，范围 1–25
  --model NAME          默认图片模型，默认：gpt-image-2
  --size SIZE           默认尺寸，默认：1024x1024
  --quality VALUE       默认质量，默认：auto
  --format FORMAT       默认输出格式 png、jpeg 或 webp，默认：png
  --output-compression N
                        默认 jpeg/webp 压缩级别，0-100
  --moderation VALUE    默认审核级别，默认：auto
  --background VALUE    默认背景值，例如 transparent 或 auto
  --count N, --n N      默认单次请求生成数量，默认 1，最大 10
  --metadata FILE       默认 metadata 输出路径（job 可覆盖）
  --base-url URL        覆盖默认 base URL，默认：https://aicode.cat
  --api-key KEY         临时覆盖 API Key；常规请写入 skill 目录 local.env
  --timeout SECONDS     curl 超时时间，默认 300
  --overwrite           允许覆盖已有输出文件
  --dry-run             按 job 打印脱敏 JSON 预览，不调用接口
  -h, --help            显示此帮助

JSONL 每行示例：
  "画一只猫"
  {"prompt":"夕阳","size":"16:9","n":2,"name":"sunset-01"}
  {"prompt":"海报","out":"./batch-out/custom.png"}
USAGE
}

input=""
output_dir=""
concurrency="4"
model="gpt-image-2"
size="1024x1024"
quality="auto"
format="png"
output_compression=""
moderation="auto"
background=""
count="1"
metadata=""
base_url=""
api_key=""
timeout="300"
overwrite=0
dry_run=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input) input="${2:-}"; shift 2 ;;
    --output-dir) output_dir="${2:-}"; shift 2 ;;
    --concurrency) concurrency="${2:-}"; shift 2 ;;
    --model) model="${2:-}"; shift 2 ;;
    --size) size="${2:-}"; shift 2 ;;
    --quality) quality="${2:-}"; shift 2 ;;
    --format|--output-format) format="${2:-}"; shift 2 ;;
    --output-compression) output_compression="${2:-}"; shift 2 ;;
    --moderation) moderation="${2:-}"; shift 2 ;;
    --background) background="${2:-}"; shift 2 ;;
    --count|--n) count="${2:-}"; shift 2 ;;
    --metadata|--metadata-path) metadata="${2:-}"; shift 2 ;;
    --base-url) base_url="${2:-}"; shift 2 ;;
    --api-key) api_key="${2:-}"; shift 2 ;;
    --timeout) timeout="${2:-}"; shift 2 ;;
    --prompt) die "generate-batch 不支持 --prompt；请使用 --input JSONL 文件。" ;;
    --prompt-file) shift 2 ;;
    --output) die "generate-batch 不支持 --output；请使用 --output-dir 与 job 级 name/out。" ;;
    --name) die "generate-batch 不支持全局 --name；请在 JSONL 每行 job 中设置 name。" ;;
    --overwrite) overwrite=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知选项：$1" ;;
  esac
done

[[ -n "$input" ]] || die "必须提供 --input。"
[[ -n "$output_dir" ]] || die "必须提供 --output-dir。"
[[ -n "$model" ]] || die "--model 不能为空。"
[[ -n "$size" ]] || die "--size 不能为空。"
[[ -n "$format" ]] || die "--format 不能为空。"
validate_batch_concurrency "$concurrency"

if [[ "$format" == "jpg" ]]; then
  format="jpeg"
fi
[[ "$format" =~ ^(png|jpeg|webp)$ ]] || die "--format 须为 png、jpeg、jpg 或 webp。"
if [[ -n "$output_compression" ]]; then
  [[ "$output_compression" =~ ^[0-9]+$ && "$output_compression" -ge 0 && "$output_compression" -le 100 ]] || die "--output-compression 须为 0 至 100 之间的整数。"
  [[ "$format" == "jpeg" || "$format" == "webp" ]] || die "--output-compression 仅适用于 jpeg 或 webp 输出。"
fi
[[ "$timeout" =~ ^[0-9]+$ && "$timeout" -gt 0 ]] || die "--timeout 须为正整数。"
[[ "$count" =~ ^[0-9]+$ && "$count" -ge 1 && "$count" -le 10 ]] || die "--count/--n 须为 1 至 10 之间的整数。"

resolved_output_dir="$(get_full_path "$output_dir")"
mkdir -p "$resolved_output_dir"

defaults_json="$(python3 -c 'import json,sys; print(json.dumps({
    "model": sys.argv[1],
    "size": sys.argv[2],
    "quality": sys.argv[3],
    "format": sys.argv[4],
    "output_compression": sys.argv[5],
    "moderation": sys.argv[6],
    "background": sys.argv[7],
    "count": int(sys.argv[8]),
    "metadata": sys.argv[9],
}, ensure_ascii=False))' "$model" "$size" "$quality" "$format" "$output_compression" "$moderation" "$background" "$count" "$metadata")"

jobs_json="$(read_batch_jobs_jsonl "$input")"
mapfile -t job_lines < <(python3 -c 'import json,sys; jobs=json.loads(sys.stdin.read());
for job in jobs: print(json.dumps(job, ensure_ascii=False))' <<<"$jobs_json")

config_json="$(resolve_image_curl_config "$base_url" "$api_key")"
base_url="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["base_url"])' "$config_json")"
api_key="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["api_key"])' "$config_json")"
[[ -n "$base_url" ]] || die "无法解析 base URL，请传入 --base-url 或设置 IMAGE_CURL_BASE_URL。"
if [[ "$dry_run" -eq 0 ]]; then
  [[ -n "$api_key" ]] || die "未找到 API Key。请在 $skill_dir/local.env 中设置 IMAGE_CURL_API_KEY，或传入 --api-key。"
fi

endpoint="$(get_image_endpoint "$base_url" "generations")"
batch_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/image-curl-batch.XXXXXX")"
cleanup_batch_tmp() {
  rm -rf "$batch_tmp_dir"
}
trap cleanup_batch_tmp EXIT

batch_job_fail() {
  local index="$1"
  shift
  printf 'job %s failed: %s\n' "$index" "$*" >"$batch_tmp_dir/error-${index}.txt"
  return 1
}

capture_die() {
  local err_file="$1"
  shift
  if "$@" 2>"$err_file"; then
    return 0
  fi
  local status=$?
  if [[ -s "$err_file" ]]; then
    tr '\n' ' ' <"$err_file"
  else
    printf 'exit %s' "$status"
  fi
  return "$status"
}

run_batch_job() {
  local index="$1"
  local job_json="$2"
  local descriptor err_file
  err_file="$batch_tmp_dir/plan-${index}.err"
  if ! descriptor="$(build_batch_job_descriptor "$index" "$job_json" "$defaults_json" 2>"$err_file")"; then
    batch_job_fail "$index" "$(if [[ -s "$err_file" ]]; then tr '\n' ' ' <"$err_file"; else echo '无法构建任务描述符。'; fi)"
    return 1
  fi

  local prompt requested_size job_model job_quality job_format job_compression job_moderation job_background job_count job_name job_output job_metadata
  prompt="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["prompt"])' "$descriptor")"
  requested_size="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["size"])' "$descriptor")"
  job_model="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["model"])' "$descriptor")"
  job_quality="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["quality"])' "$descriptor")"
  job_format="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["format"])' "$descriptor")"
  job_compression="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["output_compression"])' "$descriptor")"
  job_moderation="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["moderation"])' "$descriptor")"
  job_background="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["background"])' "$descriptor")"
  job_count="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["count"])' "$descriptor")"
  job_name="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["name"])' "$descriptor")"
  job_output="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["output"])' "$descriptor")"
  job_metadata="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["metadata"])' "$descriptor")"

  if [[ "$job_format" == "jpg" ]]; then
    job_format="jpeg"
  fi
  if [[ ! "$job_format" =~ ^(png|jpeg|webp)$ ]]; then
    batch_job_fail "$index" "--format 须为 png、jpeg、jpg 或 webp。"
    return 1
  fi
  if [[ ! "$job_count" =~ ^[0-9]+$ || "$job_count" -lt 1 || "$job_count" -gt 10 ]]; then
    batch_job_fail "$index" "--count/--n 须为 1 至 10 之间的整数。"
    return 1
  fi

  local api_size="" size_note="" is_explicit_dimension=0
  local size_meta="$batch_tmp_dir/size-meta-${index}.json"
  err_file="$batch_tmp_dir/size-${index}.err"
  if ! (
    api_size="" size_note="" is_explicit_dimension=0
    resolve_size "$requested_size" api_size size_note is_explicit_dimension
    python3 - "$api_size" "$size_note" "$is_explicit_dimension" <<'PY'
import json
import sys
print(json.dumps({
    "api_size": sys.argv[1],
    "size_note": sys.argv[2],
    "is_explicit_dimension": sys.argv[3],
}, ensure_ascii=False))
PY
  ) 2>"$err_file" >"$size_meta"; then
    batch_job_fail "$index" "$(if [[ -s "$err_file" ]]; then tr '\n' ' ' <"$err_file"; else echo "无法解析尺寸：$requested_size"; fi)"
    return 1
  fi
  api_size="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["api_size"])' "$size_meta")"
  size_note="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["size_note"])' "$size_meta")"
  is_explicit_dimension="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["is_explicit_dimension"])' "$size_meta")"
  err_file="$batch_tmp_dir/test-size-${index}.err"
  if ! capture_die "$err_file" test_image_size "$api_size" >/dev/null; then
    batch_job_fail "$index" "$(tr '\n' ' ' <"$err_file")"
    return 1
  fi
  api_size="${api_size,,}"

  if [[ "$is_explicit_dimension" == "1" ]]; then
    prompt="$(augment_prompt_for_size "$prompt" "$requested_size")"
  fi

  local output
  if [[ -n "$job_output" ]]; then
    output="$(resolve_output_path "$job_output" "" "" "$job_format")"
  else
    output="$(resolve_output_path "" "$resolved_output_dir" "$job_name" "$job_format")"
  fi
  output="$(get_full_path "$output")"
  mkdir -p "$(dirname "$output")"

  local -a targets=()
  get_output_targets "$output" "$job_format" "$job_count" targets
  err_file="$batch_tmp_dir/targets-${index}.err"
  if ! capture_die "$err_file" assert_output_targets_available "$overwrite" "${targets[@]}" >/dev/null; then
    batch_job_fail "$index" "$(tr '\n' ' ' <"$err_file")"
    return 1
  fi

  local resolved_metadata=""
  if [[ -n "$job_metadata" ]]; then
    resolved_metadata="$(get_full_path "$job_metadata")"
    mkdir -p "$(dirname "$resolved_metadata")"
  fi

  local payload
  payload="$(python3 - "$job_model" "$prompt" "$api_size" "$job_quality" "$job_format" "$job_compression" "$job_moderation" "$job_background" "$job_count" <<'PY'
import json
import sys

model, prompt, size, quality, output_format, output_compression, moderation, background, count = sys.argv[1:10]
if output_format == "jpg":
    output_format = "jpeg"

payload = {
    "model": model,
    "prompt": prompt,
    "size": size,
    "quality": quality,
    "output_format": output_format,
    "moderation": moderation,
    "n": int(count),
}
if background.strip():
    payload["background"] = background.strip()
if output_compression.strip():
    payload["output_compression"] = int(output_compression)
print(json.dumps(payload, ensure_ascii=False))
PY
)"

  if [[ "$dry_run" -eq 1 ]]; then
    local json_output
    json_output="$(normalize_path_for_json "$output")"
    python3 - "$index" "$endpoint" "$payload" "$json_output" "$resolved_metadata" "$job_count" "$size_note" <<'PY' >"$batch_tmp_dir/preview-${index}.json"
import json
import sys

index, endpoint, payload, output, metadata, count, size_note = sys.argv[1:8]

def normalize_path(value):
    if isinstance(value, str) and (len(value) >= 2 and value[1] == ":" or value.startswith("\\\\")):
        return value.replace("\\", "/")
    return value

preview = {
    "job": int(index),
    "endpoint": endpoint,
    "authorization": "Bearer ***",
    "payload": json.loads(payload),
    "output": normalize_path(output),
    "count": int(count),
    "metadata": normalize_path(metadata) if metadata else None,
}
if size_note:
    preview["size_note"] = size_note
print(json.dumps(preview, ensure_ascii=False, indent=2))
PY
    return 0
  fi

  local response_file
  response_file="$(mktemp "${batch_tmp_dir}/response-${index}.XXXXXX.json")"
  if ! curl -sS --fail-with-body -X POST "$endpoint" \
    -H "Authorization: Bearer $api_key" \
    -H "Content-Type: application/json" \
    -H "Cache-Control: no-store, no-cache, max-age=0" \
    -H "Pragma: no-cache" \
    --max-time "$timeout" \
    -d "$payload" >"$response_file"; then
    local error_body
    error_body="$(<"$response_file")"
    printf 'job %s failed: curl 请求失败。%s\n' "$index" "$error_body" >"$batch_tmp_dir/error-${index}.txt"
    return 1
  fi

  local result_json
  if ! result_json="$(save_image_response "$response_file" "$output" "$resolved_metadata" "$job_format" "$job_count")"; then
    printf 'job %s failed: 无法保存响应图片。\n' "$index" >"$batch_tmp_dir/error-${index}.txt"
    return 1
  fi

  printf '%s\n' "$result_json" >"$batch_tmp_dir/result-${index}.json"
  return 0
}

if [[ "$dry_run" -eq 1 ]]; then
  failures=()
  index=0
  for job_json in "${job_lines[@]}"; do
    index=$((index + 1))
    if run_batch_job "$index" "$job_json"; then
      cat "$batch_tmp_dir/preview-${index}.json"
    elif [[ -f "$batch_tmp_dir/error-${index}.txt" ]]; then
      failures+=("$(<"$batch_tmp_dir/error-${index}.txt")")
    fi
  done
  if ((${#failures[@]} > 0)); then
    printf '%s\n' "${failures[@]}" >&2
    exit 1
  fi
  exit 0
fi

failures=()
pids=()
index=0
for job_json in "${job_lines[@]}"; do
  index=$((index + 1))
  while ((${#pids[@]} >= concurrency)); do
    still_running=()
    for pid in "${pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        still_running+=("$pid")
      else
        wait "$pid" || true
      fi
    done
    pids=("${still_running[@]}")
    if ((${#pids[@]} >= concurrency)); then
      sleep 0.2
    fi
  done
  (
    set +e
    run_batch_job "$index" "$job_json"
    exit 0
  ) &
  pids+=($!)
done

for pid in "${pids[@]}"; do
  wait "$pid" || true
done

saved_paths=()
for job_index in $(seq 1 "${#job_lines[@]}"); do
  if [[ -f "$batch_tmp_dir/error-${job_index}.txt" ]]; then
    failures+=("$(<"$batch_tmp_dir/error-${job_index}.txt")")
  elif [[ -f "$batch_tmp_dir/result-${job_index}.json" ]]; then
    while IFS= read -r saved_path; do
      [[ -n "$saved_path" ]] && saved_paths+=("$saved_path")
      printf '%s\n' "$saved_path"
    done < <(python3 - "$batch_tmp_dir/result-${job_index}.json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if isinstance(data.get("saved_files"), list):
    for item in data["saved_files"]:
        if isinstance(item, dict) and item.get("file"):
            print(item["file"])
        elif isinstance(item, str):
            print(item)
elif data.get("saved_file"):
    print(data["saved_file"])
PY
)
  fi
done

if ((${#saved_paths[@]} > 0)); then
  thread_id="$(get_thread_id)"
  save_thread_state "$thread_id" --last-output "${saved_paths[@]}"
fi

if ((${#failures[@]} > 0)); then
  printf '%s\n' "${failures[@]}" >&2
  exit 1
fi

exit 0