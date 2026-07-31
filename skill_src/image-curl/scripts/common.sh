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

# Bash 3.2 compatible lowercase (macOS ships /bin/bash 3.2).
to_lower() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'
}

# Sets a scalar variable by name (Bash 3.2 replacement for local -n namerefs).
assign_var_by_name() {
  local var_name="${1:?}"
  local value="${2-}"
  eval "$var_name=\"\$value\""
}

# Reads newline-delimited stdout from CMD into the array variable named VAR_NAME.
# Bash 3.2 replacement for mapfile/readarray.
read_lines_into_array() {
  local var_name="${1:?}"
  shift
  local -a _lines=()
  local _line
  while IFS= read -r _line || [[ -n "${_line:-}" ]]; do
    _lines+=("$_line")
  done < <("$@")
  eval "$var_name=(\"\${_lines[@]}\")"
}

# Encode a Bash string array as a JSON array. Safe for empty arrays under Bash 3.2 + set -u.
# Usage: bash_array_to_json [ITEM ...]
bash_array_to_json() {
  local -a items=()
  if (($# > 0)); then
    items=("$@")
  fi
  if ((${#items[@]} == 0)); then
    printf '[]'
    return 0
  fi
  printf '%s\n' "${items[@]}" | python3 -c 'import json,sys; print(json.dumps([line.strip() for line in sys.stdin if line.strip()]))'
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

# Default output base (first writable candidate):
#   1. $IMAGE_CURL_OUTPUT_DIR/<thread_id|manual>/
#   2. ${CODEX_HOME:-~/.codex}/generated_images/<thread_id|manual>/
#   3. ./.image-curl-output/<thread_id|manual>/  (sandbox / read-only CODEX_HOME fallback)
get_default_output_dir() {
  python3 - <<'PY'
import os
import tempfile
from pathlib import Path

def sanitize_path_segment(value):
    sanitized = "".join(
        ch if ch.isascii() and (ch.isalnum() or ch in "-_") else "_"
        for ch in value
    )
    return sanitized or "generated_image"

def is_writable_dir(path: Path) -> bool:
    try:
        path.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=path, delete=True):
            pass
        return True
    except OSError:
        return False

thread_id = (
    os.environ.get("CODEX_THREAD_ID")
    or os.environ.get("CODEX_SESSION_ID")
    or "manual"
).strip() or "manual"
segment = sanitize_path_segment(thread_id)

candidates = []
override = (os.environ.get("IMAGE_CURL_OUTPUT_DIR") or "").strip()
if override:
    candidates.append(Path(override).expanduser())
codex_home = Path(os.environ.get("CODEX_HOME", "") or Path.home() / ".codex").expanduser()
candidates.append(codex_home / "generated_images")
candidates.append(Path.cwd() / ".image-curl-output")

chosen = None
for base in candidates:
    target = base / segment
    if is_writable_dir(target):
        chosen = target
        break

print(chosen or (candidates[-1] / segment))
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

# Populates the array variable named by $4 with one or more absolute output paths.
get_output_targets() {
  local output_path="$1"
  local format="$2"
  local count="$3"
  local var_targets="${4:?}"

  read_lines_into_array "$var_targets" python3 - "$output_path" "$format" "$count" <<'PY'
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

_normalize_size_result() {
  local raw_spec="${1:?}"
  local var_api_size="${2:?}"
  local var_size_note="${3:?}"
  local var_explicit="${4:?}"
  local result="${5:?}"

  assign_var_by_name "$var_api_size" "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["api_size"])' "$result")"
  assign_var_by_name "$var_size_note" "$(python3 -c 'import json,sys; v=json.loads(sys.argv[1]).get("size_note"); print(v if v else "")' "$result")"
  assign_var_by_name "$var_explicit" "$(python3 -c 'import json,sys; print("1" if json.loads(sys.argv[1])["is_explicit_dimension"] else "0")' "$result")"
}

_run_normalize_size() {
  local raw_spec="${1:?}"
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
    printf '%s\n' "${err:-无法解析尺寸：$raw_spec}" >&2
    return 1
  fi
  rm -f "$stderr_file"
  printf '%s' "$result"
}

# Like resolve_size but returns 1 instead of die (for batch job error aggregation).
try_resolve_size() {
  local raw_spec="${1:?}"
  local var_api_size="${2:?}"
  local var_size_note="${3:?}"
  local var_explicit="${4:?}"
  local result

  if ! result="$(_run_normalize_size "$raw_spec")"; then
    return 1
  fi
  _normalize_size_result "$raw_spec" "$var_api_size" "$var_size_note" "$var_explicit" "$result"
}

resolve_size() {
  local raw_spec="${1:?}"
  local var_api_size="${2:?}"
  local var_size_note="${3:?}"
  local var_explicit="${4:?}"
  local result

  if ! result="$(_run_normalize_size "$raw_spec")"; then
    exit 1
  fi
  _normalize_size_result "$raw_spec" "$var_api_size" "$var_size_note" "$var_explicit" "$result"
}

# Writes {"api_size","size_note","is_explicit_dimension"} JSON to $2; returns 1 on error.
write_resolve_size_meta() {
  local raw_spec="${1:?}"
  local out_file="${2:?}"
  local api_size="" size_note="" is_explicit_dimension=0

  if ! try_resolve_size "$raw_spec" api_size size_note is_explicit_dimension; then
    return 1
  fi
  python3 -c 'import json,sys; print(json.dumps({"api_size":sys.argv[1],"size_note":sys.argv[2],"is_explicit_dimension":sys.argv[3]}, ensure_ascii=False))' \
    "$api_size" "$size_note" "$is_explicit_dimension" >"$out_file"
}

augment_prompt_for_size() {
  local prompt="${1:?}"
  local raw_spec="${2:?}"
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local normalize_py="${script_dir}/lib/normalize_size.py"
  python3 "$normalize_py" --augment-prompt --prompt "$prompt" "$raw_spec"
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
  selectors_json="$(bash_array_to_json ${selectors+"${selectors[@]}"})"
  images_json="$(bash_array_to_json ${images+"${images[@]}"})"
  payload="$(python3 -c 'import json,sys; print(json.dumps({"thread_id":sys.argv[1],"image_sets":json.loads(sys.argv[2]),"images":json.loads(sys.argv[3])}, ensure_ascii=False))' "$thread_id" "$selectors_json" "$images_json")"
  local request_file
  request_file="$(mktemp "${TMPDIR:-/tmp}/image-curl-resolve-req.XXXXXX.json")"
  printf '%s' "$payload" >"$request_file"
  local status=0
  invoke_thread_state resolve --request-file "$request_file" || status=$?
  rm -f "$request_file"
  return "$status"
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
        if isinstance(item, dict):
            path = item.get("file") or item.get("path")
            if path:
                print(path)
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
  local api_key="${6:-}"

  python3 - "$response_file" "$output_path" "$metadata_path" "$output_format" "$requested_count" "$api_key" <<'PY'
import base64
import json
import re
import sys
from pathlib import Path
from urllib import error as urlerror
from urllib import request as urlrequest

response_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
metadata_path = Path(sys.argv[3]) if sys.argv[3] else None
output_format = sys.argv[4]
requested_count = int(sys.argv[5])
api_key = sys.argv[6].strip() if len(sys.argv) > 6 else ""

URL_FETCH_TIMEOUT = 120
DATA_URL_PATTERN = re.compile(
    r"^data:(?P<mime>[\w.+/-]+)?(?P<base64>;base64)?,(?P<data>.*)$",
    re.IGNORECASE | re.DOTALL,
)


def normalize_path(path):
    return str(path).replace("\\", "/")


def item_keys(item):
    if isinstance(item, dict):
        return sorted(item.keys())
    return type(item).__name__


def decode_data_url(raw: str) -> bytes:
    match = DATA_URL_PATTERN.match(raw.strip())
    if not match:
        raise ValueError("不是合法的 data URL")
    payload = match.group("data")
    if match.group("base64"):
        return base64.b64decode(payload, validate=False)
    from urllib.parse import unquote_to_bytes

    return unquote_to_bytes(payload)


def fetch_url_bytes(url: str, api_key: str) -> bytes:
    """Download image bytes from url.

    Prefer no Authorization first: many gateways return S3 pre-signed URLs
    that break (406) if extra signed headers are sent. Retry with Bearer only
    on 401/403 (auth-gated content hosts).
    """
    if url.lower().startswith("data:"):
        return decode_data_url(url)

    last_error = None
    attempts = [(None, "无鉴权")]
    if api_key:
        attempts.append(({"Authorization": f"Bearer {api_key}"}, "Bearer"))

    for headers, label in attempts:
        try:
            req = urlrequest.Request(url, headers=headers or {})
            with urlrequest.urlopen(req, timeout=URL_FETCH_TIMEOUT) as resp:
                body = resp.read()
            if not body:
                raise ValueError(f"{label}下载结果为空")
            return body
        except urlerror.HTTPError as exc:
            last_error = exc
            body_hint = ""
            try:
                body_hint = exc.read(200).decode("utf-8", errors="replace")
            except Exception:
                body_hint = ""
            # Retry with auth only when the host rejected anonymous access.
            if headers is None and exc.code in (401, 403) and api_key:
                continue
            extra = f" body={body_hint!r}" if body_hint else ""
            raise SystemExit(
                f"从 data[].url 下载图片失败（{label} HTTP {exc.code}）：{exc.reason}。"
                f"若链接主机不接受当前 API Key，且非预签名公开 URL，请重试请求或要求网关返回 b64_json。"
                f"{extra}"
            ) from exc
        except Exception as exc:
            last_error = exc
            if headers is None and api_key:
                continue
            raise SystemExit(f"从 data[].url 下载图片失败（{label}）：{exc}") from exc

    raise SystemExit(f"从 data[].url 下载图片失败：{last_error}")


def image_bytes_from_item(item, index: int, api_key: str) -> bytes:
    if not isinstance(item, dict):
        raise SystemExit(
            f"响应 JSON 中 data[{index}] 不是对象（实际类型：{type(item).__name__}）。"
        )

    b64 = item.get("b64_json")
    if isinstance(b64, str) and b64.strip():
        try:
            return base64.b64decode(b64, validate=True)
        except Exception as exc:
            raise SystemExit(f"data[{index}] 中的 base64 图片数据无效：{exc}") from exc

    url = item.get("url")
    if isinstance(url, str) and url.strip():
        return fetch_url_bytes(url.strip(), api_key)

    keys = ", ".join(item_keys(item)) or "(empty)"
    raise SystemExit(
        f"响应 JSON 中缺少 data[{index}].b64_json（也没有可用的 data[{index}].url）。"
        f"实际字段：{keys}。"
    )


try:
    response = json.loads(response_path.read_text(encoding="utf-8"))
except Exception as exc:
    raise SystemExit(f"响应不是合法的 JSON：{exc}")

if isinstance(response, dict) and response.get("error"):
    err = response.get("error")
    if isinstance(err, dict):
        message = err.get("message") or err.get("code") or json.dumps(err, ensure_ascii=False)
    else:
        message = str(err)
    raise SystemExit(f"接口返回错误：{message}")

data = response.get("data") if isinstance(response, dict) else None
if not isinstance(data, list) or not data:
    top = ", ".join(sorted(response.keys())) if isinstance(response, dict) else type(response).__name__
    raise SystemExit(f"响应 JSON 中缺少 data[0]。顶层字段：{top}。")


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
    image_bytes = image_bytes_from_item(item, index, api_key)
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