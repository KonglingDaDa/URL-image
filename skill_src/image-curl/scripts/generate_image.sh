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
  generate_image.sh --prompt 文本 (--output 文件 | --output-dir 目录 [--name 前缀]) [选项]
  generate_image.sh --prompt-file 文件 (--output 文件 | --output-dir 目录 [--name 前缀]) [选项]

选项：
  --output FILE         输出文件路径（优先于 --output-dir/--name）
  --output-dir DIR      输出目录；与 --name 组合生成「前缀-随机后缀」文件名
  --name PREFIX         可读文件名前缀，默认 generated；未指定 --output-dir 时写入
                        ${CODEX_HOME:-~/.codex}/generated_images/<thread|manual>/
  --model NAME          图片模型，默认：gpt-image-2
  --size SIZE           auto、宽x高、宽:高 或 tier 简写（如 16:9、9:16@1k、2k、4k）
                        解析后须满足：边长为 16 的倍数，最长边 <=3840，宽高比 <=3:1
  --quality VALUE       默认：auto
  --format FORMAT       png、jpeg 或 webp，默认：png
  --output-compression N
                        jpeg/webp 输出压缩级别，0-100
  --moderation VALUE    默认：auto
  --background VALUE    可选背景值，例如 transparent（透明）或 auto
  --count N, --n N      单次 API 请求生成的图片数量，默认 1，最大 10
  --metadata FILE       保存响应 metadata，省略 b64_json
  --base-url URL        覆盖默认 base URL，默认：https://aicode.cat
  --api-key KEY         临时覆盖 API Key；常规请写入 skill 目录 local.env
  --timeout SECONDS     curl 超时时间，默认 300
  --overwrite           允许覆盖已有输出文件
  --dry-run             dry-run 模式，打印脱敏后的请求信息，不调用接口
  -h, --help            显示此帮助
USAGE
}

model="gpt-image-2"
prompt=""
prompt_file=""
output=""
output_dir=""
name=""
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
    --image)
      printf '警告：generate 不支持 --image 输入；请使用 edit_image 进行改图。\n' >&2
      shift 2
      ;;
    --model) model="${2:-}"; shift 2 ;;
    --prompt) prompt="${2:-}"; shift 2 ;;
    --prompt-file) prompt_file="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    --output-dir) output_dir="${2:-}"; shift 2 ;;
    --name) name="${2:-}"; shift 2 ;;
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
    --overwrite) overwrite=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知选项：$1" ;;
  esac
done

if [[ -z "$output" && -z "$output_dir" && -z "$name" ]]; then
  die "必须提供 --output、--output-dir 或 --name 至少其一。"
fi
[[ -n "$model" ]] || die "--model 不能为空。"
[[ -n "$size" ]] || die "--size 不能为空。"
[[ -n "$format" ]] || die "--format 不能为空。"
requested_size="$size"
api_size=""
size_note=""
is_explicit_dimension=0
resolve_size "$requested_size" api_size size_note is_explicit_dimension
test_image_size "$api_size"
size="${api_size,,}"
[[ "$format" =~ ^(png|jpeg|jpg|webp)$ ]] || die "--format 须为 png、jpeg、jpg 或 webp。"
if [[ "$format" == "jpg" ]]; then
  format="jpeg"
fi
if [[ -n "$output_compression" ]]; then
  [[ "$output_compression" =~ ^[0-9]+$ && "$output_compression" -ge 0 && "$output_compression" -le 100 ]] || die "--output-compression 须为 0 至 100 之间的整数。"
  [[ "$format" == "jpeg" || "$format" == "webp" ]] || die "--output-compression 仅适用于 jpeg 或 webp 输出。"
fi
[[ "$timeout" =~ ^[0-9]+$ && "$timeout" -gt 0 ]] || die "--timeout 须为正整数。"
[[ "$count" =~ ^[0-9]+$ && "$count" -ge 1 && "$count" -le 10 ]] || die "--count/--n 须为 1 至 10 之间的整数。"

if [[ -n "$prompt" && -n "$prompt_file" ]]; then
  die "请只提供 --prompt 或 --prompt-file 其中之一，不可同时使用。"
fi

if [[ -n "$prompt_file" ]]; then
  [[ -f "$prompt_file" ]] || die "未找到提示词文件：$prompt_file"
  prompt="$(<"$prompt_file")"
fi

prompt="${prompt#"${prompt%%[![:space:]]*}"}"
prompt="${prompt%"${prompt##*[![:space:]]}"}"
[[ -n "$prompt" ]] || die "必须提供 --prompt 或 --prompt-file。"

if [[ "$is_explicit_dimension" == "1" ]]; then
  prompt="$(augment_prompt_for_size "$prompt" "$requested_size")"
fi

output="$(resolve_output_path "$output" "$output_dir" "$name" "$format")"
output="$(get_full_path "$output")"
resolved_output_dir="$(dirname "$output")"
[[ -d "$resolved_output_dir" ]] || mkdir -p "$resolved_output_dir"

targets=()
get_output_targets "$output" "$format" "$count" targets
assert_output_targets_available "$overwrite" "${targets[@]}"

if [[ -n "$metadata" ]]; then
  metadata="$(get_full_path "$metadata")"
  mkdir -p "$(dirname "$metadata")"
fi

config_json="$(resolve_image_curl_config "$base_url" "$api_key")"
base_url="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["base_url"])' "$config_json")"
api_key="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["api_key"])' "$config_json")"

[[ -n "$base_url" ]] || die "无法解析 base URL，请传入 --base-url 或设置 IMAGE_CURL_BASE_URL。"
[[ -n "$api_key" ]] || die "未找到 API Key。请在 $skill_dir/local.env 中设置 IMAGE_CURL_API_KEY，或传入 --api-key。"

endpoint="$(get_image_endpoint "$base_url" "generations")"

payload="$(python3 - "$model" "$prompt" "$size" "$quality" "$format" "$output_compression" "$moderation" "$background" "$count" <<'PY'
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
  json_output="$(normalize_path_for_json "$output")"
  python3 - "$endpoint" "$payload" "$json_output" "$metadata" "$count" "$size_note" <<'PY'
import json
import sys

endpoint, payload, output, metadata, count, size_note = sys.argv[1:7]

def normalize_path(value):
    if isinstance(value, str) and (len(value) >= 2 and value[1] == ":" or value.startswith("\\\\")):
        return value.replace("\\", "/")
    return value

preview = {
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
  exit 0
fi

response_file="$(mktemp "${TMPDIR:-/tmp}/image-curl-response.XXXXXX.json")"
cleanup() {
  rm -f "$response_file"
}
trap cleanup EXIT

curl -sS --fail-with-body -X POST "$endpoint" \
  -H "Authorization: Bearer $api_key" \
  -H "Content-Type: application/json" \
  -H "Cache-Control: no-store, no-cache, max-age=0" \
  -H "Pragma: no-cache" \
  --max-time "$timeout" \
  -d "$payload" > "$response_file"

result_json="$(save_image_response "$response_file" "$output" "$metadata" "$format" "$count")"
thread_id="$(get_thread_id)"
saved_paths=()
mapfile -t saved_paths < <(extract_saved_paths_from_result "$result_json")
if ((${#saved_paths[@]} > 0)); then
  save_thread_state "$thread_id" --last-output "${saved_paths[@]}"
fi
printf '%s\n' "$result_json"