#!/usr/bin/env python3
"""Normalize image size specs via allowed_sizes.json catalog for OpenAI image API."""

from __future__ import annotations

import argparse
import json
import re
import sys
from functools import lru_cache
from pathlib import Path
from typing import Any, NoReturn

IMAGE_SIZE_STEP = 16
IMAGE_MAX_EDGE = 3840
IMAGE_MIN_PIXELS = 655_360
IMAGE_MAX_PIXELS = 8_294_400
IMAGE_MAX_RATIO = 3.0

SIZE_DIMENSION_PATTERN = re.compile(r"^\s*(\d+)\s*[xX×]\s*(\d+)\s*$")


ALLOWED_SIZES_PATH = Path(__file__).with_name("allowed_sizes.json")


def fail(message: str, *, status: int = 1) -> NoReturn:
    print(message, file=sys.stderr)
    raise SystemExit(status)


def canonicalize_size_spec(spec: str) -> str:
    return re.sub(r"\s+", "", spec.strip().lower().replace("×", "x"))


@lru_cache(maxsize=1)
def load_allowed_sizes_catalog() -> dict[str, Any]:
    try:
        return json.loads(ALLOWED_SIZES_PATH.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"未找到尺寸白名单：{ALLOWED_SIZES_PATH}")
    except json.JSONDecodeError as exc:
        fail(f"尺寸白名单 JSON 无效：{exc}")


def allowed_size_inputs() -> set[str]:
    catalog = load_allowed_sizes_catalog()
    return {canonicalize_size_spec(item["input"]) for item in catalog.get("allowed", [])}


def forbidden_size_hints() -> dict[str, dict[str, Any]]:
    catalog = load_allowed_sizes_catalog()
    hints: dict[str, dict[str, Any]] = {}
    for item in catalog.get("forbidden", []):
        key = canonicalize_size_spec(item["input"])
        hints[key] = item
    return hints


def format_allowed_size_summary() -> str:
    catalog = load_allowed_sizes_catalog()
    parts: list[str] = []
    for item in catalog.get("allowed", []):
        label = item.get("note") or item["api_size"]
        parts.append(f"`{item['input']}`（{label}）")
    return "、".join(parts)


def validate_allowed_size_spec(spec: str) -> None:
    canonical = canonicalize_size_spec(spec)
    if canonical in allowed_size_inputs():
        return

    forbidden = forbidden_size_hints().get(canonical)
    if forbidden:
        alternatives = "、".join(f"`{value}`" for value in forbidden.get("use_instead", []))
        reason = forbidden.get("reason", "不在白名单")
        fail(f"不要用 `{spec.strip()}`：{reason}。请改用：{alternatives}。")

    fail(
        f"不支持的 --size `{spec.strip()}`。请仅使用文档标注「要用」的格式："
        f"{format_allowed_size_summary()}。"
    )


def validate_api_size_string(api_size: str) -> None:
    if api_size == "auto":
        return

    dim_match = SIZE_DIMENSION_PATTERN.match(api_size)
    if not dim_match:
        fail(f"api_size `{api_size}` 不是有效的宽x高格式。")

    width = int(dim_match.group(1))
    height = int(dim_match.group(2))
    error = validate_image_size(width, height)
    if error:
        fail(f"api_size `{api_size}` 不符合上游约束：{error}")


def validate_image_size(width: int, height: int) -> str | None:
    if width <= 0 or height <= 0:
        return "width and height must be positive"
    if width % IMAGE_SIZE_STEP != 0 or height % IMAGE_SIZE_STEP != 0:
        return f"width and height must both be divisible by {IMAGE_SIZE_STEP}"
    if width > IMAGE_MAX_EDGE or height > IMAGE_MAX_EDGE:
        return f"maximum edge length is {IMAGE_MAX_EDGE}px"

    pixels = width * height
    if pixels < IMAGE_MIN_PIXELS:
        return f"total pixels must be at least {IMAGE_MIN_PIXELS}"
    if pixels > IMAGE_MAX_PIXELS:
        return f"total pixels must be at most {IMAGE_MAX_PIXELS}"

    long_edge = max(width, height)
    short_edge = min(width, height)
    if long_edge / short_edge > IMAGE_MAX_RATIO:
        return f"long edge to short edge ratio must not exceed {IMAGE_MAX_RATIO}:1"
    return None


def is_explicit_dimension(spec: str) -> bool:
    return SIZE_DIMENSION_PATTERN.match(spec.strip()) is not None


def lookup_allowed_api_size(spec: str) -> tuple[str, str | None, bool] | None:
    """Return catalog api_size for a whitelisted input spec, or None if not found."""
    canonical = canonicalize_size_spec(spec)
    catalog = load_allowed_sizes_catalog()
    for item in catalog.get("allowed", []):
        if canonicalize_size_spec(item["input"]) != canonical:
            continue
        api_size = item["api_size"]
        raw_spec = spec.strip()
        is_explicit = is_explicit_dimension(raw_spec)
        if canonical == "auto" or canonical == canonicalize_size_spec(api_size):
            size_note = None
        else:
            size_note = f"catalog image size {raw_spec} -> {api_size}"
        return api_size, size_note, is_explicit
    return None


def normalize_image_size(spec: str) -> tuple[str, str | None, bool]:
    raw_spec = spec.strip()
    validate_allowed_size_spec(raw_spec)

    catalog_result = lookup_allowed_api_size(raw_spec)
    if catalog_result is None:
        fail(
            f"内部错误：尺寸 `{raw_spec}` 已通过白名单校验，但在 allowed_sizes.json 中未找到对应条目。"
            "请检查 catalog 与校验逻辑是否一致。"
        )
    return catalog_result


def prompt_size_constraint(size: str) -> str | None:
    dim_match = SIZE_DIMENSION_PATTERN.match(size)
    if not dim_match:
        return None

    width = int(dim_match.group(1))
    height = int(dim_match.group(2))
    if width == height:
        orientation = "square"
    elif width > height:
        orientation = "landscape"
    else:
        orientation = "portrait"

    return (
        "Final output constraint: compose for an exact "
        f"{width}x{height} pixel {orientation} canvas. "
        "The generated image should visually match that final canvas size and aspect ratio; "
        "do not imply a different resolution, crop, border, or padding."
    )


def augment_prompt_with_size(prompt: str, size: str) -> str:
    constraint = prompt_size_constraint(size)
    if constraint is None or constraint in prompt:
        return prompt
    return f"{prompt.rstrip()}\n\n{constraint}"


def augment_prompt_for_spec(prompt: str, raw_spec: str, api_size: str) -> str:
    if not is_explicit_dimension(raw_spec):
        return prompt
    return augment_prompt_with_size(prompt, api_size)


def main() -> None:
    parser = argparse.ArgumentParser(description="Normalize image size specifications.")
    parser.add_argument("spec", nargs="?", help="Size spec, e.g. 16:9, 1024x1024, auto")
    parser.add_argument(
        "--format",
        choices=("json", "text"),
        default="json",
        help="Output api_size as JSON (default) or plain text",
    )
    parser.add_argument("--augment-prompt", action="store_true", help="Augment prompt for explicit WxH")
    parser.add_argument("--prompt", default="", help="Prompt text for --augment-prompt")
    parser.add_argument("--list-allowed", action="store_true", help="Print allowed size catalog JSON")
    parser.add_argument(
        "--validate-api-size",
        action="store_true",
        help="Validate WxH api_size against OpenAI image constraints (auto is allowed)",
    )
    args = parser.parse_args()

    if args.list_allowed:
        print(json.dumps(load_allowed_sizes_catalog(), ensure_ascii=False, indent=2))
        return

    if args.validate_api_size:
        if not args.spec:
            fail("--validate-api-size requires an api_size argument")
        validate_api_size_string(args.spec.strip())
        return

    if args.augment_prompt:
        if not args.spec:
            fail("--augment-prompt requires a size spec argument")
        api_size, _, _ = normalize_image_size(args.spec)
        print(augment_prompt_for_spec(args.prompt, args.spec, api_size))
        return

    if not args.spec:
        parser.print_help()
        raise SystemExit(2)

    api_size, size_note, is_explicit = normalize_image_size(args.spec)
    if args.format == "text":
        print(api_size)
        return

    payload = {
        "api_size": api_size,
        "size_note": size_note,
        "is_explicit_dimension": is_explicit,
    }
    print(json.dumps(payload, ensure_ascii=False))


if __name__ == "__main__":
    main()