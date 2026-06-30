# image-curl shared helpers (sourced by generate_image.sh / edit_image.sh)
#
# Extension hooks for later modules (F–H):
#   read_batch_jobs_jsonl / build_batch_job_descriptor – batch JSONL flows (module F)
#   load_thread_state     – read thread-local overrides (model, size, etc.)
#   responses_api_*       – OpenAI Responses API routing (separate from /v1/images/*)
#   pillow_preprocess     – local image resize/validate before multipart upload
#
# Callers must set skill_dir and invoke load_image_curl_local_env after sourcing.

load_image_curl_local_env() {
  local env_file="${1:?skill_dir required}/local.env"
  if [[ -f "$env_file" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
  fi
}

die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

get_full_path() {
  local path="${1:?}"
  python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$path"
}

normalize_path_for_json() {
  local path="${1:-}"
  if [[ -z "$path" ]]; then
    return 0
  fi
  python3 -c 'import sys; print(sys.argv[1].replace(chr(92), "/"))' "$path"
}

get_curl_file_path() {
  normalize_path_for_json "$(get_full_path "$1")"
}

# Validates a local image/mask path (exists, non-empty).
# $2 = CLI option name (image|mask); $3 = Chinese label for file errors (图片|蒙版).
assert_local_image_file() {
  local path="${1:-}"
  local option_name="${2:-image}"
  local file_label="${3:-图片}"

  [[ -n "$path" ]] || die "--${option_name} 不能为空。"
  [[ -f "$path" ]] || die "未找到${file_label}文件：$path"
  [[ -s "$path" ]] || die "${file_label}文件为空：$path"
}

validate_input_fidelity() {
  local value="${1:-}"
  if [[ -z "$value" ]]; then
    return 0
  fi
  [[ "$value" == "low" || "$value" == "high" ]] || die "--input-fidelity 须为 low 或 high。"
}

resolve_image_curl_config() {
  local override_base_url="${1:-}"
  local override_api_key="${2:-}"
  python3 - "$override_base_url" "$override_api_key" <<'PY'
import json
import os
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
auth_path = codex_home / "auth.json"

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
    "auth_path": str(auth_path),
    "base_url": base_url.rstrip("/") if base_url else "",
    "api_key": api_key,
}, ensure_ascii=False))
PY
}

get_image_endpoint() {
  local base_url="${1:?}"
  local kind="${2:?}"
  local route_base="${base_url%/}"
  if [[ "$route_base" == */v1 ]]; then
    printf '%s/images/%s' "$route_base" "$kind"
  else
    printf '%s/v1/images/%s' "$route_base" "$kind"
  fi
}

# Returns CODEX_THREAD_ID, CODEX_SESSION_ID, or "manual".
get_thread_id() {
  local tid="${CODEX_THREAD_ID:-${CODEX_SESSION_ID:-}}"
  tid="${tid#"${tid%%[![:space:]]*}"}"
  tid="${tid%"${tid##*[![:space:]]}"}"
  if [[ -z "$tid" ]]; then
    printf 'manual\n'
  else
    printf '%s\n' "$tid"
  fi
}

# Default: ${CODEX_HOME:-~/.codex}/generated_images/<thread_id|manual>/
get_default_output_dir() {
  python3 - <<'PY'
import os
from pathlib import Path

def sanitize_path_segment(value):
    sanitized = "".join(
        ch if ch.isascii() and (ch.isalnum() or ch in "-_") else "_"
        for ch in value
    )
    return sanitized or "generated_image"

codex_home = Path(os.environ.get("CODEX_HOME", "") or Path.home() / ".codex").expanduser()
thread_id = (
    os.environ.get("CODEX_THREAD_ID")
    or os.environ.get("CODEX_SESSION_ID")
    or "manual"
).strip() or "manual"
print(codex_home / "generated_images" / sanitize_path_segment(thread_id))
PY
}

# Resolves a single output file path. --output takes priority; otherwise uses
# --output-dir (or default dir) with --name prefix (default "generated") + random suffix.
resolve_output_path() {
  local explicit_output="${1:-}"
  local output_dir="${2:-}"
  local name_prefix="${3:-}"
  local format="${4:-png}"
  local default_dir
  default_dir="$(get_default_output_dir)"

  python3 - "$explicit_output" "$output_dir" "$name_prefix" "$format" "$default_dir" <<'PY'
import os
import sys
import uuid
from pathlib import Path

explicit_output, output_dir, name_prefix, fmt, default_dir = sys.argv[1:6]

def sanitize_path_segment(value):
    sanitized = "".join(
        ch if ch.isascii() and (ch.isalnum() or ch in "-_") else "_"
        for ch in value
    )
    return sanitized or "generated_image"

def random_suffix(length=8):
    return uuid.uuid4().hex[:length]

ext = f".{fmt}"

if explicit_output.strip():
    path = Path(explicit_output).expanduser()
    if not path.is_absolute():
        path = path.resolve()
    if path.suffix == "":
        path = path.with_suffix(ext)
    print(path)
else:
    if output_dir.strip():
        base_dir = Path(output_dir).expanduser()
        if not base_dir.is_absolute():
            base_dir = base_dir.resolve()
    else:
        base_dir = Path(default_dir).expanduser()
    base_dir.mkdir(parents=True, exist_ok=True)
    prefix = sanitize_path_segment(name_prefix.strip() or "generated")
    print(base_dir / f"{prefix}-{random_suffix()}{ext}")
PY
}

# Populates the nameref array with one or more absolute output paths (true bash array).
get_output_targets() {
  local output_path="$1"
  local format="$2"
  local count="$3"
  local -n _targets_ref="$4"

  local -a _lines=()
  mapfile -t _lines < <(python3 - "$output_path" "$format" "$count" <<'PY'
import sys
from pathlib import Path

output = Path(sys.argv[1])
output_format = sys.argv[2]
count = int(sys.argv[3])

if count == 1:
    print(output)
else:
    suffix = output.suffix or f".{output_format}"
    stem = output.stem if output.suffix else output.name
    for index in range(1, count + 1):
        print(output.with_name(f"{stem}-{index}{suffix}"))
PY
)
  _targets_ref=("${_lines[@]}")
}

assert_output_targets_available() {
  local overwrite="$1"
  shift
  local targets=("$@")

  if [[ "$overwrite" -eq 1 ]]; then
    return 0
  fi

  local conflicts=()
  local target
  for target in "${targets[@]}"; do
    if [[ -e "$target" ]]; then
      conflicts+=("$target")
    fi
  done

  if ((${#conflicts[@]} > 0)); then
    local joined
    joined=$(IFS=', '; echo "${conflicts[*]}")
    die "输出文件已存在：${joined}（如需覆盖请加 --overwrite）"
  fi
}

resolve_size() {
  local raw_spec="${1:?}"
  local -n _api_size_ref="${2:?}"
  local -n _note_ref="${3:?}"
  local -n _explicit_ref="${4:?}"

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local normalize_py="${script_dir}/lib/normalize_size.py"
  [[ -f "$normalize_py" ]] || die "未找到尺寸解析脚本：$normalize_py"

  local stderr_file result
  stderr_file="$(mktemp "${TMPDIR:-/tmp}/image-curl-size-err.XXXXXX")"
  if ! result="$(python3 "$normalize_py" "$raw_spec" 2>"$stderr_file")"; then
    local err
    err="$(<"$stderr_file")"
    rm -f "$stderr_file"
    die "${err:-无法解析尺寸：$raw_spec}"
  fi
  rm -f "$stderr_file"

  _api_size_ref="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["api_size"])' "$result")"
  _note_ref="$(python3 -c 'import json,sys; v=json.loads(sys.argv[1]).get("size_note"); print(v if v else "")' "$result")"
  _explicit_ref="$(python3 -c 'import json,sys; print("1" if json.loads(sys.argv[1])["is_explicit_dimension"] else "0")' "$result")"
}

augment_prompt_for_size() {
  local prompt="${1:?}"
  local raw_spec="${2:?}"
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local normalize_py="${script_dir}/lib/normalize_size.py"
  python3 "$normalize_py" --augment-prompt --prompt "$prompt" "$raw_spec"
}

test_image_size() {
  local size="${1,,}"
  if [[ "$size" == "auto" ]]; then
    return 0
  fi
  [[ "$size" =~ ^([1-9][0-9]*)x([1-9][0-9]*)$ ]] || die "--size 须为 auto 或 宽x高，例如 1024x1024、1344x768、2048x1152。"
  local width="${BASH_REMATCH[1]}"
  local height="${BASH_REMATCH[2]}"
  local pixel_count=$(( width * height ))
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
}

# Requires python3 or py -3. Exits with Chinese error when Python is missing.
invoke_thread_state() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local thread_state_py="${script_dir}/lib/thread_state.py"
  [[ -f "$thread_state_py" ]] || die "未找到线程状态脚本：$thread_state_py"

  if command -v python3 >/dev/null 2>&1; then
    python3 "$thread_state_py" "$@"
    return $?
  fi
  if command -v py >/dev/null 2>&1; then
    py -3 "$thread_state_py" "$@"
    return $?
  fi
  die "未找到 Python 3，无法处理线程占位符/状态。请安装 Python 3 并确保 python3 或 py -3 可用。"
}

# Resolve --image-set selectors and --image placeholders to absolute paths (JSON array on stdout).
# Usage: resolve_image_refs THREAD_ID [--image-set SELECTOR ...] [--image PATH_OR_PLACEHOLDER ...]
resolve_image_refs() {
  local thread_id="${1:?}"
  shift
  local -a selectors=()
  local -a images=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --image-set) selectors+=("${2:-}"); shift 2 ;;
      --image) images+=("${2:-}"); shift 2 ;;
      *) die "resolve_image_refs：未知参数 $1" ;;
    esac
  done

  # Use stdin JSON to avoid shell '#' truncation in placeholders like [Last Output #2].
  local selectors_json images_json payload
  selectors_json="$(printf '%s\n' "${selectors[@]}" | python3 -c 'import json,sys; print(json.dumps([line.strip() for line in sys.stdin if line.strip()]))')"
  images_json="$(printf '%s\n' "${images[@]}" | python3 -c 'import json,sys; print(json.dumps([line.strip() for line in sys.stdin if line.strip()]))')"
  payload="$(python3 -c 'import json,sys; print(json.dumps({"thread_id":sys.argv[1],"image_sets":json.loads(sys.argv[2]),"images":json.loads(sys.argv[3])}, ensure_ascii=False))' "$thread_id" "$selectors_json" "$images_json")"
  local request_file
  request_file="$(mktemp "${TMPDIR:-/tmp}/image-curl-resolve-req.XXXXXX.json")"
  printf '%s' "$payload" >"$request_file"
  invoke_thread_state resolve --request-file "$request_file"
  rm -f "$request_file"
}

# Persist active_image_set.json / last_output_set.json for a thread.
# Usage: save_thread_state THREAD_ID [--active-input PATH ...] [--last-output PATH ...]
save_thread_state() {
  local thread_id="${1:?}"
  shift
  local -a active_inputs=()
  local -a last_outputs=()
  local mode=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --active-input)
        mode="active"
        shift
        while [[ $# -gt 0 && "$1" != --* ]]; do
          active_inputs+=("$1")
          shift
        done
        ;;
      --last-output)
        mode="last"
        shift
        while [[ $# -gt 0 && "$1" != --* ]]; do
          last_outputs+=("$1")
          shift
        done
        ;;
      *) die "save_thread_state：未知参数 $1" ;;
    esac
  done

  local -a args=(save --thread-id "$thread_id")
  if ((${#active_inputs[@]} > 0)); then
    args+=(--active-input "${active_inputs[@]}")
  fi
  if ((${#last_outputs[@]} > 0)); then
    args+=(--last-output "${last_outputs[@]}")
  fi
  invoke_thread_state "${args[@]}" >/dev/null
}

extract_saved_paths_from_result() {
  local result_json="${1:?}"
  python3 - "$result_json" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
if isinstance(data.get("saved_files"), list):
    for item in data["saved_files"]:
        if isinstance(item, dict) and item.get("file"):
            print(item["file"])
        elif isinstance(item, str):
            print(item)
elif data.get("saved_file"):
    print(data["saved_file"])
PY
}

read_batch_jobs_jsonl() {
  local path="${1:?}"
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local parser_py="${script_dir}/lib/parse_batch_jsonl.py"
  [[ -f "$parser_py" ]] || die "未找到批量任务解析脚本：$parser_py"
  python3 "$parser_py" "$path"
}

validate_batch_concurrency() {
  local value="${1:?}"
  [[ "$value" =~ ^[0-9]+$ && "$value" -ge 1 && "$value" -le 25 ]] || die "--concurrency 须为 1 至 25 之间的整数。"
}

# Merge CLI defaults with one JSONL job and emit a normalized job descriptor JSON on stdout.
# Usage: build_batch_job_descriptor INDEX JOB_JSON DEFAULTS_JSON
build_batch_job_descriptor() {
  local index="${1:?}"
  local job_json="${2:?}"
  local defaults_json="${3:?}"

  python3 - "$index" "$job_json" "$defaults_json" <<'PY'
import json
import sys

index = int(sys.argv[1])
job = json.loads(sys.argv[2])
defaults = json.loads(sys.argv[3])

def pick(*values):
    for value in values:
        if value is None:
            continue
        if isinstance(value, str):
            if value.strip():
                return value.strip()
            continue
        return value
    return ""

def pick_int(*values):
    for value in values:
        if value is None or value == "":
            continue
        return int(value)
    return 1

prompt = pick(job.get("prompt"), defaults.get("prompt"))
if not prompt:
    raise SystemExit(f"job {index}: missing prompt")

name = pick(job.get("name"), defaults.get("name"))
if not name:
    name = f"{index:03d}"

descriptor = {
    "index": index,
    "prompt": prompt,
    "model": pick(job.get("model"), defaults.get("model")),
    "size": pick(job.get("size"), defaults.get("size")),
    "quality": pick(job.get("quality"), defaults.get("quality")),
    "format": pick(job.get("format"), defaults.get("format")),
    "output_compression": pick(job.get("output_compression"), job.get("compression"), defaults.get("output_compression")),
    "moderation": pick(job.get("moderation"), defaults.get("moderation")),
    "background": pick(job.get("background"), defaults.get("background")),
    "count": pick_int(job.get("n"), job.get("count"), defaults.get("count"), 1),
    "name": name,
    "output": pick(job.get("output"), job.get("out")),
    "metadata": pick(job.get("metadata"), job.get("metadata_path")),
}
print(json.dumps(descriptor, ensure_ascii=False))
PY
}

save_image_response() {
  local response_file="$1"
  local output_path="$2"
  local metadata_path="${3:-}"
  local output_format="$4"
  local requested_count="$5"

  python3 - "$response_file" "$output_path" "$metadata_path" "$output_format" "$requested_count" <<'PY'
import base64
import json
import sys
from pathlib import Path

response_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
metadata_path = Path(sys.argv[3]) if sys.argv[3] else None
output_format = sys.argv[4]
requested_count = int(sys.argv[5])

def normalize_path(path):
    return str(path).replace("\\", "/")

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
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(image_bytes)
    saved_files.append({
        "file": normalize_path(target),
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
    metadata_path.parent.mkdir(parents=True, exist_ok=True)
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
}