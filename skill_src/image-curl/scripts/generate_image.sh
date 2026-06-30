#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
用法：
  generate_image.sh --prompt 文本 --output 文件 [选项]
  generate_image.sh --prompt-file 文件 --output 文件 [选项]

选项：
  --model NAME          图片模型，默认：gpt-image-2
  --size SIZE           auto 或 宽x高；边长须为 16 的倍数，最长边 <=3840，宽高比 <=3:1
  --quality VALUE       默认：auto
  --format FORMAT       png、jpeg 或 webp，默认：png
  --output-compression N
                        jpeg/webp 输出压缩级别，0-100
  --moderation VALUE    默认：auto
  --background VALUE    可选背景值，例如 transparent 或 auto
  --count N, --n N      单次 API 请求生成的图片数量，默认 1，最大 10
  --metadata FILE       保存响应 metadata，省略 b64_json
  --base-url URL        覆盖默认 base URL，默认：https://aicode.cat
  --api-key KEY         覆盖本机 Codex 鉴权 API key
  --timeout SECONDS     curl 超时时间，默认 300
  --overwrite           允许覆盖已有输出文件
  --dry-run             打印脱敏后的请求信息，不调用接口
  -h, --help            显示此帮助
USAGE
}

die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

model="gpt-image-2"
prompt=""
prompt_file=""
output=""
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
    --model) model="${2:-}"; shift 2 ;;
    --prompt) prompt="${2:-}"; shift 2 ;;
    --prompt-file) prompt_file="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
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

[[ -n "$output" ]] || die "必须提供 --output。"
[[ -n "$model" ]] || die "--model 不能为空。"
[[ -n "$size" ]] || die "--size 不能为空。"
[[ -n "$format" ]] || die "--format 不能为空。"
size="${size,,}"
if [[ "$size" != "auto" ]]; then
  [[ "$size" =~ ^([1-9][0-9]*)x([1-9][0-9]*)$ ]] || die "--size 须为 auto 或 宽x高，例如 1024x1024、1344x768、2048x1152。"
  width="${BASH_REMATCH[1]}"
  height="${BASH_REMATCH[2]}"
  pixel_count=$(( width * height ))
  if (( width > 3840 || height > 3840 )); then
    die "--size '$size' 不受上游支持：最长边不得超过 3840。"
  fi
  if (( width % 16 != 0 || height % 16 != 0 )); then
    die "--size '$size' 不受上游支持：宽和高均须为 16 的倍数。"
  fi
  if (( width > height * 3 || height > width * 3 )); then
    die "--size '$size' 不受上游支持：最大宽高比为 3:1。"
  fi
  if (( pixel_count < 655360 || pixel_count > 8294400 )); then
    die "--size '$size' 不受上游支持：总像素数须在 655360 至 8294400 之间。"
  fi
fi
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

output="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$output")"
output_dir="$(dirname "$output")"
[[ -d "$output_dir" ]] || mkdir -p "$output_dir"
if [[ "$count" -eq 1 && -e "$output" && "$overwrite" -ne 1 ]]; then
  die "输出文件已存在：$output（如需覆盖请加 --overwrite）"
fi

if [[ -n "$metadata" ]]; then
  metadata="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$metadata")"
  mkdir -p "$(dirname "$metadata")"
fi

python3 - "$output" "$format" "$count" "$overwrite" <<'PY'
import sys
from pathlib import Path

output = Path(sys.argv[1])
output_format = sys.argv[2]
count = int(sys.argv[3])
overwrite = sys.argv[4] == "1"

def targets_for(output_path, output_format, count):
    if count == 1:
        return [output_path]
    suffix = output_path.suffix or f".{output_format}"
    stem = output_path.stem if output_path.suffix else output_path.name
    return [output_path.with_name(f"{stem}-{index}{suffix}") for index in range(1, count + 1)]

if not overwrite:
    conflicts = [str(path) for path in targets_for(output, output_format, count) if path.exists()]
    if conflicts:
        raise SystemExit("输出文件已存在：" + ", ".join(conflicts) + "（如需覆盖请加 --overwrite）")
PY

config_json="$(python3 - "$base_url" "$api_key" <<'PY'
import json
import os
import re
import sys
from pathlib import Path

override_base_url = sys.argv[1].strip()
override_api_key = sys.argv[2].strip()

def first(*values):
    for value in values:
        if isinstance(value, str) and value.strip():
            return value.strip()
    return ""

codex_home = Path(first(os.environ.get("CODEX_HOME")) or Path.home() / ".codex").expanduser()
config_path = codex_home / "config.toml"
auth_path = codex_home / "auth.json"

def strip_comment(line):
    result = []
    in_string = False
    escaped = False
    for char in line:
        if char == '"' and not escaped:
            in_string = not in_string
        if char == "#" and not in_string:
            break
        result.append(char)
        escaped = char == "\\" and not escaped
        if char != "\\":
            escaped = False
    return "".join(result)

def parse_value(raw):
    raw = raw.strip()
    if len(raw) >= 2 and raw[0] == raw[-1] == '"':
        return raw[1:-1].replace(r'\"', '"')
    if raw.lower() == "true":
        return True
    if raw.lower() == "false":
        return False
    if re.fullmatch(r"-?\d+", raw):
        return int(raw)
    return raw

top = {}
tables = {}
current = None
if config_path.is_file():
    for raw_line in config_path.read_text(encoding="utf-8-sig").splitlines():
        line = strip_comment(raw_line).strip()
        if not line:
            continue
        match = re.fullmatch(r"\[(.+)\]", line)
        if match:
            current = match.group(1).strip()
            tables.setdefault(current, {})
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        target = tables[current] if current else top
        target[key.strip()] = parse_value(value)

def normalize_base_url(value):
    return value.rstrip("/")

base_url = first(
    override_base_url,
    os.environ.get("IMAGE_CURL_BASE_URL"),
    "https://aicode.cat",
)

api_key = first(
    override_api_key,
    os.environ.get("IMAGE_CURL_API_KEY"),
    os.environ.get("OPENAI_API_KEY"),
    os.environ.get("CLIPROXY_API_KEY"),
)

if not api_key and auth_path.is_file():
    try:
        auth = json.loads(auth_path.read_text(encoding="utf-8"))
    except Exception:
        auth = {}
    if isinstance(auth, dict):
        api_key = first(
            auth.get("OPENAI_API_KEY"),
            auth.get("OPENAI_API_TOKEN"),
            auth.get("api_key"),
            auth.get("token"),
            auth.get("openai_api_key"),
        )

print(json.dumps({
    "codex_home": str(codex_home),
    "config_path": str(config_path),
    "auth_path": str(auth_path),
    "base_url": normalize_base_url(base_url) if base_url else "",
    "api_key": api_key,
}, ensure_ascii=False))
PY
)"

base_url="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["base_url"])' "$config_json")"
api_key="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["api_key"])' "$config_json")"
config_path="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["config_path"])' "$config_json")"
auth_path="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["auth_path"])' "$config_json")"

[[ -n "$base_url" ]] || die "无法从 $config_path 读取 base URL，请传入 --base-url 或设置 IMAGE_CURL_BASE_URL。"
[[ -n "$api_key" ]] || die "无法从 $auth_path 读取 API key，请传入 --api-key 或设置 IMAGE_CURL_API_KEY。"

route_base="${base_url%/}"
if [[ "$route_base" == */v1 ]]; then
  endpoint="$route_base/images/generations"
else
  endpoint="$route_base/v1/images/generations"
fi

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
  python3 - "$endpoint" "$payload" "$output" "$metadata" "$count" <<'PY'
import json
import sys

endpoint, payload, output, metadata, count = sys.argv[1:6]
print(json.dumps({
    "endpoint": endpoint,
    "authorization": "Bearer ***",
    "payload": json.loads(payload),
    "output": output,
    "count": int(count),
    "metadata": metadata or None,
}, ensure_ascii=False, indent=2))
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

python3 - "$response_file" "$output" "$metadata" "$format" "$count" <<'PY'
import base64
import json
import sys
from pathlib import Path

response_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
metadata_path = Path(sys.argv[3]) if sys.argv[3] else None
output_format = sys.argv[4]
requested_count = int(sys.argv[5])

try:
    response = json.loads(response_path.read_text(encoding="utf-8"))
except Exception as exc:
    raise SystemExit(f"响应不是合法的 JSON：{exc}")

data = response.get("data")
if not isinstance(data, list) or not data:
    raise SystemExit("响应 JSON 中缺少 data[0]。")

def targets_for(output_path, output_format, count):
    if count == 1:
        return [output_path]
    suffix = output_path.suffix or f".{output_format}"
    stem = output_path.stem if output_path.suffix else output_path.name
    return [output_path.with_name(f"{stem}-{index}{suffix}") for index in range(1, count + 1)]

target_count = requested_count if requested_count > 1 else len(data)
targets = targets_for(output_path, output_format, target_count)
saved_files = []

for index, item in enumerate(data):
    b64 = item.get("b64_json") if isinstance(item, dict) else None
    if not isinstance(b64, str) or not b64:
        raise SystemExit(f"响应 JSON 中缺少 data[{index}].b64_json。")
    try:
        image_bytes = base64.b64decode(b64, validate=True)
    except Exception as exc:
        raise SystemExit(f"data[{index}] 中的 base64 图片数据无效：{exc}")

    target = targets[index]
    target.write_bytes(image_bytes)
    saved_files.append({
        "file": str(target),
        "bytes": len(image_bytes),
        "revised_prompt": item.get("revised_prompt") if isinstance(item, dict) else None,
    })

if metadata_path:
    sanitized = json.loads(json.dumps(response))
    for item in sanitized.get("data", []):
        if isinstance(item, dict) and "b64_json" in item:
            item["b64_json"] = "<omitted>"
    sanitized["saved_files"] = [entry["file"] for entry in saved_files]
    sanitized["requested_count"] = requested_count
    metadata_path.write_text(json.dumps(sanitized, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

if requested_count == 1 and len(saved_files) == 1:
    result = {
        "saved_file": saved_files[0]["file"],
        "bytes": saved_files[0]["bytes"],
        "revised_prompt": saved_files[0]["revised_prompt"],
    }
else:
    result = {
        "saved_files": saved_files,
        "requested_count": requested_count,
        "returned_count": len(saved_files),
    }
print(json.dumps(result, ensure_ascii=False))
PY
