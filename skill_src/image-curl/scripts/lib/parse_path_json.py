#!/usr/bin/env python3
"""Print one resolved path per line from a JSON string array file."""
from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: parse_path_json.py FILE", file=sys.stderr)
        return 2
    path = Path(sys.argv[1])
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, list):
        print("JSON must be an array", file=sys.stderr)
        return 1
    for item in payload:
        if isinstance(item, str) and item.strip():
            print(item)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())