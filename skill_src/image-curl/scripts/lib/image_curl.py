#!/usr/bin/env python3
"""image-curl core: one implementation behind the .sh and .ps1 entry scripts.

Subcommands: generate, edit, generate-batch (alias generate_batch), models, help.

Providers
  openai  POST {base}/v1/images/generations | /v1/images/edits   (Authorization: Bearer)
  gemini  POST {base}/v1beta/models/{model}:generateContent      (x-goog-api-key)

The provider follows the model name (gemini-* / *nano-banana* -> gemini) unless
--provider is given. HTTP goes through the system curl; headers carrying the key
are passed on stdin (curl -K -), never on the command line.

PowerShell passes its arguments as a JSON file (--argv-file) so Windows
PowerShell 5.1 cannot mangle quotes, spaces or '#'.
"""
from __future__ import annotations

import argparse
import base64
import contextlib
import copy
import io
import json
import mimetypes
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, NoReturn
from urllib import error as urlerror
from urllib import request as urlrequest

# Installed skill dirs may be read-only; do not drop __pycache__ next to the scripts.
sys.dont_write_bytecode = True
LIB_DIR = Path(__file__).resolve().parent
SKILL_DIR = LIB_DIR.parent.parent
sys.path.insert(0, str(LIB_DIR))

import normalize_size  # noqa: E402
import parse_batch_jsonl  # noqa: E402
import thread_state  # noqa: E402

DEFAULT_BASE_URL = "https://aicode.cat"
DEFAULT_OPENAI_MODEL = "gpt-image-2"
DEFAULT_GEMINI_MODEL = "gemini-nano-banana-2.1"
DEFAULT_SIZE = "1024x1024"
DEFAULT_TIMEOUT = 300
DEFAULT_RETRIES = 3
MAX_COUNT = 10
GEMINI_MAX_REFERENCE_IMAGES = 14
GEMINI_MAX_INLINE_BYTES = 20 * 1024 * 1024
GEMINI_COUNT_WORKERS = 4
URL_FETCH_TIMEOUT = 120
RETRYABLE_HTTP = {429, 500, 502, 503, 504}
RETRYABLE_CURL_EXIT = {6, 7, 35, 52, 55, 56}
OUTPUT_FORMATS = ("png", "jpeg", "webp")
MIME_EXTENSIONS = {"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp"}
GEMINI_INPUT_MIME = ("image/png", "image/jpeg", "image/webp", "image/heic", "image/heif")
GEMINI_SAFETY_REASONS = frozenset({"SAFETY", "IMAGE_SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST"})

_print_lock = threading.Lock()


class CliError(Exception):
    """User-facing error; printed as `错误：<message>` with exit code 1."""


class RetryableError(CliError):
    """A failure worth another attempt (no image in response, 5xx, network)."""


def warn(message: str) -> None:
    with _print_lock:
        print(f"警告：{message}", file=sys.stderr)


def emit(text: str) -> None:
    with _print_lock:
        print(text)


def first_non_empty(*values: Any) -> str:
    for value in values:
        if isinstance(value, str) and value.strip():
            return value.strip()
    return ""


def call_lib(fn: Callable[..., Any], *args: Any, **kwargs: Any) -> Any:
    """Run a helper that reports errors by printing + SystemExit; turn that into CliError."""
    buffer = io.StringIO()
    try:
        with contextlib.redirect_stderr(buffer):
            result = fn(*args, **kwargs)
    except SystemExit as exc:
        message = buffer.getvalue().strip() or f"exit {exc.code}"
        raise CliError(message) from None
    leftover = buffer.getvalue().strip()
    if leftover:
        print(leftover, file=sys.stderr)
    return result


def normalize_path(path: Path | str) -> str:
    return str(path).replace("\\", "/")


def sanitize_path_segment(value: str) -> str:
    sanitized = "".join(ch if ch.isascii() and (ch.isalnum() or ch in "-_") else "_" for ch in value)
    return sanitized or "generated_image"


# ---------------------------------------------------------------------------
# local.env and configuration
# ---------------------------------------------------------------------------

ENV_LINE = re.compile(r"^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$")


def parse_env_file(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = ENV_LINE.match(line)
        if not match:
            continue
        key, value = match.group(1), match.group(2).strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        else:
            value = re.split(r"\s+#", value, maxsplit=1)[0].strip()
        values[key] = value
    return values


def load_local_env(skill_dir: Path = SKILL_DIR) -> Path | None:
    """Load skill-dir local.env into os.environ; file values win (same as `source`)."""
    path = Path(os.environ.get("IMAGE_CURL_ENV_FILE") or (skill_dir / "local.env")).expanduser()
    if not path.is_file():
        return None
    for key, value in parse_env_file(path.read_text(encoding="utf-8-sig")).items():
        os.environ[key] = value
    return path


def codex_home() -> Path:
    return Path(first_non_empty(os.environ.get("CODEX_HOME")) or Path.home() / ".codex").expanduser()


def resolve_base_url(override: str | None) -> str:
    return first_non_empty(override, os.environ.get("IMAGE_CURL_BASE_URL"), DEFAULT_BASE_URL).rstrip("/")


def read_auth_json_key() -> str:
    auth_path = codex_home() / "auth.json"
    if not auth_path.is_file():
        return ""
    try:
        auth = json.loads(auth_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return ""
    if not isinstance(auth, dict):
        return ""
    return first_non_empty(
        auth.get("OPENAI_API_KEY"),
        auth.get("OPENAI_API_TOKEN"),
        auth.get("api_key"),
        auth.get("token"),
        auth.get("openai_api_key"),
    )


def resolve_api_key(provider: str, override: str | None) -> tuple[str, str]:
    """Return (key, source label). Gemini falls back to IMAGE_CURL_API_KEY for composite keys."""
    if first_non_empty(override):
        return first_non_empty(override), "--api-key"
    if provider == "gemini":
        names = ("IMAGE_CURL_GEMINI_API_KEY", "IMAGE_CURL_API_KEY")
    else:
        names = ("IMAGE_CURL_API_KEY", "OPENAI_API_KEY", "CLIPROXY_API_KEY")
    for name in names:
        value = first_non_empty(os.environ.get(name))
        if value:
            return value, name
    if provider == "openai":
        value = read_auth_json_key()
        if value:
            return value, "auth.json"
    return "", ""


def key_var_for(provider: str) -> str:
    return "IMAGE_CURL_GEMINI_API_KEY" if provider == "gemini" else "IMAGE_CURL_API_KEY"


def infer_provider(model: str) -> str:
    lowered = model.lower()
    if lowered.startswith("gemini") or "nano-banana" in lowered:
        return "gemini"
    return "openai"


def resolve_model_and_provider(model: str | None, provider: str | None) -> tuple[str, str]:
    provider = (provider or "auto").strip().lower()
    if provider not in ("auto", "openai", "gemini"):
        raise CliError("--provider 须为 auto、openai 或 gemini。")
    model = first_non_empty(model)
    if not model:
        if provider == "gemini":
            model = first_non_empty(os.environ.get("IMAGE_CURL_GEMINI_MODEL"), DEFAULT_GEMINI_MODEL)
        else:
            model = first_non_empty(os.environ.get("IMAGE_CURL_MODEL"), DEFAULT_OPENAI_MODEL)
    if provider == "auto":
        provider = infer_provider(model)
    return model, provider


def gateway_root(base_url: str) -> str:
    root = base_url.rstrip("/")
    for suffix in ("/v1beta", "/v1"):
        if root.endswith(suffix):
            return root[: -len(suffix)]
    return root


def openai_endpoint(base_url: str, kind: str) -> str:
    route_base = base_url.rstrip("/")
    if route_base.endswith("/v1"):
        return f"{route_base}/images/{kind}"
    return f"{gateway_root(route_base)}/v1/images/{kind}"


def gemini_endpoint(base_url: str, model: str) -> str:
    return f"{gateway_root(base_url)}/v1beta/models/{model}:generateContent"


# ---------------------------------------------------------------------------
# Sizes
# ---------------------------------------------------------------------------


@dataclass
class SizePlan:
    requested: str
    api_size: str = ""
    aspect_ratio: str | None = None
    image_size: str | None = None
    note: str | None = None
    explicit_dimension: bool = False


def load_size_catalog() -> dict[str, Any]:
    return call_lib(normalize_size.load_allowed_sizes_catalog)


def resolve_openai_size(spec: str) -> SizePlan:
    api_size, note, explicit = call_lib(normalize_size.normalize_image_size, spec)
    return SizePlan(requested=spec, api_size=api_size.lower(), note=note, explicit_dimension=bool(explicit))


def gemini_size_summary(catalog: dict[str, Any]) -> str:
    ratios = "、".join(catalog["aspect_ratios"])
    tiers = "、".join(tier.lower() for tier in catalog["image_sizes"])
    return f"宽高比 {ratios}；档位 {tiers}；写法如 16:9、9:16@2k、2k、4k@16:9、auto"


def resolve_gemini_size(spec: str, *, default_auto: bool = False) -> SizePlan:
    """Map --size to Gemini imageConfig {aspectRatio, imageSize}.

    Accepts: auto | <ratio> | <tier> | <ratio>@<tier> | <tier>@<ratio> | 1024x1024 | 1280x720.
    default_auto: the user did not pass --size (edit keeps the input image's ratio).
    """
    catalog = load_size_catalog().get("gemini")
    if not isinstance(catalog, dict):
        raise CliError("allowed_sizes.json 缺少 gemini 尺寸表。")
    if default_auto:
        return SizePlan(requested="auto", note="未指定 --size：沿用输入图比例")
    canonical = normalize_size.canonicalize_size_spec(spec)
    ratios = list(catalog["aspect_ratios"])
    tiers = {tier.lower(): tier for tier in catalog["image_sizes"]}

    for item in catalog.get("forbidden", []):
        if normalize_size.canonicalize_size_spec(item["input"]) == canonical:
            alternatives = "、".join(f"`{value}`" for value in item.get("use_instead", []))
            raise CliError(f"Gemini 不要用 `{spec.strip()}`：{item.get('reason', '不支持')}。请改用：{alternatives}。")
    if canonical == "auto":
        return SizePlan(requested=spec, note="aspectRatio 由模型决定")
    for item in catalog.get("pixel_aliases", []):
        if normalize_size.canonicalize_size_spec(item["input"]) == canonical:
            return SizePlan(
                requested=spec,
                aspect_ratio=item["aspect_ratio"],
                image_size=item["image_size"],
                note=f"Gemini {spec.strip()} -> aspectRatio={item['aspect_ratio']} imageSize={item['image_size']}",
            )

    ratio = catalog.get("default_aspect_ratio", "1:1")
    tier = catalog.get("default_image_size", "1K")
    parts = canonical.split("@")
    if len(parts) > 2 or not all(parts):
        raise CliError(f"不支持的 Gemini --size `{spec.strip()}`。{gemini_size_summary(catalog)}。")
    seen_ratio = seen_tier = False
    for part in parts:
        if ":" in part:
            if seen_ratio or part not in ratios:
                raise CliError(f"Gemini 不支持宽高比 `{part}`。{gemini_size_summary(catalog)}。")
            ratio, seen_ratio = part, True
        elif part in tiers:
            if seen_tier:
                raise CliError(f"不支持的 Gemini --size `{spec.strip()}`。{gemini_size_summary(catalog)}。")
            tier, seen_tier = tiers[part], True
        else:
            raise CliError(f"不支持的 Gemini --size `{spec.strip()}`。{gemini_size_summary(catalog)}。")
    return SizePlan(
        requested=spec,
        aspect_ratio=ratio,
        image_size=tier,
        note=f"Gemini {spec.strip()} -> aspectRatio={ratio} imageSize={tier}",
    )


# ---------------------------------------------------------------------------
# Output paths
# ---------------------------------------------------------------------------


def thread_id() -> str:
    value = first_non_empty(os.environ.get("CODEX_THREAD_ID"), os.environ.get("CODEX_SESSION_ID"))
    return value or "manual"


def is_writable_dir(path: Path) -> bool:
    try:
        path.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=path, delete=True):
            pass
        return True
    except OSError:
        return False


def default_output_dir() -> Path:
    segment = sanitize_path_segment(thread_id())
    candidates: list[Path] = []
    override = first_non_empty(os.environ.get("IMAGE_CURL_OUTPUT_DIR"))
    if override:
        candidates.append(Path(override).expanduser())
    candidates.append(codex_home() / "generated_images")
    candidates.append(Path.cwd() / ".image-curl-output")
    for base in candidates:
        if is_writable_dir(base / segment):
            return (base / segment).resolve()
    return (candidates[-1] / segment).resolve()


def resolve_output_path(explicit: str, output_dir: str, name: str, extension: str) -> Path:
    if explicit.strip():
        path = Path(explicit).expanduser()
        if path.suffix == "":
            path = path.with_suffix(extension)
        return path.resolve()
    if output_dir.strip():
        base_dir = Path(output_dir).expanduser().resolve()
    else:
        base_dir = default_output_dir()
    prefix = sanitize_path_segment(name.strip() or "generated")
    return base_dir / f"{prefix}-{uuid.uuid4().hex[:8]}{extension}"


def output_targets(output: Path, count: int) -> list[Path]:
    if count == 1:
        return [output]
    return [output.with_name(f"{output.stem}-{index}{output.suffix}") for index in range(1, count + 1)]


def assert_targets_available(targets: list[Path], overwrite: bool) -> None:
    if overwrite:
        return
    conflicts = [normalize_path(target) for target in targets if target.exists()]
    if conflicts:
        raise CliError(f"输出文件已存在：{', '.join(conflicts)}（如需覆盖请加 --overwrite）")


# ---------------------------------------------------------------------------
# curl transport
# ---------------------------------------------------------------------------


@dataclass
class HttpResponse:
    status: int
    body: bytes

    def json(self) -> Any:
        try:
            return json.loads(self.body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            snippet = self.body[:300].decode("utf-8", errors="replace")
            raise CliError(f"响应不是合法的 JSON（HTTP {self.status}）：{exc}；正文开头：{snippet!r}") from None


def curl_config_header(name: str, value: str) -> str:
    escaped = f"{name}: {value}".replace("\\", "\\\\").replace('"', '\\"')
    return f'header = "{escaped}"\n'


def curl_binary() -> str:
    found = shutil.which("curl")
    if not found:
        raise CliError("未找到 curl。macOS / Linux 请安装 curl；Windows 请启用系统自带的 curl.exe。")
    return found


def run_curl(
    method: str,
    url: str,
    *,
    headers: dict[str, str],
    timeout: int,
    data_file: Path | None = None,
    form: list[tuple[str, str]] | None = None,
) -> HttpResponse:
    with tempfile.TemporaryDirectory(prefix="image-curl-") as tmp:
        body_path = Path(tmp) / "body"
        cmd = [
            curl_binary(),
            "-sS",
            "-X",
            method,
            url,
            "--max-time",
            str(timeout),
            "-o",
            str(body_path),
            "-w",
            "%{http_code}",
            "-K",
            "-",
        ]
        if data_file is not None:
            cmd += ["--data-binary", f"@{data_file}"]
        for flag, value in form or []:
            cmd += [flag, value]
        config = "".join(curl_config_header(name, value) for name, value in headers.items())
        proc = subprocess.run(cmd, input=config.encode("utf-8"), capture_output=True)
        if proc.returncode != 0:
            detail = proc.stderr.decode("utf-8", errors="replace").strip()
            error_cls = RetryableError if proc.returncode in RETRYABLE_CURL_EXIT else CliError
            if proc.returncode == 28:
                detail += f"（超过 --timeout {timeout} 秒；4K 图可能需要更久）"
            raise error_cls(f"curl 请求失败（exit {proc.returncode}）：{detail}")
        status_text = proc.stdout.decode("ascii", errors="replace").strip()
        status = int(status_text) if status_text.isdigit() else 0
        body = body_path.read_bytes() if body_path.exists() else b""
        return HttpResponse(status=status, body=body)


def api_error_message(response: HttpResponse) -> str:
    try:
        data = json.loads(response.body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return response.body[:300].decode("utf-8", errors="replace").strip() or "(空响应)"
    err = data.get("error") if isinstance(data, dict) else None
    if isinstance(err, dict):
        return str(err.get("message") or err.get("status") or err.get("code") or json.dumps(err, ensure_ascii=False))
    if err:
        return str(err)
    return json.dumps(data, ensure_ascii=False)[:300]


ERROR_HINTS: tuple[tuple[str, str], ...] = (
    (
        "group platform",
        "这个 Key 不是 Gemini 分组的 Key；请在 local.env 设置 IMAGE_CURL_GEMINI_API_KEY（Gemini 生图分组的 Key）。",
    ),
    (
        "images api",
        "这个 Key 的分组不支持 Images API（例如 Gemini 分组）；GPT 生图请用 GPT 生图分组的 Key，或改用 gemini 模型。",
    ),
    ("not available for this group", "当前 Key 的分组没有这个模型；运行 `image-curl models` 查看可用模型。"),
)


def api_error_hint(provider: str, status: int, message: str) -> str:
    if status == 401:
        return f"Key 无效或已删除，请检查 local.env 的 {key_var_for(provider)}。"
    lowered = message.lower()
    for needle, hint in ERROR_HINTS:
        if lowered.find(needle) >= 0:
            return hint
    if status == 429:
        return "请求过于频繁或额度不足，稍后再试。"
    return ""


def raise_for_status(provider: str, response: HttpResponse) -> None:
    if 200 <= response.status < 300:
        return
    message = api_error_message(response)
    hint = api_error_hint(provider, response.status, message)
    text = f"接口返回 HTTP {response.status}：{message}"
    if hint:
        text += f"。{hint}"
    if response.status in RETRYABLE_HTTP:
        raise RetryableError(text)
    raise CliError(text)


def with_retries(action: Callable[[], Any], *, label: str) -> Any:
    raw = os.environ.get("IMAGE_CURL_SAVE_RETRIES", "")
    attempts = int(raw) if raw.isdigit() and int(raw) >= 1 else DEFAULT_RETRIES
    for attempt in range(1, attempts + 1):
        try:
            return action()
        except RetryableError as exc:
            if attempt >= attempts:
                raise CliError(str(exc)) from None
            warn(f"{label}第 {attempt}/{attempts} 次失败，正在重试：{exc}")
            time.sleep(min(2 * attempt, 6))
    raise CliError(f"{label}失败")


# ---------------------------------------------------------------------------
# OpenAI Images API
# ---------------------------------------------------------------------------

DATA_URL_PATTERN = re.compile(r"^data:(?P<mime>[\w.+/-]+)?(?P<b64>;base64)?,(?P<data>.*)$", re.IGNORECASE | re.DOTALL)


def decode_data_url(raw: str) -> bytes:
    match = DATA_URL_PATTERN.match(raw.strip())
    if not match:
        raise ValueError("不是合法的 data URL")
    if match.group("b64"):
        return base64.b64decode(match.group("data"), validate=False)
    from urllib.parse import unquote_to_bytes

    return unquote_to_bytes(match.group("data"))


def fetch_url_bytes(url: str, api_key: str) -> bytes:
    """Download data[].url. Anonymous first (S3 pre-signed URLs break with extra headers),
    then Bearer when the host answers 401/403."""
    if url.lower().startswith("data:"):
        return decode_data_url(url)
    attempts: list[tuple[dict[str, str] | None, str]] = [(None, "无鉴权")]
    if api_key:
        attempts.append(({"Authorization": f"Bearer {api_key}"}, "Bearer"))
    last_error: Exception | None = None
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
            if headers is None and exc.code in (401, 403) and api_key:
                continue
            raise RetryableError(
                f"从 data[].url 下载图片失败（{label} HTTP {exc.code}）：{exc.reason}。"
                "若链接主机不接受当前 Key，请重试或要求网关返回 b64_json。"
            ) from None
        except Exception as exc:  # network errors
            last_error = exc
            if headers is None and api_key:
                continue
            raise RetryableError(f"从 data[].url 下载图片失败（{label}）：{exc}") from None
    raise RetryableError(f"从 data[].url 下载图片失败：{last_error}")


def openai_item_bytes(item: Any, index: int, api_key: str) -> bytes:
    if not isinstance(item, dict):
        raise CliError(f"响应 JSON 中 data[{index}] 不是对象（实际类型：{type(item).__name__}）。")
    b64 = item.get("b64_json")
    if isinstance(b64, str) and b64.strip():
        try:
            return base64.b64decode(b64, validate=True)
        except Exception as exc:
            raise CliError(f"data[{index}] 中的 base64 图片数据无效：{exc}") from None
    url = item.get("url")
    if isinstance(url, str) and url.strip():
        return fetch_url_bytes(url.strip(), api_key)
    keys = ", ".join(sorted(item.keys())) or "(empty)"
    raise RetryableError(f"响应 JSON 中缺少 data[{index}].b64_json（也没有可用的 data[{index}].url）。实际字段：{keys}。")


def save_openai_response(
    response: Any,
    output: Path,
    *,
    requested_count: int,
    api_key: str,
    metadata: Path | None,
) -> dict[str, Any]:
    if isinstance(response, dict) and response.get("error"):
        err = response["error"]
        message = err.get("message") or err.get("code") if isinstance(err, dict) else err
        raise CliError(f"接口返回错误：{message}")
    data = response.get("data") if isinstance(response, dict) else None
    if not isinstance(data, list) or not data:
        top = ", ".join(sorted(response.keys())) if isinstance(response, dict) else type(response).__name__
        raise RetryableError(f"响应 JSON 中缺少 data[0]。顶层字段：{top}。")

    # Same naming as before: one requested + one returned -> exact path, otherwise -1, -2, ...
    targets = output_targets(output, max(requested_count, len(data)) if requested_count > 1 or len(data) > 1 else 1)
    images = [openai_item_bytes(item, index, api_key) for index, item in enumerate(data)]
    saved: list[dict[str, Any]] = []
    for index, (item, image_bytes) in enumerate(zip(data, images)):
        target = targets[index]
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(image_bytes)
        saved.append({
            "file": normalize_path(target),
            "bytes": len(image_bytes),
            "revised_prompt": item.get("revised_prompt") if isinstance(item, dict) else None,
        })

    if metadata:
        sanitized = copy.deepcopy(response)
        for item in sanitized.get("data", []):
            if isinstance(item, dict) and "b64_json" in item:
                item["b64_json"] = "<omitted>"
        sanitized["saved_files"] = [entry["file"] for entry in saved]
        sanitized["requested_count"] = requested_count
        metadata.parent.mkdir(parents=True, exist_ok=True)
        metadata.write_text(json.dumps(sanitized, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    if requested_count == 1 and len(saved) == 1:
        return {"saved_file": saved[0]["file"], "bytes": saved[0]["bytes"], "revised_prompt": saved[0]["revised_prompt"]}
    return {"saved_files": saved, "requested_count": requested_count, "returned_count": len(saved)}


# ---------------------------------------------------------------------------
# Gemini generateContent
# ---------------------------------------------------------------------------


def sniff_image_mime(data: bytes, path: Path) -> str:
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if data[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    if data[4:12] in (b"ftypheic", b"ftypheix", b"ftyphevc", b"ftypmif1", b"ftypmsf1"):
        return "image/heic"
    if data[:6] in (b"GIF87a", b"GIF89a"):
        return "image/gif"
    guessed, _ = mimetypes.guess_type(path.name)
    return guessed or "application/octet-stream"


@dataclass
class InlineImage:
    path: Path
    mime: str
    size: int
    b64: str


def load_gemini_inputs(paths: list[Path]) -> list[InlineImage]:
    if len(paths) > GEMINI_MAX_REFERENCE_IMAGES:
        raise CliError(f"Gemini 一次最多 {GEMINI_MAX_REFERENCE_IMAGES} 张参考图，当前 {len(paths)} 张。")
    images: list[InlineImage] = []
    total = 0
    for path in paths:
        data = path.read_bytes()
        mime = sniff_image_mime(data, path)
        if mime not in GEMINI_INPUT_MIME:
            raise CliError(f"Gemini 不支持这种参考图格式（{mime}）：{normalize_path(path)}。请转成 PNG / JPEG / WebP。")
        total += len(data)
        images.append(InlineImage(path=path, mime=mime, size=len(data), b64=base64.b64encode(data).decode("ascii")))
    if total > GEMINI_MAX_INLINE_BYTES:
        raise CliError(f"参考图合计 {total // 1024 // 1024} MB，超过 Gemini 内联上限 20 MB；请先压缩或减少张数。")
    return images


def build_gemini_payload(prompt: str, images: list[InlineImage], size: SizePlan, *, redact: bool) -> dict[str, Any]:
    parts: list[dict[str, Any]] = []
    for image in images:
        data = f"<base64 {image.size} bytes: {normalize_path(image.path)}>" if redact else image.b64
        parts.append({"inlineData": {"mimeType": image.mime, "data": data}})
    parts.append({"text": prompt})
    generation: dict[str, Any] = {"responseModalities": ["TEXT", "IMAGE"]}
    image_config: dict[str, str] = {}
    if size.aspect_ratio:
        image_config["aspectRatio"] = size.aspect_ratio
    if size.image_size:
        image_config["imageSize"] = size.image_size
    if image_config:
        generation["imageConfig"] = image_config
    return {"contents": [{"role": "user", "parts": parts}], "generationConfig": generation}


def extract_gemini_image(response: Any) -> tuple[bytes, str, str]:
    """Return (image bytes, mime type, model text). The last non-thought image is the final one."""
    if not isinstance(response, dict):
        raise CliError(f"Gemini 响应不是 JSON 对象（实际类型：{type(response).__name__}）。")
    if response.get("error"):
        err = response["error"]
        message = err.get("message") if isinstance(err, dict) else err
        raise CliError(f"接口返回错误：{message}")
    feedback = response.get("promptFeedback") or {}
    if isinstance(feedback, dict) and feedback.get("blockReason"):
        raise CliError(f"提示词被安全策略拦截（blockReason={feedback['blockReason']}），请改写提示词。")

    found: tuple[bytes, str] | None = None
    texts: list[str] = []
    finish_reasons: list[str] = []
    for candidate in response.get("candidates") or []:
        if not isinstance(candidate, dict):
            continue
        if candidate.get("finishReason"):
            finish_reasons.append(str(candidate["finishReason"]))
        for part in (candidate.get("content") or {}).get("parts") or []:
            if not isinstance(part, dict) or part.get("thought"):
                continue
            inline = part.get("inlineData") or part.get("inline_data")
            if isinstance(inline, dict) and inline.get("data"):
                mime = inline.get("mimeType") or inline.get("mime_type") or "image/jpeg"
                try:
                    found = (base64.b64decode(inline["data"], validate=False), str(mime))
                except Exception as exc:
                    raise CliError(f"Gemini 返回的图片 base64 无效：{exc}") from None
            elif isinstance(part.get("text"), str) and part["text"].strip():
                texts.append(part["text"].strip())
    text = "\n".join(texts)
    if found is None:
        reason = "、".join(finish_reasons) or "未知"
        detail = f"；模型回复：{text[:300]}" if text else ""
        if GEMINI_SAFETY_REASONS.intersection(finish_reasons):
            raise RetryableError(f"图片被安全策略拦截（finishReason={reason}）{detail}")
        raise RetryableError(f"Gemini 没有返回图片（finishReason={reason}）{detail}")
    return found[0], found[1], text


def redact_gemini_response(response: Any) -> Any:
    sanitized = copy.deepcopy(response)
    candidates = (sanitized.get("candidates") or []) if isinstance(sanitized, dict) else []
    for candidate in candidates:
        for part in (candidate.get("content") or {}).get("parts") or []:
            inline = part.get("inlineData") or part.get("inline_data")
            if isinstance(inline, dict) and "data" in inline:
                inline["data"] = "<omitted>"
    return sanitized


def place_by_mime(target: Path, mime: str) -> Path:
    extension = MIME_EXTENSIONS.get(mime.lower())
    if not extension or target.suffix.lower() == extension or (extension == ".jpg" and target.suffix.lower() == ".jpeg"):
        return target
    warn(f"Gemini 返回的是 {mime}，已按真实格式保存为 {target.with_suffix(extension).name}")
    return target.with_suffix(extension)


# ---------------------------------------------------------------------------
# Tasks
# ---------------------------------------------------------------------------


@dataclass
class Task:
    kind: str  # generate | edit
    provider: str
    model: str
    prompt: str
    size: SizePlan
    count: int
    output: Path
    targets: list[Path]
    metadata: Path | None
    base_url: str
    api_key: str
    key_source: str
    timeout: int
    overwrite: bool
    quality: str = "auto"
    output_format: str = "png"
    output_compression: int | None = None
    moderation: str = "auto"
    background: str = ""
    images: list[Path] = field(default_factory=list)
    mask: Path | None = None
    input_fidelity: str = ""
    gemini_inputs: list[InlineImage] = field(default_factory=list)

    @property
    def endpoint(self) -> str:
        if self.provider == "gemini":
            return gemini_endpoint(self.base_url, self.model)
        return openai_endpoint(self.base_url, "edits" if self.kind == "edit" else "generations")


@dataclass
class Options:
    prompt: str = ""
    prompt_file: str = ""
    output: str = ""
    output_dir: str = ""
    name: str = ""
    model: str | None = None
    provider: str | None = None
    size: str | None = None
    quality: str = "auto"
    output_format: str | None = None
    output_compression: str = ""
    moderation: str = "auto"
    background: str = ""
    count: Any = 1
    metadata: str = ""
    base_url: str = ""
    api_key: str = ""
    timeout: Any = DEFAULT_TIMEOUT
    overwrite: bool = False
    dry_run: bool = False
    images: list[str] = field(default_factory=list)
    image_sets: list[str] = field(default_factory=list)
    mask: str = ""
    input_fidelity: str = ""
    explicit: set[str] = field(default_factory=set)


def parse_int(value: Any, label: str, low: int, high: int | None = None) -> int:
    text = str(value).strip()
    if not text.isdigit() or int(text) < low or (high is not None and int(text) > high):
        bound = f"{low} 至 {high} 之间的整数" if high is not None else "正整数"
        raise CliError(f"{label} 须为{bound}。")
    return int(text)


def read_prompt(opts: Options) -> str:
    if opts.prompt and opts.prompt_file:
        raise CliError("请只提供 --prompt 或 --prompt-file 其中之一，不可同时使用。")
    prompt = opts.prompt
    if opts.prompt_file:
        path = Path(opts.prompt_file).expanduser()
        if not path.is_file():
            raise CliError(f"未找到提示词文件：{opts.prompt_file}")
        prompt = path.read_text(encoding="utf-8-sig")
    prompt = prompt.strip()
    if not prompt:
        raise CliError("必须提供 --prompt 或 --prompt-file。")
    return prompt


def plan_task(kind: str, opts: Options, *, dry_run: bool, prompt: str | None = None) -> Task:
    model, provider = resolve_model_and_provider(opts.model, opts.provider)
    if kind == "generate" and not (opts.output or opts.output_dir or opts.name):
        raise CliError("必须提供 --output、--output-dir 或 --name 至少其一。")
    if kind == "edit" and not (opts.output or opts.output_dir or opts.name):
        raise CliError("必须提供 --output、--output-dir 或 --name 至少其一。")
    count = parse_int(opts.count, "--count/--n", 1, MAX_COUNT)
    timeout = parse_int(opts.timeout, "--timeout", 1)
    prompt = prompt if prompt is not None else read_prompt(opts)

    output_format = (opts.output_format or "png").strip().lower()
    if output_format == "jpg":
        output_format = "jpeg"
    if output_format not in OUTPUT_FORMATS:
        raise CliError("--format 须为 png、jpeg、jpg 或 webp。")
    compression: int | None = None
    if str(opts.output_compression).strip():
        compression = parse_int(opts.output_compression, "--output-compression", 0, 100)
        if output_format not in ("jpeg", "webp") and provider == "openai":
            raise CliError("--output-compression 仅适用于 jpeg 或 webp 输出。")
    if opts.input_fidelity and opts.input_fidelity not in ("low", "high"):
        raise CliError("--input-fidelity 须为 low 或 high。")

    size_spec = (opts.size or DEFAULT_SIZE).strip()
    if not size_spec:
        raise CliError("--size 不能为空。")
    if provider == "gemini":
        size = resolve_gemini_size(size_spec, default_auto=(kind == "edit" and opts.size is None))
        extension = ".jpg"
        ignored = [flag for flag in ("quality", "moderation", "background", "output_compression", "input_fidelity") if flag in opts.explicit]
        if "output_format" in opts.explicit and output_format != "jpeg":
            ignored.append("format")
        if ignored:
            warn("Gemini 生图不支持 " + "、".join(f"--{flag.replace('_', '-')}" for flag in ignored) + "，已忽略（Gemini 固定返回 JPEG）。")
        if opts.mask:
            raise CliError("Gemini 不支持 --mask；请在提示词里写清要改的区域，或改用 GPT 生图模型。")
    else:
        size = resolve_openai_size(size_spec)
        if size.explicit_dimension:
            prompt = call_lib(normalize_size.augment_prompt_for_spec, prompt, size_spec, size.api_size)
        extension = f".{output_format}"

    output = resolve_output_path(opts.output, opts.output_dir, opts.name, extension)
    if provider == "gemini" and output.suffix.lower() not in (".jpg", ".jpeg"):
        if opts.output:
            warn(f"Gemini 固定返回 JPEG，输出文件改为 {output.with_suffix('.jpg').name}")
        output = output.with_suffix(".jpg")
    targets = output_targets(output, count)
    assert_targets_available(targets, opts.overwrite)

    metadata = Path(opts.metadata).expanduser().resolve() if opts.metadata else None
    base_url = resolve_base_url(opts.base_url)
    api_key, key_source = resolve_api_key(provider, opts.api_key)
    if not dry_run and not api_key:
        raise CliError(
            f"未找到 API Key。请在 {normalize_path(SKILL_DIR / 'local.env')} 中设置 {key_var_for(provider)}，或传入 --api-key。"
        )

    task = Task(
        kind=kind,
        provider=provider,
        model=model,
        prompt=prompt,
        size=size,
        count=count,
        output=output,
        targets=targets,
        metadata=metadata,
        base_url=base_url,
        api_key=api_key,
        key_source=key_source,
        timeout=timeout,
        overwrite=opts.overwrite,
        quality=opts.quality,
        output_format=output_format,
        output_compression=compression,
        moderation=opts.moderation,
        background=opts.background.strip(),
        input_fidelity=opts.input_fidelity,
    )
    return task


def attach_edit_inputs(task: Task, opts: Options) -> None:
    if not opts.images and not opts.image_sets:
        raise CliError("至少需要 --image 或 --image-set 之一。")
    paths = call_lib(
        thread_state.resolve_edit_images,
        thread_id=thread_state.effective_thread_id(None),
        image_sets=list(opts.image_sets),
        images=list(opts.images),
    )
    task.images = [Path(path) for path in paths]
    if not task.images:
        raise CliError("未能解析任何输入图片。")
    if opts.mask:
        mask = Path(opts.mask).expanduser()
        if not mask.is_file():
            raise CliError(f"未找到蒙版文件：{opts.mask}")
        if mask.stat().st_size == 0:
            raise CliError(f"蒙版文件为空：{opts.mask}")
        task.mask = mask.resolve()
    if task.provider == "gemini":
        task.gemini_inputs = load_gemini_inputs(task.images)


def openai_json_payload(task: Task) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "model": task.model,
        "prompt": task.prompt,
        "size": task.size.api_size,
        "quality": task.quality,
        "output_format": task.output_format,
        "response_format": "b64_json",
        "moderation": task.moderation,
        "n": task.count,
    }
    if task.background:
        payload["background"] = task.background
    if task.output_compression is not None:
        payload["output_compression"] = task.output_compression
    return payload


def openai_multipart_preview(task: Task) -> dict[str, Any]:
    multipart = openai_json_payload(task)
    multipart.pop("background", None)
    multipart["image[]"] = [normalize_path(path) for path in task.images]
    if task.mask:
        multipart["mask"] = normalize_path(task.mask)
    if task.input_fidelity:
        multipart["input_fidelity"] = task.input_fidelity
    return multipart


def preview_task(task: Task) -> dict[str, Any]:
    preview: dict[str, Any] = {"endpoint": task.endpoint, "provider": task.provider, "model": task.model}
    if task.provider == "gemini":
        preview["authorization"] = "x-goog-api-key: ***"
        preview["payload"] = build_gemini_payload(task.prompt, task.gemini_inputs, task.size, redact=True)
    else:
        preview["authorization"] = "Bearer ***"
        if task.kind == "edit":
            preview["multipart"] = openai_multipart_preview(task)
        else:
            preview["payload"] = openai_json_payload(task)
    preview["output"] = normalize_path(task.output)
    if task.count > 1:
        preview["outputs"] = [normalize_path(path) for path in task.targets]
    preview["count"] = task.count
    preview["metadata"] = normalize_path(task.metadata) if task.metadata else None
    preview["api_key_source"] = task.key_source or None
    if task.size.note:
        preview["size_note"] = task.size.note
    return preview


def execute_openai(task: Task) -> dict[str, Any]:
    headers = {
        "Authorization": f"Bearer {task.api_key}",
        "Cache-Control": "no-store, no-cache, max-age=0",
        "Pragma": "no-cache",
    }

    def attempt() -> dict[str, Any]:
        with tempfile.TemporaryDirectory(prefix="image-curl-req-") as tmp:
            if task.kind == "edit":
                prompt_file = Path(tmp) / "prompt.txt"
                prompt_file.write_text(task.prompt, encoding="utf-8")
                form: list[tuple[str, str]] = [
                    ("--form-string", f"model={task.model}"),
                    ("-F", f"prompt=<{normalize_path(prompt_file)}"),
                    ("--form-string", f"size={task.size.api_size}"),
                    ("--form-string", f"quality={task.quality}"),
                    ("--form-string", f"output_format={task.output_format}"),
                    ("--form-string", "response_format=b64_json"),
                    ("--form-string", f"moderation={task.moderation}"),
                    ("--form-string", f"n={task.count}"),
                ]
                if task.output_compression is not None:
                    form.append(("--form-string", f"output_compression={task.output_compression}"))
                if task.input_fidelity:
                    form.append(("--form-string", f"input_fidelity={task.input_fidelity}"))
                for image in task.images:
                    form.append(("-F", f"image[]=@{normalize_path(image)}"))
                if task.mask:
                    form.append(("-F", f"mask=@{normalize_path(task.mask)}"))
                response = run_curl("POST", task.endpoint, headers=headers, timeout=task.timeout, form=form)
            else:
                body = Path(tmp) / "payload.json"
                body.write_text(json.dumps(openai_json_payload(task), ensure_ascii=False), encoding="utf-8")
                response = run_curl(
                    "POST",
                    task.endpoint,
                    headers={**headers, "Content-Type": "application/json"},
                    timeout=task.timeout,
                    data_file=body,
                )
        raise_for_status("openai", response)
        return save_openai_response(
            response.json(),
            task.output,
            requested_count=task.count,
            api_key=task.api_key,
            metadata=task.metadata,
        )

    return with_retries(attempt, label="生图请求")


def execute_gemini(task: Task) -> dict[str, Any]:
    payload = build_gemini_payload(task.prompt, task.gemini_inputs, task.size, redact=False)
    headers = {"x-goog-api-key": task.api_key, "Content-Type": "application/json"}
    with tempfile.TemporaryDirectory(prefix="image-curl-gemini-") as tmp:
        body = Path(tmp) / "payload.json"
        body.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")

        def one(index: int) -> dict[str, Any]:
            target = task.targets[index]

            def attempt() -> tuple[bytes, str, str, Any]:
                response = run_curl("POST", task.endpoint, headers=headers, timeout=task.timeout, data_file=body)
                raise_for_status("gemini", response)
                data = response.json()
                image_bytes, mime, text = extract_gemini_image(data)
                return image_bytes, mime, text, data

            label = f"第 {index + 1} 张图" if task.count > 1 else "生图请求"
            image_bytes, mime, text, data = with_retries(attempt, label=label)
            final = place_by_mime(target, mime)
            if final != target and final.exists() and not task.overwrite:
                raise CliError(f"输出文件已存在：{normalize_path(final)}（如需覆盖请加 --overwrite）")
            final.parent.mkdir(parents=True, exist_ok=True)
            final.write_bytes(image_bytes)
            entry: dict[str, Any] = {"file": normalize_path(final), "bytes": len(image_bytes), "mime_type": mime}
            if text:
                entry["text"] = text
            entry["_response"] = data
            return entry

        results: list[dict[str, Any] | None] = [None] * task.count
        errors: list[str] = []
        if task.count == 1:
            results[0] = one(0)
        else:
            with ThreadPoolExecutor(max_workers=min(task.count, GEMINI_COUNT_WORKERS)) as pool:
                futures = {pool.submit(one, index): index for index in range(task.count)}
                for future, index in futures.items():
                    try:
                        results[index] = future.result()
                    except CliError as exc:
                        errors.append(f"第 {index + 1} 张图失败：{exc}")

    saved = [entry for entry in results if entry]
    if task.metadata:
        meta = {
            "provider": "gemini",
            "model": task.model,
            "responses": [redact_gemini_response(entry.pop("_response")) for entry in saved],
            "saved_files": [entry["file"] for entry in saved],
            "requested_count": task.count,
        }
        task.metadata.parent.mkdir(parents=True, exist_ok=True)
        task.metadata.write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    for entry in saved:
        entry.pop("_response", None)

    if task.count == 1 and len(saved) == 1:
        result: dict[str, Any] = {"saved_file": saved[0]["file"], "bytes": saved[0]["bytes"], "mime_type": saved[0]["mime_type"]}
        if saved[0].get("text"):
            result["text"] = saved[0]["text"]
    else:
        result = {"saved_files": saved, "requested_count": task.count, "returned_count": len(saved)}
    if errors:
        result["errors"] = errors
        if not saved:
            raise CliError("；".join(errors))
    return result


def execute_task(task: Task) -> dict[str, Any]:
    if task.provider == "gemini":
        return execute_gemini(task)
    return execute_openai(task)


def saved_paths(result: dict[str, Any]) -> list[str]:
    if isinstance(result.get("saved_files"), list):
        paths = []
        for item in result["saved_files"]:
            if isinstance(item, dict) and (item.get("file") or item.get("path")):
                paths.append(item.get("file") or item.get("path"))
            elif isinstance(item, str):
                paths.append(item)
        return paths
    if result.get("saved_file"):
        return [result["saved_file"]]
    return []


def save_state(*, active_inputs: list[Path] | None = None, last_outputs: list[str] | None = None) -> None:
    tid = thread_state.effective_thread_id(None)
    if active_inputs:
        call_lib(thread_state.save_active_image_set, tid, [Path(p) for p in active_inputs])
    if last_outputs:
        call_lib(thread_state.save_last_output_set, tid, [Path(p) for p in last_outputs])


# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

GENERATE_USAGE = """用法：
  image-curl generate --prompt 文本 (--output 文件 | --output-dir 目录 | --name 前缀) [选项]

选项：
  --prompt TEXT / --prompt-file FILE   提示词（二选一）
  --output FILE         精确输出路径（优先于 --output-dir/--name）
  --output-dir DIR      输出目录；与 --name 组合成「前缀-随机后缀」
  --name PREFIX         文件名前缀；不给 --output-dir 时写入默认目录
                        （IMAGE_CURL_OUTPUT_DIR → ~/.codex/generated_images → ./.image-curl-output）
  --model NAME          模型，默认 gpt-image-2；gemini-* 模型自动走 Gemini 接口
  --provider P          auto（默认，按模型判断）、openai、gemini
  --size SIZE           GPT：白名单（1024x1024、16:9、9:16@2k、4k@16:9 等）
                        Gemini：宽高比[@档位]（1:1、16:9@2k、4:1、4k 等）
  --quality VALUE       GPT 专用，默认 auto
  --format FORMAT       GPT 专用：png、jpeg、webp，默认 png（Gemini 固定 JPEG）
  --output-compression N  GPT 专用：jpeg/webp 压缩 0-100
  --moderation VALUE    GPT 专用，默认 auto
  --background VALUE    GPT 专用，例如 transparent
  --count N, --n N      张数，默认 1，最大 10（Gemini 每张单独请求）
  --metadata FILE       保存响应 metadata（不含图片 base64）
  --base-url URL        默认 https://aicode.cat
  --api-key KEY         临时覆盖 Key；常规写入 skill 目录 local.env
  --timeout SECONDS     curl 超时，默认 300
  --overwrite           允许覆盖已有文件
  --dry-run             只打印脱敏请求，不调用接口
  -h, --help            显示帮助
"""

EDIT_USAGE = """用法：
  image-curl edit (--image 文件 | --image-set 选择器) --prompt 文本 (--output 文件 | --output-dir 目录 | --name 前缀) [选项]

在 generate 选项之外：
  --image FILE          输入图或占位符（[Image #N]、[Last Output] 等），可重复
  --image-set SELECTOR  active、last-output、latest-turn、turn:-K、thread:1,2,5，可重复
  --mask FILE           GPT 专用：PNG 蒙版，透明区为编辑区
  --input-fidelity V    GPT 专用：low 或 high
Gemini 改图：最多 14 张参考图；不给 --size 时沿用输入图比例。
"""

BATCH_USAGE = """用法：
  image-curl generate-batch --input prompts.jsonl --output-dir 目录 [选项]

选项：
  --input FILE          JSONL：每行一个字符串 prompt 或 job 对象
  --output-dir DIR      输出目录（必填）
  --concurrency N       并发数，默认 4，范围 1-25
  其余（--model、--provider、--size、--quality、--format、--output-compression、
  --moderation、--background、--count/--n、--metadata、--base-url、--api-key、
  --timeout、--overwrite、--dry-run）作为每个 job 的默认值。

job 字段：prompt、model、provider、size、quality、background、format、compression、
  moderation、n、name、out。同一批可混用 GPT 与 Gemini 模型。

示例：
  "画一只猫"
  {"prompt":"夕阳","size":"16:9","n":2,"name":"sunset-01"}
  {"prompt":"海报","model":"gemini-nano-banana-2.1","size":"9:16@2k","out":"./batch-out/poster.jpg"}
"""

MODELS_USAGE = """用法：
  image-curl models [--provider openai|gemini] [--base-url URL] [--api-key KEY]

列出已配置 Key 能用的模型：GPT 分组查 /v1/models，Gemini 分组查 /v1beta/models。
"""

MAIN_USAGE = """用法：
  image-curl.sh <子命令> [选项...]      （Windows：image-curl.ps1）

子命令：
  generate         文生图
  edit             图生图 / 改图
  generate-batch   批量文生图（别名 generate_batch）
  models           列出当前 Key 可用的模型
  help             显示帮助

示例：
  image-curl.sh generate --prompt "一只猫" --output ./cat.png
  image-curl.sh generate --model gemini-nano-banana-2.1 --prompt "一只猫" --size 16:9@2k --name cat
  image-curl.sh edit --image ./photo.png --prompt "换背景" --output ./out.png
  image-curl.sh generate-batch --input prompts.jsonl --output-dir ./batch-out
  image-curl.sh models

各子命令加 --help 查看详细选项。
"""


class ArgParser(argparse.ArgumentParser):
    def error(self, message: str) -> NoReturn:  # pragma: no cover - argparse internals
        raise CliError(message)


SHARED_FLAGS: list[tuple[tuple[str, ...], str, dict[str, Any]]] = [
    (("--model",), "model", {}),
    (("--provider",), "provider", {}),
    (("--size",), "size", {}),
    (("--quality",), "quality", {}),
    (("--format", "--output-format"), "output_format", {}),
    (("--output-compression",), "output_compression", {}),
    (("--moderation",), "moderation", {}),
    (("--background",), "background", {}),
    (("--count", "--n"), "count", {}),
    (("--metadata", "--metadata-path"), "metadata", {}),
    (("--base-url",), "base_url", {}),
    (("--api-key",), "api_key", {}),
    (("--timeout",), "timeout", {}),
]


def build_parser(command: str) -> ArgParser:
    parser = ArgParser(prog=f"image-curl {command}", add_help=False, allow_abbrev=False)
    parser.add_argument("-h", "--help", action="store_true", dest="help")
    for flags, dest, extra in SHARED_FLAGS:
        parser.add_argument(*flags, dest=dest, default=None, **extra)
    parser.add_argument("--overwrite", action="store_true")
    parser.add_argument("--dry-run", action="store_true", dest="dry_run")
    if command in ("generate", "edit"):
        parser.add_argument("--prompt", default=None)
        parser.add_argument("--prompt-file", dest="prompt_file", default=None)
        parser.add_argument("--output", default=None)
        parser.add_argument("--output-dir", dest="output_dir", default=None)
        parser.add_argument("--name", default=None)
        parser.add_argument("--image", action="append", dest="images", default=None)
    if command == "edit":
        parser.add_argument("--image-set", action="append", dest="image_sets", default=None)
        parser.add_argument("--mask", default=None)
        parser.add_argument("--input-fidelity", dest="input_fidelity", default=None)
    if command == "batch":
        parser.add_argument("--input", default=None)
        parser.add_argument("--output-dir", dest="output_dir", default=None)
        parser.add_argument("--concurrency", default="4")
        for flag in ("--prompt", "--prompt-file", "--output", "--name"):
            parser.add_argument(flag, dest=f"rejected_{flag.strip('-').replace('-', '_')}", default=None)
    return parser


def parse_options(command: str, argv: list[str]) -> tuple[Options, argparse.Namespace]:
    parser = build_parser(command)
    namespace, extras = parser.parse_known_args(argv)
    if extras:
        raise CliError(f"未知选项：{extras[0]}")
    opts = Options()
    for key, value in vars(namespace).items():
        if value is None or not hasattr(opts, key):
            continue
        setattr(opts, key, value)
        if key in ("quality", "output_format", "output_compression", "moderation", "background", "input_fidelity"):
            opts.explicit.add(key)
    opts.images = list(getattr(namespace, "images", None) or [])
    opts.image_sets = list(getattr(namespace, "image_sets", None) or [])
    return opts, namespace


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------


def cmd_generate(argv: list[str]) -> int:
    opts, ns = parse_options("generate", argv)
    if ns.help:
        print(GENERATE_USAGE, end="")
        return 0
    if opts.images:
        warn("generate 不支持 --image 输入；请使用 edit 进行改图。")
    task = plan_task("generate", opts, dry_run=opts.dry_run)
    if opts.dry_run:
        emit(json.dumps(preview_task(task), ensure_ascii=False, indent=2))
        return 0
    result = execute_task(task)
    save_state(last_outputs=saved_paths(result))
    emit(json.dumps(result, ensure_ascii=False))
    return 1 if result.get("errors") else 0


def cmd_edit(argv: list[str]) -> int:
    opts, ns = parse_options("edit", argv)
    if ns.help:
        print(EDIT_USAGE, end="")
        return 0
    if not opts.images and not opts.image_sets:
        raise CliError("至少需要 --image 或 --image-set 之一。")
    task = plan_task("edit", opts, dry_run=opts.dry_run)
    attach_edit_inputs(task, opts)
    if opts.dry_run:
        save_state(active_inputs=task.images)
        emit(json.dumps(preview_task(task), ensure_ascii=False, indent=2))
        return 0
    result = execute_task(task)
    save_state(active_inputs=task.images, last_outputs=saved_paths(result))
    emit(json.dumps(result, ensure_ascii=False))
    return 1 if result.get("errors") else 0


def batch_job_options(job: dict[str, Any], defaults: Options, output_dir: Path, index: int) -> Options:
    def pick(*values: Any) -> Any:
        for value in values:
            if value is None:
                continue
            if isinstance(value, str):
                if value.strip():
                    return value.strip()
                continue
            return value
        return None

    opts = Options(
        output=str(pick(job.get("out"), job.get("output")) or ""),
        output_dir=str(output_dir),
        name=str(pick(job.get("name")) or f"{index:03d}"),
        model=pick(job.get("model"), defaults.model),
        provider=pick(job.get("provider"), defaults.provider),
        size=pick(job.get("size"), defaults.size),
        quality=str(pick(job.get("quality"), defaults.quality) or "auto"),
        output_format=pick(job.get("format"), job.get("output_format"), defaults.output_format),
        output_compression=str(pick(job.get("output_compression"), job.get("compression"), defaults.output_compression) or ""),
        moderation=str(pick(job.get("moderation"), defaults.moderation) or "auto"),
        background=str(pick(job.get("background"), defaults.background) or ""),
        count=pick(job.get("n"), job.get("count"), defaults.count) or 1,
        metadata=str(pick(job.get("metadata"), job.get("metadata_path"), defaults.metadata) or ""),
        base_url=defaults.base_url,
        api_key=defaults.api_key,
        timeout=defaults.timeout,
        overwrite=defaults.overwrite,
    )
    opts.explicit = set(defaults.explicit)
    for key, explicit_name in (
        ("quality", "quality"),
        ("format", "output_format"),
        ("output_format", "output_format"),
        ("compression", "output_compression"),
        ("output_compression", "output_compression"),
        ("moderation", "moderation"),
        ("background", "background"),
    ):
        if job.get(key) not in (None, ""):
            opts.explicit.add(explicit_name)
    return opts


def cmd_batch(argv: list[str]) -> int:
    opts, ns = parse_options("batch", argv)
    if ns.help:
        print(BATCH_USAGE, end="")
        return 0
    for flag, message in (
        ("rejected_prompt", "generate-batch 不支持 --prompt；请使用 --input JSONL 文件。"),
        ("rejected_prompt_file", "generate-batch 不支持 --prompt-file；请使用 --input JSONL 文件。"),
        ("rejected_output", "generate-batch 不支持 --output；请使用 --output-dir 与 job 级 name/out。"),
        ("rejected_name", "generate-batch 不支持全局 --name；请在 JSONL 每行 job 中设置 name。"),
    ):
        if getattr(ns, flag, None) is not None:
            raise CliError(message)
    if not ns.input:
        raise CliError("必须提供 --input。")
    if not ns.output_dir:
        raise CliError("必须提供 --output-dir。")
    concurrency = parse_int(ns.concurrency, "--concurrency", 1, 25)
    try:
        jobs = parse_batch_jsonl.read_jobs_jsonl(ns.input)
    except ValueError as exc:
        raise CliError(str(exc)) from None
    output_dir = Path(ns.output_dir).expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    planned: list[tuple[int, Task]] = []
    failures: list[str] = []
    reserved: set[Path] = set()
    for index, job in enumerate(jobs, start=1):
        try:
            job_opts = batch_job_options(job, opts, output_dir, index)
            task = plan_task("generate", job_opts, dry_run=opts.dry_run, prompt=str(job["prompt"]).strip())
            clash = [normalize_path(path) for path in task.targets if path in reserved]
            if clash:
                raise CliError(f"与前面的 job 输出路径重复：{', '.join(clash)}")
            reserved.update(task.targets)
            planned.append((index, task))
        except CliError as exc:
            failures.append(f"job {index} failed: {exc}")

    if opts.dry_run:
        for index, task in planned:
            preview = {"job": index, **preview_task(task)}
            emit(json.dumps(preview, ensure_ascii=False, indent=2))
        if failures:
            print("\n".join(failures), file=sys.stderr)
            return 1
        return 0

    results: dict[int, dict[str, Any]] = {}

    def run(item: tuple[int, Task]) -> tuple[int, dict[str, Any] | None, str | None]:
        index, task = item
        try:
            return index, execute_task(task), None
        except CliError as exc:
            return index, None, f"job {index} failed: {exc}"

    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        for index, result, error in pool.map(run, planned):
            if error:
                failures.append(error)
            elif result is not None:
                results[index] = result
                for job_error in result.get("errors", []):
                    failures.append(f"job {index} failed: {job_error}")

    all_saved: list[str] = []
    for index in sorted(results):
        for path in saved_paths(results[index]):
            all_saved.append(path)
            emit(path)
    if all_saved:
        save_state(last_outputs=all_saved)
    if failures:
        failures.sort(key=lambda text: int(re.match(r"job (\d+)", text).group(1)) if re.match(r"job (\d+)", text) else 0)
        print("\n".join(failures), file=sys.stderr)
        return 1
    return 0


def fetch_models(provider: str, base_url: str, api_key: str, timeout: int) -> list[str]:
    root = gateway_root(base_url)
    if provider == "gemini":
        url, headers = f"{root}/v1beta/models", {"x-goog-api-key": api_key}
    else:
        url, headers = f"{root}/v1/models", {"Authorization": f"Bearer {api_key}"}
    response = run_curl("GET", url, headers=headers, timeout=timeout)
    raise_for_status(provider, response)
    data = response.json()
    if provider == "gemini":
        items = data.get("models", []) if isinstance(data, dict) else []
        names = [str(item.get("name", "")) for item in items if isinstance(item, dict)]
        return [name[len("models/"):] if name.startswith("models/") else name for name in names]
    items = data.get("data", []) if isinstance(data, dict) else []
    return [str(item.get("id", "")) for item in items if isinstance(item, dict)]


def cmd_models(argv: list[str]) -> int:
    parser = ArgParser(prog="image-curl models", add_help=False, allow_abbrev=False)
    parser.add_argument("-h", "--help", action="store_true", dest="help")
    parser.add_argument("--provider", default=None)
    parser.add_argument("--base-url", dest="base_url", default=None)
    parser.add_argument("--api-key", dest="api_key", default=None)
    parser.add_argument("--timeout", default="60")
    ns, extras = parser.parse_known_args(argv)
    if extras:
        raise CliError(f"未知选项：{extras[0]}")
    if ns.help:
        print(MODELS_USAGE, end="")
        return 0
    providers = [ns.provider] if ns.provider else ["openai", "gemini"]
    if any(p not in ("openai", "gemini") for p in providers):
        raise CliError("--provider 须为 openai 或 gemini。")
    base_url = resolve_base_url(ns.base_url)
    timeout = parse_int(ns.timeout, "--timeout", 1)
    report: dict[str, Any] = {"base_url": base_url}
    status = 0
    for provider in providers:
        api_key, source = resolve_api_key(provider, ns.api_key)
        if provider == "gemini" and source == "IMAGE_CURL_API_KEY" and not ns.provider:
            report[provider] = {"skipped": "未配置 IMAGE_CURL_GEMINI_API_KEY"}
            continue
        if not api_key:
            report[provider] = {"skipped": f"未配置 {key_var_for(provider)}"}
            continue
        try:
            report[provider] = {"key_source": source, "models": fetch_models(provider, base_url, api_key, timeout)}
        except CliError as exc:
            report[provider] = {"key_source": source, "error": str(exc)}
            status = 1
    emit(json.dumps(report, ensure_ascii=False, indent=2))
    return status


COMMANDS: dict[str, Callable[[list[str]], int]] = {
    "generate": cmd_generate,
    "edit": cmd_edit,
    "generate-batch": cmd_batch,
    "generate_batch": cmd_batch,
    "models": cmd_models,
}


def configure_stdio() -> None:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure") and (stream.encoding or "").lower().replace("-", "") != "utf8":
            try:
                stream.reconfigure(encoding="utf-8", errors="replace")
            except (OSError, ValueError):
                continue  # stream cannot be reconfigured (e.g. replaced by a test harness)


def main(argv: list[str] | None = None) -> int:
    configure_stdio()
    args = list(sys.argv[1:] if argv is None else argv)
    if args[:1] == ["--argv-file"]:
        if len(args) < 2:
            print("错误：--argv-file 需要文件路径。", file=sys.stderr)
            return 1
        try:
            loaded = json.loads(Path(args[1]).read_text(encoding="utf-8-sig"))
        except (OSError, json.JSONDecodeError) as exc:
            print(f"错误：无法读取参数文件 {args[1]}：{exc}", file=sys.stderr)
            return 1
        args = [str(item) for item in (loaded if isinstance(loaded, list) else [loaded])]
    if not args or args[0] in ("help", "-h", "--help"):
        print(MAIN_USAGE, end="")
        return 0
    command, rest = args[0], args[1:]
    handler = COMMANDS.get(command)
    if handler is None:
        print(f"未知子命令: {command}", file=sys.stderr)
        print(MAIN_USAGE, end="", file=sys.stderr)
        return 1
    load_local_env()
    try:
        return handler(rest)
    except CliError as exc:
        print(f"错误：{exc}", file=sys.stderr)
        return 1
    except OSError as exc:
        print(f"错误：文件读写失败：{exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("错误：已中断。", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
