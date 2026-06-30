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
  edit_image.sh --image 文件 --prompt 文本 (--output 文件 | --output-dir 目录 [--name 前缀]) [选项]
  edit_image.sh --image 文件 --prompt-file 文件 (--output 文件 | --output-dir 目录 [--name 前缀]) [选项]

选项：
  --output FILE         输出文件路径（优先于 --output-dir/--name）
  --output-dir DIR      输出目录；与 --name 组合生成「前缀-随机后缀」文件名
  --name PREFIX         可读文件名前缀，默认 generated；未指定 --output-dir 时写入
                        ${CODEX_HOME:-~/.codex}/generated_images/<thread|manual>/
  --image FILE          输入图片或占位符（[Image #N]、[Last Output] 等），可重复
  --image-set SELECTOR  图片集选择器，可重复：active、last-output、latest-turn、
                        turn:-K、thread:1,2,5（edit 不隐式继承线程状态，须显式指定）
  --model NAME          图片模型，默认：gpt-image-2
  --size SIZE           auto、宽x高、宽:高 或 tier 简写（如 16:9、9:16@1k、2k、4k）
                        解析后须满足：边长为 16 的倍数，最长边 <=3840，宽高比 <=3:1
  --quality VALUE       默认：auto
  --format FORMAT       png、jpeg 或 webp，默认：png
  --output-compression N
                        jpeg/webp 输出压缩级别，0-100
  --moderation VALUE    默认：auto
  --mask FILE           可选 PNG 蒙版，透明区域为待编辑区域
  --input-fidelity VALUE
                        输入保真度：low 或 high
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
count="1"
metadata=""
base_url=""
api_key=""
timeout="300"
overwrite=0
dry_run=0
mask=""
input_fidelity=""
images=()
image_sets=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) images+=("${2:-}"); shift 2 ;;
    --image-set) image_sets+=("${2:-}"); shift 2 ;;
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
    --mask) mask="${2:-}"; shift 2 ;;
    --input-fidelity) input_fidelity="${2:-}"; shift 2 ;;
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

[[ "${#images[@]}" -gt 0 || "${#image_sets[@]}" -gt 0 ]] || die "至少需要 --image 或 --image-set 之一。"
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
validate_input_fidelity "$input_fidelity"

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

thread_id="$(get_thread_id)"
resolve_refs_args=()
for selector in "${image_sets[@]}"; do
  resolve_refs_args+=(--image-set "$selector")
done
for image in "${images[@]}"; do
  resolve_refs_args+=(--image "$image")
done
resolved_images_json="$(resolve_image_refs "$thread_id" "${resolve_refs_args[@]}")"
mapfile -t resolved_images < <(python3 -c 'import json,sys; [print(p) for p in json.loads(sys.stdin.read())]' <<<"$resolved_images_json")
((${#resolved_images[@]} > 0)) || die "未能解析任何输入图片。"

resolved_mask=""
if [[ -n "$mask" ]]; then
  assert_local_image_file "$mask" "mask" "蒙版"
  resolved_mask="$(get_full_path "$mask")"
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
if [[ "$dry_run" -eq 0 ]]; then
  [[ -n "$api_key" ]] || die "未找到 API Key。请在 $skill_dir/local.env 中设置 IMAGE_CURL_API_KEY，或传入 --api-key。"
fi

endpoint="$(get_image_endpoint "$base_url" "edits")"

if [[ "$dry_run" -eq 1 ]]; then
  save_thread_state "$thread_id" --active-input "${resolved_images[@]}"
  json_output="$(normalize_path_for_json "$output")"
  curl_images=()
  for image in "${resolved_images[@]}"; do
    curl_images+=("$(normalize_path_for_json "$image")")
  done
  json_mask=""
  if [[ -n "$resolved_mask" ]]; then
    json_mask="$(normalize_path_for_json "$resolved_mask")"
  fi
  python3 - "$endpoint" "$model" "$prompt" "$size" "$quality" "$format" "$output_compression" "$moderation" "$count" "$json_output" "$metadata" "$size_note" "$json_mask" "$input_fidelity" "${curl_images[@]}" <<'PY'
import json
import sys

endpoint, model, prompt, size, quality, output_format, output_compression, moderation, count, output, metadata, size_note, mask, input_fidelity, *images = sys.argv[1:]

def normalize_path(value):
    if isinstance(value, str) and (len(value) >= 2 and value[1] == ":" or value.startswith("\\\\")):
        return value.replace("\\", "/")
    return value

multipart = {
    "model": model,
    "prompt": prompt,
    "size": size,
    "quality": quality,
    "output_format": output_format,
    "moderation": moderation,
    "n": int(count),
    "image[]": [normalize_path(image) for image in images],
}
if output_compression:
    multipart["output_compression"] = int(output_compression)
if mask:
    multipart["mask"] = normalize_path(mask)
if input_fidelity:
    multipart["input_fidelity"] = input_fidelity
preview = {
    "endpoint": endpoint,
    "authorization": "Bearer ***",
    "multipart": multipart,
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

response_file="$(mktemp "${TMPDIR:-/tmp}/image-curl-edit-response.XXXXXX.json")"
prompt_tmp="$(mktemp "${TMPDIR:-/tmp}/image-curl-edit-prompt.XXXXXX.txt")"
printf '%s' "$prompt" >"$prompt_tmp"
cleanup() {
  rm -f "$response_file" "$prompt_tmp"
}
trap cleanup EXIT

curl_args=(
  -sS --fail-with-body -X POST "$endpoint"
  -H "Authorization: Bearer $api_key"
  -H "Cache-Control: no-store, no-cache, max-age=0"
  -H "Pragma: no-cache"
  --max-time "$timeout"
  --form-string "model=$model"
  -F "prompt=<${prompt_tmp}"
  --form-string "size=$size"
  --form-string "quality=$quality"
  --form-string "output_format=$format"
  --form-string "moderation=$moderation"
  --form-string "n=$count"
)

if [[ -n "$output_compression" ]]; then
  curl_args+=(--form-string "output_compression=$output_compression")
fi

if [[ -n "$input_fidelity" ]]; then
  curl_args+=(--form-string "input_fidelity=$input_fidelity")
fi

for image in "${resolved_images[@]}"; do
  curl_args+=(-F "image[]=@$(get_curl_file_path "$image")")
done

if [[ -n "$resolved_mask" ]]; then
  curl_args+=(-F "mask=@$(get_curl_file_path "$resolved_mask")")
fi

curl "${curl_args[@]}" > "$response_file"

result_json="$(save_image_response "$response_file" "$output" "$metadata" "$format" "$count")"
saved_paths=()
mapfile -t saved_paths < <(extract_saved_paths_from_result "$result_json")
if ((${#saved_paths[@]} > 0)); then
  save_thread_state "$thread_id" --active-input "${resolved_images[@]}" --last-output "${saved_paths[@]}"
else
  save_thread_state "$thread_id" --active-input "${resolved_images[@]}"
fi
printf '%s\n' "$result_json"