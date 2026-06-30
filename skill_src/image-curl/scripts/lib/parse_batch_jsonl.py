#!/usr/bin/env python3
"""Parse JSONL batch input for generate_batch; prints a JSON array of normalized jobs."""

from __future__ import annotations

import json
import sys
from pathlib import Path

MAX_JOBS = 500


def normalize_job(job: object, line_no: int) -> dict:
    if isinstance(job, str):
        prompt = job.strip()
        if not prompt:
            raise ValueError(f"empty prompt in batch job line {line_no}")
        return {"prompt": prompt}
    if isinstance(job, dict):
        prompt = str(job.get("prompt", "")).strip()
        if not prompt:
            raise ValueError(f"missing prompt in batch job line {line_no}")
        return dict(job)
    raise ValueError(f"invalid batch job line {line_no}: expected string or object")


def read_jobs_jsonl(path: str | Path) -> list[dict]:
    input_path = Path(path).expanduser()
    if not input_path.is_file():
        raise ValueError(f"batch input not found: {input_path}")

    jobs: list[dict] = []
    for line_no, raw_line in enumerate(input_path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            item = json.loads(line)
        except json.JSONDecodeError:
            item = line
        jobs.append(normalize_job(item, line_no))

    if not jobs:
        raise ValueError("no batch jobs found")
    if len(jobs) > MAX_JOBS:
        raise ValueError(f"too many batch jobs: {len(jobs)} (max {MAX_JOBS})")
    return jobs


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: parse_batch_jsonl.py INPUT.jsonl", file=sys.stderr)
        return 2
    try:
        jobs = read_jobs_jsonl(sys.argv[1])
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(json.dumps(jobs, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())