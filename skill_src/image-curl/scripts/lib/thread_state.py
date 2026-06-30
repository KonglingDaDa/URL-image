#!/usr/bin/env python3
"""image-curl thread state: placeholders, rollout scan, active/last-output sets.

Edit does not implicitly inherit thread state; callers must pass placeholders or
--image-set selectors explicitly.

Without CODEX_THREAD_ID / CODEX_SESSION_ID the effective thread id is "manual":
  - local paths and [Last Output] (when state files exist) still resolve
  - rollout-backed placeholders and selectors require a real Codex thread id

Batch manifest hooks (module F) may extend resolve/save via additional selectors.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import mimetypes
import os
import re
import sys
from pathlib import Path
from typing import Iterable, NoReturn
from urllib import error, request
from urllib import parse as urlparse

ROLLOUT_MAX_BYTES = 8 * 1024 * 1024
THREAD_ATTACHMENT_MAX_TURNS = 256
THREAD_ATTACHMENT_MAX_IMAGES = 1024
IMAGE_MAX_EDIT_IMAGES = 16

ATTACHMENT_PLACEHOLDER_PATTERN = re.compile(r"^\s*\[Image\s*#\s*(\d+)\]\s*$", re.IGNORECASE)
TURN_ATTACHMENT_PLACEHOLDER_PATTERN = re.compile(
    r"^\s*\[Turn\s*(-\d+)\s+Image\s*#\s*(\d+)\]\s*$",
    re.IGNORECASE,
)
THREAD_ATTACHMENT_PLACEHOLDER_PATTERN = re.compile(
    r"^\s*\[Thread\s+Image\s*#\s*(\d+)\]\s*$",
    re.IGNORECASE,
)
LAST_OUTPUT_PLACEHOLDER_PATTERN = re.compile(
    r"^\s*\[Last\s+Output(?:\s*#\s*(\d+)\s*)?\]\s*$",
    re.IGNORECASE,
)
DATA_URL_IMAGE_PATTERN = re.compile(
    r"^\s*data:([a-zA-Z0-9.+-]+/[a-zA-Z0-9.+-]+);base64,(.+)\s*$",
    re.IGNORECASE | re.DOTALL,
)


def fail(message: str, *, status: int = 1) -> NoReturn:
    print(message, file=sys.stderr)
    raise SystemExit(status)


def sanitize_path_segment(value: str) -> str:
    sanitized = "".join(
        ch if ch.isascii() and (ch.isalnum() or ch in "-_") else "_"
        for ch in value
    )
    return sanitized or "generated_image"


def codex_home_dir() -> Path:
    return Path(os.environ.get("CODEX_HOME", "~/.codex")).expanduser()


def thread_output_dir(thread_id: str) -> Path:
    return codex_home_dir() / "generated_images" / sanitize_path_segment(thread_id)


def active_image_set_path(thread_id: str) -> Path:
    return thread_output_dir(thread_id) / "active_image_set.json"


def last_output_set_path(thread_id: str) -> Path:
    return thread_output_dir(thread_id) / "last_output_set.json"


def rollout_inline_image_dir(thread_id: str) -> Path:
    return thread_output_dir(thread_id) / "rollout_images"


def ensure_parent(path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    return path


def env_thread_id() -> str | None:
    thread_id = os.environ.get("CODEX_THREAD_ID") or os.environ.get("CODEX_SESSION_ID")
    if not thread_id:
        return None
    normalized = thread_id.strip()
    return normalized or None


def effective_thread_id(cli_thread_id: str | None = None) -> str:
    if cli_thread_id and cli_thread_id.strip():
        return cli_thread_id.strip()
    return env_thread_id() or "manual"


def requires_rollout_thread(thread_id: str) -> bool:
    """Rollout scan needs a real Codex thread id, not the manual fallback."""
    if thread_id != "manual":
        return False
    return env_thread_id() is None


def assert_rollout_thread(thread_id: str) -> None:
    if requires_rollout_thread(thread_id):
        fail(
            "rollout 占位符与 rollout 类 --image-set 选择器需要 CODEX_THREAD_ID "
            "或 CODEX_SESSION_ID；本地路径与 [Last Output] 在无会话时仍可使用。"
        )


def find_thread_rollout_path(thread_id: str) -> Path:
    sessions_dir = codex_home_dir() / "sessions"
    matches = sorted(sessions_dir.rglob(f"rollout-*-{thread_id}.jsonl"))
    if not matches:
        fail(f"未找到线程 {thread_id} 的 Codex session rollout 文件。")
    return matches[-1]


def resolve_existing_path(
    raw: str,
    *,
    base_dir: Path | None = None,
    allow_cwd_fallback: bool = True,
    allow_raw_relative_path: bool = True,
) -> Path | None:
    path = Path(raw).expanduser()
    candidates: list[Path] = []
    if path.is_absolute():
        candidates.append(path)
    else:
        if base_dir is not None:
            candidates.append((base_dir / path).expanduser())
        if allow_cwd_fallback:
            candidates.append((Path.cwd() / path).expanduser())
        if allow_raw_relative_path:
            candidates.append(path)

    seen: set[Path] = set()
    for candidate in candidates:
        if candidate in seen:
            continue
        seen.add(candidate)
        if candidate.is_file():
            return candidate.resolve()
    return None


def resolve_rollout_path(raw: str, *, rollout_cwd: Path | None) -> Path | None:
    return resolve_existing_path(
        raw,
        base_dir=rollout_cwd,
        allow_cwd_fallback=False,
        allow_raw_relative_path=False,
    )


def flatten_thread_attachments(
    attachment_turns: list[tuple[list[str], Path | None]],
) -> list[tuple[str, Path | None]]:
    flattened: list[tuple[str, Path | None]] = []
    for images, rollout_cwd in attachment_turns:
        for image in images:
            flattened.append((image, rollout_cwd))
            if len(flattened) > THREAD_ATTACHMENT_MAX_IMAGES:
                fail(
                    "线程附件历史过大，无法安全索引 "
                    f"(上限 {THREAD_ATTACHMENT_MAX_IMAGES} 张)"
                )
    return flattened


def cache_rollout_inline_image(thread_id: str, raw: str) -> str | None:
    match = DATA_URL_IMAGE_PATTERN.match(raw)
    if not match:
        return None
    mime = match.group(1).lower()
    if not mime.startswith("image/"):
        return None
    encoded = match.group(2).strip()
    try:
        decoded = base64.b64decode(encoded, validate=True)
    except Exception:
        return None

    suffix = mimetypes.guess_extension(mime) or ".img"
    if suffix == ".jpe":
        suffix = ".jpg"
    digest = hashlib.sha256(raw.encode("utf-8")).hexdigest()[:24]
    path = ensure_parent(rollout_inline_image_dir(thread_id) / f"{digest}{suffix}")
    if not path.is_file():
        path.write_bytes(decoded)
    return str(path.resolve())


def cache_rollout_remote_image(thread_id: str, raw: str) -> str | None:
    try:
        parsed = urlparse.urlparse(raw.strip())
    except ValueError:
        return None
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        return None

    try:
        with request.urlopen(raw, timeout=20) as response:
            content_type = response.headers.get_content_type().lower()
            if not content_type.startswith("image/"):
                return None
            decoded = response.read()
    except Exception:
        return None

    suffix = mimetypes.guess_extension(content_type) or Path(parsed.path).suffix or ".img"
    if suffix == ".jpe":
        suffix = ".jpg"
    digest = hashlib.sha256(raw.encode("utf-8")).hexdigest()[:24]
    path = ensure_parent(rollout_inline_image_dir(thread_id) / f"{digest}{suffix}")
    if not path.is_file():
        path.write_bytes(decoded)
    return str(path.resolve())


def resolve_rollout_image_reference(thread_id: str, raw: str) -> str | None:
    cached = cache_rollout_inline_image(thread_id, raw)
    if cached is not None:
        return cached
    cached = cache_rollout_remote_image(thread_id, raw)
    if cached is not None:
        return cached
    if isinstance(raw, str) and raw.strip():
        return raw
    return None


def read_thread_attachment_turns(thread_id: str) -> list[tuple[list[str], Path | None]]:
    assert_rollout_thread(thread_id)
    rollout_path = find_thread_rollout_path(thread_id)
    try:
        if rollout_path.stat().st_size > ROLLOUT_MAX_BYTES:
            fail(
                "Codex session rollout 过大，无法安全扫描附件占位符 "
                f"({rollout_path.stat().st_size} 字节 > {ROLLOUT_MAX_BYTES} 字节上限)"
            )
    except OSError as exc:
        fail(f"无法检查 rollout 文件 {rollout_path}：{exc}")

    default_rollout_cwd: Path | None = None
    current_turn_cwd: Path | None = None
    attachment_turns: list[tuple[list[str], Path | None]] = []

    for raw_line in rollout_path.read_text(encoding="utf-8").splitlines():
        if not raw_line.strip():
            continue
        try:
            entry = json.loads(raw_line)
        except json.JSONDecodeError as exc:
            fail(f"无法解析 rollout 文件 {rollout_path}：{exc}")

        payload = entry.get("payload")
        if not isinstance(payload, dict):
            continue

        if entry.get("type") == "session_meta":
            cwd = payload.get("cwd")
            if isinstance(cwd, str) and cwd.strip():
                default_rollout_cwd = Path(cwd).expanduser()
                current_turn_cwd = default_rollout_cwd
            continue

        if entry.get("type") == "turn_context":
            cwd = payload.get("cwd")
            if isinstance(cwd, str) and cwd.strip():
                current_turn_cwd = Path(cwd).expanduser()
            else:
                current_turn_cwd = default_rollout_cwd
            continue

        if entry.get("type") != "event_msg" or payload.get("type") != "user_message":
            continue

        resolved_images: list[str] = []
        local_images = payload.get("local_images")
        if isinstance(local_images, list):
            resolved_images.extend(
                str(item) for item in local_images if isinstance(item, str) and item.strip()
            )
        images = payload.get("images")
        if isinstance(images, list):
            resolved_images.extend(
                resolved
                for item in images
                if isinstance(item, str)
                for resolved in [resolve_rollout_image_reference(thread_id, item)]
                if resolved is not None
            )
        if resolved_images:
            attachment_turns.append((resolved_images, current_turn_cwd))
            if len(attachment_turns) > THREAD_ATTACHMENT_MAX_TURNS:
                fail(
                    "线程附件历史过大，无法安全扫描 "
                    f"(上限 {THREAD_ATTACHMENT_MAX_TURNS} 个含附件轮次)"
                )
    return attachment_turns


def load_thread_attachment_turns(thread_id: str) -> list[tuple[list[str], Path | None]]:
    attachment_turns = read_thread_attachment_turns(thread_id)
    if not attachment_turns:
        fail(
            "Codex session rollout 中未找到图片附件；"
            "请使用真实文件路径，或先在当前会话中附加图片。"
        )
    return attachment_turns


def latest_attachment_turn(thread_id: str) -> tuple[list[str], Path | None] | None:
    attachment_turns = read_thread_attachment_turns(thread_id)
    if not attachment_turns:
        return None
    return attachment_turns[-1]


def dedupe_paths(paths: Iterable[Path]) -> list[Path]:
    unique: list[Path] = []
    seen: set[Path] = set()
    for path in paths:
        resolved = path.resolve()
        if resolved in seen:
            continue
        seen.add(resolved)
        unique.append(resolved)
    return unique


def load_active_image_set(thread_id: str) -> list[Path]:
    path = active_image_set_path(thread_id)
    if not path.is_file():
        return []
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"无法读取 active_image_set {path}：{exc}")

    raw_images = payload.get("images")
    if not isinstance(raw_images, list):
        return []

    resolved_paths: list[Path] = []
    for item in raw_images:
        if not isinstance(item, str):
            continue
        resolved = resolve_existing_path(item)
        if resolved is not None:
            resolved_paths.append(resolved)
    return dedupe_paths(resolved_paths)


def save_active_image_set(thread_id: str, images: list[Path]) -> None:
    path = active_image_set_path(thread_id)
    ensure_parent(path)
    payload = {
        "thread_id": thread_id,
        "images": [str(path_item.resolve()) for path_item in dedupe_paths(images)],
    }
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def load_last_output_set(thread_id: str) -> list[Path]:
    path = last_output_set_path(thread_id)
    if not path.is_file():
        return []
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"无法读取 last_output_set {path}：{exc}")

    raw_images = payload.get("images")
    if not isinstance(raw_images, list):
        return []

    resolved_paths: list[Path] = []
    for item in raw_images:
        if not isinstance(item, str):
            continue
        resolved = resolve_existing_path(item)
        if resolved is not None:
            resolved_paths.append(resolved)
    return dedupe_paths(resolved_paths)


def save_last_output_set(thread_id: str, images: list[Path]) -> None:
    path = last_output_set_path(thread_id)
    ensure_parent(path)
    payload = {
        "thread_id": thread_id,
        "images": [str(path_item.resolve()) for path_item in dedupe_paths(images)],
    }
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def resolve_image_set_selector(selector: str, thread_id: str) -> list[Path]:
    normalized = selector.strip()
    if normalized == "active":
        return load_active_image_set(thread_id)
    if normalized == "last-output":
        return load_last_output_set(thread_id)
    if normalized == "latest-turn":
        assert_rollout_thread(thread_id)
        latest = latest_attachment_turn(thread_id)
        if latest is None:
            return []
        images, rollout_cwd = latest
        return [
            resolve_attachment_from_turn(str(index), images=images, rollout_cwd=rollout_cwd)
            for index in range(1, len(images) + 1)
        ]
    if normalized.startswith("turn:"):
        assert_rollout_thread(thread_id)
        offset_text = normalized.split(":", 1)[1].strip()
        try:
            offset = int(offset_text)
        except ValueError:
            fail(f"无效的 --image-set 选择器：{selector}")
        if offset >= 0:
            fail(f"turn 类 --image-set 选择器须使用负偏移：{selector}")
        attachment_turns = load_thread_attachment_turns(thread_id)
        turn_index = len(attachment_turns) - 1 + offset
        if turn_index < 0 or turn_index >= len(attachment_turns):
            fail(
                f"--image-set {selector} 超出本线程范围 "
                f"（共 {len(attachment_turns)} 个含附件轮次）"
            )
        images, rollout_cwd = attachment_turns[turn_index]
        return [
            resolve_attachment_from_turn(str(index), images=images, rollout_cwd=rollout_cwd)
            for index in range(1, len(images) + 1)
        ]
    if normalized.startswith("thread:"):
        assert_rollout_thread(thread_id)
        indexes_text = normalized.split(":", 1)[1].strip()
        if not indexes_text:
            fail(f"无效的 --image-set 选择器：{selector}")
        attachment_turns = load_thread_attachment_turns(thread_id)
        flattened = flatten_thread_attachments(attachment_turns)
        selected_paths: list[Path] = []
        for chunk in indexes_text.split(","):
            chunk = chunk.strip()
            try:
                index = int(chunk) - 1
            except ValueError:
                fail(f"无效的 --image-set 选择器：{selector}")
            if index < 0 or index >= len(flattened):
                fail(
                    f"--image-set {selector} 超出本线程范围 "
                    f"（共 {len(flattened)} 个附件）"
                )
            image, rollout_cwd = flattened[index]
            resolved = resolve_rollout_path(image, rollout_cwd=rollout_cwd)
            if resolved is None:
                cwd_text = f"（rollout cwd：{rollout_cwd}）" if rollout_cwd is not None else ""
                fail(f"无法将附件路径解析为文件：{image}{cwd_text}")
            selected_paths.append(resolved)
        return dedupe_paths(selected_paths)
    fail(f"不支持的 --image-set 选择器：{selector}")


def resolve_flattened_attachment(image: str, *, rollout_cwd: Path | None) -> Path:
    resolved = resolve_rollout_path(image, rollout_cwd=rollout_cwd)
    if resolved is None:
        cwd_text = f"（rollout cwd：{rollout_cwd}）" if rollout_cwd is not None else ""
        fail(f"无法将附件路径解析为文件：{image}{cwd_text}")
    return resolved


def resolve_attachment_from_turn(
    raw: str,
    *,
    images: list[str],
    rollout_cwd: Path | None,
) -> Path:
    index = int(raw) - 1
    if index < 0 or index >= len(images):
        fail(
            f"附件占位符索引 {index + 1} 超出所选轮次范围 "
            f"（共 {len(images)} 张）"
        )
    selected = images[index]
    return resolve_flattened_attachment(selected, rollout_cwd=rollout_cwd)


def resolve_dash_image_sequence(raw_values: list[str], thread_id: str) -> list[Path] | None:
    if not raw_values or not all(raw.strip() == "-" for raw in raw_values):
        return None
    attachment_turns = load_thread_attachment_turns(thread_id)
    latest_images, latest_rollout_cwd = attachment_turns[-1]
    if len(raw_values) <= len(latest_images):
        return [
            resolve_attachment_from_turn(str(index), images=latest_images, rollout_cwd=latest_rollout_cwd)
            for index in range(1, len(raw_values) + 1)
        ]
    flattened = flatten_thread_attachments(attachment_turns)
    if len(raw_values) <= len(flattened):
        return [
            resolve_flattened_attachment(image, rollout_cwd=rollout_cwd)
            for image, rollout_cwd in flattened[: len(raw_values)]
        ]
    return None


def resolve_sequential_current_placeholders(raw_values: list[str], thread_id: str) -> list[Path] | None:
    if not raw_values:
        return None
    indexes: list[int] = []
    for raw in raw_values:
        match = ATTACHMENT_PLACEHOLDER_PATTERN.match(raw)
        if not match:
            return None
        indexes.append(int(match.group(1)))
    if indexes != list(range(1, len(raw_values) + 1)):
        return None

    attachment_turns = load_thread_attachment_turns(thread_id)
    latest_images, _latest_rollout_cwd = attachment_turns[-1]
    if len(indexes) <= len(latest_images):
        return None

    flattened = flatten_thread_attachments(attachment_turns)
    if len(indexes) > len(flattened):
        return None
    return [
        resolve_flattened_attachment(image, rollout_cwd=rollout_cwd)
        for image, rollout_cwd in flattened[: len(indexes)]
    ]


def resolve_image_reference(raw: str, *, thread_id: str) -> Path:
    attachment_match = ATTACHMENT_PLACEHOLDER_PATTERN.match(raw)
    turn_match = TURN_ATTACHMENT_PLACEHOLDER_PATTERN.match(raw)
    thread_match = THREAD_ATTACHMENT_PLACEHOLDER_PATTERN.match(raw)
    last_output_match = LAST_OUTPUT_PLACEHOLDER_PATTERN.match(raw)

    if attachment_match or turn_match or thread_match or last_output_match:
        if last_output_match:
            outputs = load_last_output_set(thread_id)
            index = int(last_output_match.group(1) or "1") - 1
            if index < 0 or index >= len(outputs):
                fail(
                    f"last output 占位符 {raw.strip()} 超出范围 "
                    f"（已保存 {len(outputs)} 个输出）"
                )
            return outputs[index]

        assert_rollout_thread(thread_id)
        attachment_turns = load_thread_attachment_turns(thread_id)

        if attachment_match:
            images, rollout_cwd = attachment_turns[-1]
            return resolve_attachment_from_turn(
                attachment_match.group(1),
                images=images,
                rollout_cwd=rollout_cwd,
            )

        if turn_match:
            turn_offset = int(turn_match.group(1))
            if turn_offset >= 0:
                fail(f"turn 附件占位符须使用负偏移：{raw.strip()}")
            turn_index = len(attachment_turns) - 1 + turn_offset
            if turn_index < 0 or turn_index >= len(attachment_turns):
                fail(
                    f"turn 附件占位符 {raw.strip()} 超出范围 "
                    f"（共 {len(attachment_turns)} 个含附件轮次）"
                )
            images, rollout_cwd = attachment_turns[turn_index]
            return resolve_attachment_from_turn(
                turn_match.group(2),
                images=images,
                rollout_cwd=rollout_cwd,
            )

        flattened = flatten_thread_attachments(attachment_turns)
        index = int(thread_match.group(1)) - 1
        if index < 0 or index >= len(flattened):
            fail(
                f"thread 附件占位符 {raw.strip()} 超出范围 "
                f"（共 {len(flattened)} 个附件）"
            )
        selected, rollout_cwd = flattened[index]
        return resolve_flattened_attachment(selected, rollout_cwd=rollout_cwd)

    resolved = resolve_existing_path(raw)
    if resolved is None:
        fail(f"未找到输入图片：{Path(raw).expanduser()}")
    return resolved


def resolve_edit_images(
    *,
    thread_id: str,
    image_sets: list[str],
    images: list[str],
) -> list[Path]:
    """Resolve --image-set selectors and --image refs for edit (no implicit state)."""
    selected_paths: list[Path] = []
    raw_values = list(images)

    for selector in image_sets:
        selected_paths.extend(resolve_image_set_selector(selector, thread_id))

    if raw_values and not requires_rollout_thread(thread_id):
        dash_paths = resolve_dash_image_sequence(raw_values, thread_id)
        if dash_paths is not None:
            selected_paths.extend(dash_paths)
            raw_values = []
        else:
            sequential_paths = resolve_sequential_current_placeholders(raw_values, thread_id)
            if sequential_paths is not None:
                selected_paths.extend(sequential_paths)
                raw_values = []

    for raw in raw_values:
        selected_paths.append(resolve_image_reference(raw, thread_id=thread_id))

    paths = dedupe_paths(selected_paths)
    if not paths:
        fail("至少需要一个输入图片（--image 或 --image-set）。")
    if len(paths) > IMAGE_MAX_EDIT_IMAGES:
        fail(f"edit 最多支持 {IMAGE_MAX_EDIT_IMAGES} 张输入图片。")
    return paths


def normalize_output_paths(paths: Iterable[Path | str]) -> list[str]:
    return [str(Path(path).resolve()).replace("\\", "/") for path in paths]


def load_resolve_request_payload(args: argparse.Namespace) -> dict[str, object]:
    if args.request_file:
        path = Path(args.request_file).expanduser()
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            fail(f"无法读取请求 JSON 文件 {path}：{exc}")
    elif args.stdin:
        try:
            payload = json.load(sys.stdin)
        except json.JSONDecodeError as exc:
            fail(f"无法解析 stdin JSON：{exc}")
    else:
        return {
            "thread_id": args.thread_id,
            "image_sets": list(args.image_set or []),
            "images": list(args.images or []),
        }

    if not isinstance(payload, dict):
        fail("resolve 请求 JSON 须为对象。")
    return payload


def cmd_resolve(args: argparse.Namespace) -> int:
    if args.request_file or args.stdin:
        payload = load_resolve_request_payload(args)
        thread_id = effective_thread_id(str(payload.get("thread_id") or args.thread_id or ""))
        image_sets = payload.get("image_sets") or []
        images = payload.get("images") or []
        if not isinstance(image_sets, list) or not isinstance(images, list):
            fail("resolve 请求 JSON 中 image_sets / images 须为数组。")
    else:
        thread_id = effective_thread_id(args.thread_id)
        image_sets = list(args.image_set or [])
        images = list(args.images or [])

    paths = resolve_edit_images(
        thread_id=thread_id,
        image_sets=[str(item) for item in image_sets],
        images=[str(item) for item in images],
    )
    print(json.dumps(normalize_output_paths(paths), ensure_ascii=False, indent=2))
    return 0


def load_save_request_payload(args: argparse.Namespace) -> dict[str, object]:
    if args.request_file:
        path = Path(args.request_file).expanduser()
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            fail(f"无法读取请求 JSON 文件 {path}：{exc}")
    elif args.stdin:
        try:
            payload = json.load(sys.stdin)
        except json.JSONDecodeError as exc:
            fail(f"无法解析 stdin JSON：{exc}")
    else:
        return {
            "thread_id": args.thread_id,
            "active_input": list(args.active_input or []),
            "last_output": list(args.last_output or []),
        }

    if not isinstance(payload, dict):
        fail("save 请求 JSON 须为对象。")
    return payload


def cmd_save(args: argparse.Namespace) -> int:
    if args.request_file or args.stdin:
        payload = load_save_request_payload(args)
        thread_id = effective_thread_id(str(payload.get("thread_id") or args.thread_id or ""))
        active_input = payload.get("active_input") or []
        last_output = payload.get("last_output") or []
        if not isinstance(active_input, list) or not isinstance(last_output, list):
            fail("save 请求 JSON 中 active_input / last_output 须为数组。")
        active_paths = [str(item) for item in active_input]
        last_paths = [str(item) for item in last_output]
    else:
        thread_id = effective_thread_id(args.thread_id)
        active_paths = [str(path) for path in args.active_input]
        last_paths = [str(path) for path in args.last_output]

    if active_paths:
        save_active_image_set(thread_id, [Path(path) for path in active_paths])
    if last_paths:
        save_last_output_set(thread_id, [Path(path) for path in last_paths])
    result = {
        "thread_id": thread_id,
        "active_saved": bool(active_paths),
        "last_output_saved": bool(last_paths),
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="image-curl thread state helpers")
    subparsers = parser.add_subparsers(dest="command", required=True)

    resolve_parser = subparsers.add_parser("resolve", help="resolve --image / --image-set to paths")
    resolve_parser.add_argument("--thread-id", default=None, help="thread id (default: env or manual)")
    resolve_parser.add_argument(
        "--image-set",
        action="append",
        default=[],
        help="selector: active, last-output, latest-turn, turn:-K, thread:1,2,5",
    )
    resolve_parser.add_argument("--images", nargs="*", default=[], help="image paths or placeholders")
    resolve_parser.add_argument(
        "--stdin",
        action="store_true",
        help="read {thread_id, image_sets, images} JSON from stdin (avoids shell # truncation)",
    )
    resolve_parser.add_argument(
        "--request-file",
        default=None,
        help="read {thread_id, image_sets, images} JSON from file (Windows-friendly)",
    )
    resolve_parser.set_defaults(func=cmd_resolve)

    save_parser = subparsers.add_parser("save", help="persist active / last-output sets")
    save_parser.add_argument("--thread-id", default=None, help="thread id (default: env or manual)")
    save_parser.add_argument("--active-input", nargs="*", default=[], help="paths for active_image_set.json")
    save_parser.add_argument("--last-output", nargs="*", default=[], help="paths for last_output_set.json")
    save_parser.add_argument(
        "--stdin",
        action="store_true",
        help="read {thread_id, active_input, last_output} JSON from stdin (avoids shell # truncation)",
    )
    save_parser.add_argument(
        "--request-file",
        default=None,
        help="read {thread_id, active_input, last_output} JSON from file (Windows-friendly)",
    )
    save_parser.set_defaults(func=cmd_save)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())