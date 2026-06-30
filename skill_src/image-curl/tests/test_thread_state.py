#!/usr/bin/env python3
"""Unit tests for scripts/lib/thread_state.py resolve/save."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
SKILL_ROOT = SCRIPT_DIR.parent
THREAD_STATE_PY = SKILL_ROOT / "scripts" / "lib" / "thread_state.py"

MINIMAL_PNG = (
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
)


def run_thread_state(*args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    merged = os.environ.copy()
    if env:
        merged.update(env)
    return subprocess.run(
        [sys.executable, str(THREAD_STATE_PY), *args],
        capture_output=True,
        text=True,
        env=merged,
        check=False,
    )


class ThreadStateResolveTests(unittest.TestCase):
    def test_resolve_last_output_manual_thread(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            thread_dir = Path(tmpdir) / "generated_images" / "manual"
            thread_dir.mkdir(parents=True)
            first = thread_dir / "first-out.png"
            second = thread_dir / "second-out.png"
            import base64

            payload = base64.b64decode(MINIMAL_PNG)
            first.write_bytes(payload)
            second.write_bytes(payload)
            state = {
                "thread_id": "manual",
                "images": [str(first.resolve()), str(second.resolve())],
            }
            (thread_dir / "last_output_set.json").write_text(
                json.dumps(state, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )

            proc = run_thread_state(
                "resolve",
                "--thread-id",
                "manual",
                "--images",
                "[Last Output]",
                "--image-set",
                "last-output",
                env={"CODEX_HOME": tmpdir},
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            paths = json.loads(proc.stdout)
            self.assertEqual(len(paths), 2)
            self.assertEqual(paths[0], str(first.resolve()).replace("\\", "/"))
            self.assertEqual(paths[1], str(second.resolve()).replace("\\", "/"))

    def test_save_request_file_preserves_hash_in_path(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            thread_dir = Path(tmpdir) / "generated_images" / "manual"
            thread_dir.mkdir(parents=True)
            hashed = thread_dir / "img#2.png"
            hashed.write_bytes(b"")
            request = {
                "thread_id": "manual",
                "active_input": [],
                "last_output": [str(hashed.resolve()).replace("\\", "/")],
            }
            request_file = Path(tmpdir) / "save-request.json"
            request_file.write_text(json.dumps(request, ensure_ascii=False), encoding="utf-8")

            proc = run_thread_state(
                "save",
                "--request-file",
                str(request_file),
                env={"CODEX_HOME": tmpdir},
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)

            state_path = thread_dir / "last_output_set.json"
            self.assertTrue(state_path.is_file(), proc.stderr)
            state = json.loads(state_path.read_text(encoding="utf-8"))
            self.assertEqual(len(state["images"]), 1)
            self.assertIn("#", state["images"][0])
            self.assertTrue(state["images"][0].endswith("img#2.png"))

    def test_rollout_placeholder_fails_for_manual(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            proc = run_thread_state(
                "resolve",
                "--thread-id",
                "manual",
                "--images",
                "[Image #1]",
                env={"CODEX_HOME": tmpdir},
            )
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("CODEX_THREAD_ID", proc.stderr)


if __name__ == "__main__":
    unittest.main()