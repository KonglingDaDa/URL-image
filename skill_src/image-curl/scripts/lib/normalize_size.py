#!/usr/bin/env python3
"""Normalize image size specs (auto, WxH, W:H, tiers) for OpenAI image API constraints."""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from fractions import Fraction
from typing import NoReturn

IMAGE_SIZE_STEP = 16
IMAGE_MAX_EDGE = 3840
IMAGE_MIN_PIXELS = 655_360
IMAGE_MAX_PIXELS = 8_294_400
IMAGE_MAX_RATIO = 3.0

SIZE_DIMENSION_PATTERN = re.compile(r"^\s*(\d+)\s*[xX×]\s*(\d+)\s*$")
SIZE_RATIO_PATTERN = re.compile(r"^\s*(\d+)\s*:\s*(\d+)\s*$")
SIZE_TIER_PATTERN = re.compile(r"^\s*([1-9]\d*)\s*[kK]\s*$")
SIZE_RATIO_TIER_PATTERN = re.compile(
    r"^\s*(?:(\d+\s*:\s*\d+)\s*(?:@|,|\s+)\s*([1-9]\d*\s*[kK])|"
    r"([1-9]\d*\s*[kK])\s*(?:@|,|\s+)\s*(\d+\s*:\s*\d+))\s*$"
)


def fail(message: str, *, status: int = 1) -> NoReturn:
    print(message, file=sys.stderr)
    raise SystemExit(status)


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


def iter_ratio_candidates(width_ratio: int, height_ratio: int) -> list[tuple[int, int]]:
    ratio = Fraction(width_ratio, height_ratio).limit_denominator(256)
    numerator = ratio.numerator
    denominator = ratio.denominator

    if max(numerator, denominator) / min(numerator, denominator) > IMAGE_MAX_RATIO:
        return []

    step_multiplier = math.lcm(
        IMAGE_SIZE_STEP // math.gcd(numerator, IMAGE_SIZE_STEP),
        IMAGE_SIZE_STEP // math.gcd(denominator, IMAGE_SIZE_STEP),
    )
    base_width = numerator * step_multiplier
    base_height = denominator * step_multiplier

    max_scale = min(IMAGE_MAX_EDGE // base_width, IMAGE_MAX_EDGE // base_height)
    candidates: list[tuple[int, int]] = []
    for scale in range(1, max_scale + 1):
        width = base_width * scale
        height = base_height * scale
        if validate_image_size(width, height) is None:
            candidates.append((width, height))
    return candidates


def parse_ratio(raw_ratio: str) -> tuple[int, int]:
    ratio_match = SIZE_RATIO_PATTERN.match(raw_ratio)
    if not ratio_match:
        fail(f"invalid image ratio: {raw_ratio}")

    width_ratio = int(ratio_match.group(1))
    height_ratio = int(ratio_match.group(2))
    if width_ratio <= 0 or height_ratio <= 0:
        fail(f"invalid image ratio: {raw_ratio}")
    return width_ratio, height_ratio


def parse_size_tier(raw_tier: str) -> int:
    tier_match = SIZE_TIER_PATTERN.match(raw_tier)
    if not tier_match:
        fail(f"invalid image size tier: {raw_tier}")
    return int(tier_match.group(1)) * 1024


def choose_ratio_tier_candidate(width_ratio: int, height_ratio: int, tier_edge: int) -> tuple[int, int]:
    candidates = iter_ratio_candidates(width_ratio, height_ratio)
    ratio = Fraction(width_ratio, height_ratio).limit_denominator(256)

    if ratio.numerator >= ratio.denominator:
        target_height = tier_edge
        target_width = round(tier_edge * ratio.numerator / ratio.denominator)
    else:
        target_width = tier_edge
        target_height = round(tier_edge * ratio.denominator / ratio.numerator)

    return choose_candidate(
        candidates,
        target_width=target_width,
        target_height=target_height,
    )


def choose_candidate(
    candidates: list[tuple[int, int]],
    *,
    target_width: int | None = None,
    target_height: int | None = None,
) -> tuple[int, int]:
    if not candidates:
        fail(
            "no valid image size candidate found under OpenAI constraints "
            f"(edge <= {IMAGE_MAX_EDGE}, divisible by {IMAGE_SIZE_STEP}, "
            f"pixels {IMAGE_MIN_PIXELS}-{IMAGE_MAX_PIXELS}, ratio <= {IMAGE_MAX_RATIO}:1)"
        )

    if target_width is None or target_height is None:
        return max(candidates, key=lambda item: (item[0] * item[1], max(item), min(item)))

    target_pixels = target_width * target_height
    return min(
        candidates,
        key=lambda item: (
            (item[0] - target_width) ** 2 + (item[1] - target_height) ** 2,
            item[0] > target_width or item[1] > target_height or item[0] * item[1] > target_pixels,
            abs(item[0] * item[1] - target_pixels),
            item[0] * item[1],
        ),
    )


def is_explicit_dimension(spec: str) -> bool:
    return SIZE_DIMENSION_PATTERN.match(spec.strip()) is not None


def normalize_image_size(spec: str) -> tuple[str, str | None, bool]:
    raw_spec = spec.strip()
    if raw_spec.lower() == "auto":
        return "auto", None, False

    tier_match = SIZE_TIER_PATTERN.match(raw_spec)
    if tier_match:
        tier_edge = parse_size_tier(raw_spec)
        normalized = f"{tier_edge}x{tier_edge}"
        if validate_image_size(tier_edge, tier_edge) is None:
            note = f"normalized image size {raw_spec} -> {normalized}"
            return normalized, note, False
        fail(f"invalid image size tier: {raw_spec}")

    ratio_tier_match = SIZE_RATIO_TIER_PATTERN.match(raw_spec)
    if ratio_tier_match:
        raw_ratio = ratio_tier_match.group(1) or ratio_tier_match.group(4)
        raw_tier = ratio_tier_match.group(2) or ratio_tier_match.group(3)
        width_ratio, height_ratio = parse_ratio(raw_ratio)
        tier_edge = parse_size_tier(raw_tier)
        normalized_width, normalized_height = choose_ratio_tier_candidate(
            width_ratio,
            height_ratio,
            tier_edge,
        )
        normalized = f"{normalized_width}x{normalized_height}"
        note = f"normalized image size {raw_spec} -> {normalized}"
        return normalized, note, False

    dim_match = SIZE_DIMENSION_PATTERN.match(raw_spec)
    if dim_match:
        width = int(dim_match.group(1))
        height = int(dim_match.group(2))
        return f"{width}x{height}", None, True

    ratio_match = SIZE_RATIO_PATTERN.match(raw_spec)
    if ratio_match:
        width_ratio, height_ratio = parse_ratio(raw_spec)

        normalized_width, normalized_height = choose_candidate(
            iter_ratio_candidates(width_ratio, height_ratio)
        )
        normalized = f"{normalized_width}x{normalized_height}"
        note = f"normalized image size {raw_spec} -> {normalized}"
        return normalized, note, False

    fail(
        "invalid image size. Use auto, WIDTHxHEIGHT, or WIDTH:HEIGHT "
        "(examples: 3840x2160, 1792x1024, 9:16, 9:16@1k)"
    )


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
    args = parser.parse_args()

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