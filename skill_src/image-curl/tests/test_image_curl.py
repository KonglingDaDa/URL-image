"""Tests for scripts/lib/image_curl.py (shared core of the .sh / .ps1 entry scripts).

End-to-end cases put tests/fakes/curl first on PATH, so no request leaves the machine.
"""
from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

TESTS_DIR = Path(__file__).resolve().parent
SKILL_DIR = TESTS_DIR.parent
LIB_DIR = SKILL_DIR / "scripts" / "lib"
CORE = LIB_DIR / "image_curl.py"
FAKES = TESTS_DIR / "fakes"
sys.path.insert(0, str(LIB_DIR))

import image_curl  # noqa: E402

PNG_1PX = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
)
JPEG_STUB = b"\xff\xd8\xff\xe0" + b"0" * 32
GEMINI_KEY = "sk-test-gemini-0000"
GPT_KEY = "sk-test-gpt-0000"


def gemini_image_response(data: bytes = JPEG_STUB, mime: str = "image/jpeg", text: str | None = None) -> dict:
    parts = []
    if text:
        parts.append({"text": text})
    parts.append({"inlineData": {"mimeType": mime, "data": base64.b64encode(data).decode()}})
    return {"candidates": [{"content": {"role": "model", "parts": parts}, "finishReason": "STOP"}]}


@pytest.fixture()
def env(tmp_path, monkeypatch):
    """Isolated environment: no local.env, temp CODEX_HOME, fake curl on PATH."""
    codex_home = tmp_path / "codex"
    codex_home.mkdir()
    script = tmp_path / "script.json"
    script.write_text("[]", encoding="utf-8")
    log = tmp_path / "curl.log"
    values = {
        "IMAGE_CURL_ENV_FILE": str(tmp_path / "missing.env"),
        "CODEX_HOME": str(codex_home),
        "PATH": f"{FAKES}{os.pathsep}{os.environ.get('PATH', '')}",
        "FAKE_CURL_SCRIPT": str(script),
        "FAKE_CURL_LOG": str(log),
        "IMAGE_CURL_SAVE_RETRIES": "2",
    }
    for name in ("IMAGE_CURL_API_KEY", "IMAGE_CURL_GEMINI_API_KEY", "OPENAI_API_KEY", "CLIPROXY_API_KEY",
                 "IMAGE_CURL_MODEL", "IMAGE_CURL_GEMINI_MODEL", "IMAGE_CURL_BASE_URL", "IMAGE_CURL_OUTPUT_DIR",
                 "CODEX_THREAD_ID", "CODEX_SESSION_ID"):
        monkeypatch.delenv(name, raising=False)
    for name, value in values.items():
        monkeypatch.setenv(name, value)
    (FAKES / "curl").chmod(0o755)

    class Env:
        root = tmp_path
        home = codex_home

        def script(self, items: list[dict]) -> None:
            script.write_text(json.dumps(items), encoding="utf-8")

        def calls(self) -> list[dict]:
            if not log.exists():
                return []
            return [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines() if line.strip()]

        def run(self, *args: str, extra_env: dict | None = None) -> subprocess.CompletedProcess:
            run_env = dict(os.environ)
            run_env.update(extra_env or {})
            return subprocess.run(
                [sys.executable, str(CORE), *args],
                capture_output=True,
                text=True,
                cwd=str(tmp_path),
                env=run_env,
            )

    return Env()


# --- pure helpers ------------------------------------------------------------


@pytest.mark.parametrize(
    "spec, ratio, tier",
    [
        ("16:9@2k", "16:9", "2K"),
        ("2k@9:16", "9:16", "2K"),
        ("2k", "1:1", "2K"),
        ("4k", "1:1", "4K"),
        ("21:9", "21:9", "1K"),
        ("4:1", "4:1", "1K"),
        ("1024x1024", "1:1", "1K"),
        ("1280x720", "16:9", "1K"),
    ],
)
def test_gemini_size_mapping(spec, ratio, tier):
    plan = image_curl.resolve_gemini_size(spec)
    assert (plan.aspect_ratio, plan.image_size) == (ratio, tier)


def test_gemini_size_auto_and_edit_default():
    assert image_curl.resolve_gemini_size("auto").aspect_ratio is None
    plan = image_curl.resolve_gemini_size("1024x1024", default_auto=True)
    assert plan.aspect_ratio is None and plan.image_size is None


@pytest.mark.parametrize("spec, needle", [("3:1", "4:1"), ("512", "1k"), ("7:3", "宽高比"), ("16:9@8k", "不支持"), ("2k@4k", "不支持")])
def test_gemini_size_rejects(spec, needle):
    with pytest.raises(image_curl.CliError) as info:
        image_curl.resolve_gemini_size(spec)
    assert needle in str(info.value)


def test_openai_size_uses_catalog():
    assert image_curl.resolve_openai_size("16:9").api_size == "3840x2160"
    with pytest.raises(image_curl.CliError) as info:
        image_curl.resolve_openai_size("4k")
    assert "4k@16:9" in str(info.value)


@pytest.mark.parametrize(
    "model, provider",
    [("gpt-image-2", "openai"), ("gpt-image-2.6-sunburst", "openai"), ("gemini-3.1-flash-image", "gemini"), ("gemini-nano-banana-2.1", "gemini")],
)
def test_infer_provider(model, provider):
    assert image_curl.infer_provider(model) == provider


def test_endpoints_accept_any_base_form():
    for base in ("https://aicode.cat", "https://aicode.cat/", "https://aicode.cat/v1", "https://aicode.cat/v1beta"):
        root = base.rstrip("/")
        assert image_curl.gemini_endpoint(root, "m") == "https://aicode.cat/v1beta/models/m:generateContent"
    assert image_curl.openai_endpoint("https://aicode.cat/v1", "edits") == "https://aicode.cat/v1/images/edits"
    assert image_curl.openai_endpoint("https://aicode.cat/v1beta", "generations") == "https://aicode.cat/v1/images/generations"


def test_parse_env_file():
    text = "# c\nexport A=1\nB = 'two words'\nC=\"x#y\"\nD=val # trailing\n\nE=\nnot a line\n"
    assert image_curl.parse_env_file(text) == {"A": "1", "B": "two words", "C": "x#y", "D": "val", "E": ""}


def test_gemini_key_order(monkeypatch):
    for name in ("IMAGE_CURL_API_KEY", "IMAGE_CURL_GEMINI_API_KEY"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("IMAGE_CURL_API_KEY", GPT_KEY)
    assert image_curl.resolve_api_key("gemini", None) == (GPT_KEY, "IMAGE_CURL_API_KEY")
    monkeypatch.setenv("IMAGE_CURL_GEMINI_API_KEY", GEMINI_KEY)
    assert image_curl.resolve_api_key("gemini", None) == (GEMINI_KEY, "IMAGE_CURL_GEMINI_API_KEY")
    assert image_curl.resolve_api_key("openai", None) == (GPT_KEY, "IMAGE_CURL_API_KEY")
    assert image_curl.resolve_api_key("gemini", "sk-cli") == ("sk-cli", "--api-key")


def test_extract_gemini_image_skips_thoughts_and_keeps_text():
    final = b"\xff\xd8\xff-final"
    response = {
        "candidates": [{
            "content": {"parts": [
                {"thought": True, "inlineData": {"mimeType": "image/png", "data": base64.b64encode(b"draft").decode()}},
                {"text": "here you go"},
                {"inlineData": {"mimeType": "image/jpeg", "data": base64.b64encode(final).decode()}},
            ]},
            "finishReason": "STOP",
        }]
    }
    data, mime, text = image_curl.extract_gemini_image(response)
    assert (data, mime, text) == (final, "image/jpeg", "here you go")


def test_extract_gemini_image_errors():
    with pytest.raises(image_curl.RetryableError) as info:
        image_curl.extract_gemini_image({"candidates": [{"content": {"parts": [{"text": "no"}]}, "finishReason": "IMAGE_SAFETY"}]})
    assert "IMAGE_SAFETY" in str(info.value)
    with pytest.raises(image_curl.CliError) as info:
        image_curl.extract_gemini_image({"promptFeedback": {"blockReason": "SAFETY"}})
    assert not isinstance(info.value, image_curl.RetryableError)


def test_curl_config_header_escapes_quotes():
    assert image_curl.curl_config_header("x", 'a"b\\c') == 'header = "x: a\\"b\\\\c"\n'


# --- end to end with fake curl ------------------------------------------------


def test_gemini_generate_end_to_end(env):
    env.script([{"match": "generateContent", "json": gemini_image_response(text="ok")}])
    out = env.root / "cat.png"
    proc = env.run("generate", "--model", "gemini-nano-banana-2.1", "--prompt", "一只猫", "--size", "16:9@2k",
                   "--output", str(out), extra_env={"IMAGE_CURL_GEMINI_API_KEY": GEMINI_KEY})
    assert proc.returncode == 0, proc.stderr
    result = json.loads(proc.stdout)
    saved = Path(result["saved_file"])
    assert saved.suffix == ".jpg" and saved.read_bytes() == JPEG_STUB
    assert result["mime_type"] == "image/jpeg" and result["text"] == "ok"
    assert "改为 cat.jpg" in proc.stderr
    (call,) = env.calls()
    assert call["url"].endswith("/v1beta/models/gemini-nano-banana-2.1:generateContent")
    assert call["headers"]["x-goog-api-key"] == GEMINI_KEY
    assert GEMINI_KEY not in " ".join(call["argv"])
    assert call["data"]["generationConfig"]["imageConfig"] == {"aspectRatio": "16:9", "imageSize": "2K"}
    last = json.loads((env.home / "generated_images" / "manual" / "last_output_set.json").read_text(encoding="utf-8"))
    assert [Path(p).name for p in last["images"]] == ["cat.jpg"]


def test_gemini_count_runs_one_request_per_image(env):
    env.script([{"match": "generateContent", "json": gemini_image_response()} for _ in range(2)])
    proc = env.run("generate", "--model", "gemini-3.1-flash-image", "--prompt", "p", "--count", "2",
                   "--output-dir", str(env.root), "--name", "pair", extra_env={"IMAGE_CURL_GEMINI_API_KEY": GEMINI_KEY})
    assert proc.returncode == 0, proc.stderr
    result = json.loads(proc.stdout)
    assert result["requested_count"] == 2 and result["returned_count"] == 2
    names = sorted(Path(item["file"]).name for item in result["saved_files"])
    assert names[0].endswith("-1.jpg") and names[1].endswith("-2.jpg")
    assert len(env.calls()) == 2


def test_gemini_retries_when_no_image(env):
    env.script([
        {"match": "generateContent", "json": {"candidates": [{"content": {"parts": [{"text": "Sure!"}]}, "finishReason": "STOP"}]}},
        {"match": "generateContent", "json": gemini_image_response()},
    ])
    proc = env.run("generate", "--model", "gemini-3.1-flash-image", "--prompt", "p", "--output", str(env.root / "a.jpg"),
                   extra_env={"IMAGE_CURL_GEMINI_API_KEY": GEMINI_KEY})
    assert proc.returncode == 0, proc.stderr
    assert "正在重试" in proc.stderr and "Sure!" in proc.stderr
    assert len(env.calls()) == 2


def test_gemini_wrong_group_key_gets_hint_without_retry(env):
    env.script([{"match": "generateContent", "status": 400,
                 "json": {"error": {"code": 400, "message": "API key group platform is not gemini", "status": "INVALID_ARGUMENT"}}}])
    proc = env.run("generate", "--model", "gemini-3.1-flash-image", "--prompt", "p", "--output", str(env.root / "a.jpg"),
                   extra_env={"IMAGE_CURL_API_KEY": GPT_KEY})
    assert proc.returncode == 1
    assert "HTTP 400" in proc.stderr and "IMAGE_CURL_GEMINI_API_KEY" in proc.stderr
    assert len(env.calls()) == 1


def test_gemini_edit_sends_inline_images_and_rejects_mask(env):
    image = env.root / "in.png"
    image.write_bytes(PNG_1PX)
    env.script([{"match": "generateContent", "json": gemini_image_response()}])
    proc = env.run("edit", "--model", "gemini-nano-banana-2.1", "--image", str(image), "--prompt", "换背景",
                   "--output", str(env.root / "out.jpg"), extra_env={"IMAGE_CURL_GEMINI_API_KEY": GEMINI_KEY})
    assert proc.returncode == 0, proc.stderr
    parts = env.calls()[0]["data"]["contents"][0]["parts"]
    assert parts[0]["inlineData"]["mimeType"] == "image/png"
    assert base64.b64decode(parts[0]["inlineData"]["data"]) == PNG_1PX
    assert parts[1] == {"text": "换背景"}
    assert "imageConfig" not in env.calls()[0]["data"]["generationConfig"]

    mask = env.root / "mask.png"
    mask.write_bytes(PNG_1PX)
    proc = env.run("edit", "--model", "gemini-nano-banana-2.1", "--image", str(image), "--mask", str(mask),
                   "--prompt", "x", "--output", str(env.root / "m.jpg"), extra_env={"IMAGE_CURL_GEMINI_API_KEY": GEMINI_KEY})
    assert proc.returncode == 1 and "--mask" in proc.stderr


def test_openai_generate_and_multi_count(env):
    b64 = base64.b64encode(PNG_1PX).decode()
    env.script([
        {"match": "/v1/images/generations", "json": {"data": [{"b64_json": b64, "revised_prompt": "rp"}]}},
        {"match": "/v1/images/generations", "json": {"data": [{"b64_json": b64}, {"url": "data:image/png;base64," + b64}]}},
    ])
    single = env.root / "one.png"
    proc = env.run("generate", "--prompt", "p", "--output", str(single), extra_env={"IMAGE_CURL_API_KEY": GPT_KEY})
    assert proc.returncode == 0, proc.stderr
    assert json.loads(proc.stdout) == {"saved_file": single.as_posix(), "bytes": len(PNG_1PX), "revised_prompt": "rp"}
    call = env.calls()[0]
    assert call["headers"]["Authorization"] == f"Bearer {GPT_KEY}" and GPT_KEY not in " ".join(call["argv"])
    assert call["data"]["model"] == "gpt-image-2" and call["data"]["n"] == 1

    proc = env.run("generate", "--prompt", "p", "--n", "2", "--output", str(env.root / "two.png"), extra_env={"IMAGE_CURL_API_KEY": GPT_KEY})
    assert proc.returncode == 0, proc.stderr
    result = json.loads(proc.stdout)
    assert result["returned_count"] == 2
    assert [Path(item["file"]).name for item in result["saved_files"]] == ["two-1.png", "two-2.png"]


def test_openai_http_error_body_is_reported(env):
    env.script([{"match": "/v1/images/generations", "status": 404,
                 "json": {"error": {"message": "Images API is not supported for this platform", "type": "not_found_error"}}}])
    proc = env.run("generate", "--prompt", "p", "--output", str(env.root / "x.png"), extra_env={"IMAGE_CURL_API_KEY": GEMINI_KEY})
    assert proc.returncode == 1
    assert "HTTP 404" in proc.stderr and "Images API is not supported" in proc.stderr and "GPT 生图分组" in proc.stderr


def test_openai_edit_uses_multipart(env):
    image = env.root / "in.png"
    image.write_bytes(PNG_1PX)
    env.script([{"match": "/v1/images/edits", "json": {"data": [{"b64_json": base64.b64encode(PNG_1PX).decode()}]}}])
    proc = env.run("edit", "--image", str(image), "--prompt", "多行\n提示词", "--input-fidelity", "high",
                   "--output", str(env.root / "e.png"), extra_env={"IMAGE_CURL_API_KEY": GPT_KEY})
    assert proc.returncode == 0, proc.stderr
    form = [value for _, value in env.calls()[0]["form"]]
    assert f"image[]=@{image.as_posix()}" in form and "input_fidelity=high" in form
    assert any(value.startswith("prompt=<") for value in form)


def test_batch_mixes_providers(env):
    jobs = env.root / "jobs.jsonl"
    jobs.write_text(
        '"gpt job"\n{"prompt":"gemini job","model":"gemini-nano-banana-2.1","size":"9:16@2k","name":"g"}\n',
        encoding="utf-8",
    )
    env.script([
        {"match": "/v1/images/generations", "json": {"data": [{"b64_json": base64.b64encode(PNG_1PX).decode()}]}},
        {"match": "generateContent", "json": gemini_image_response()},
    ])
    extra = {"IMAGE_CURL_API_KEY": GPT_KEY, "IMAGE_CURL_GEMINI_API_KEY": GEMINI_KEY}
    proc = env.run("generate-batch", "--input", str(jobs), "--output-dir", str(env.root / "out"), extra_env=extra)
    assert proc.returncode == 0, proc.stderr
    lines = proc.stdout.strip().splitlines()
    assert len(lines) == 2 and lines[0].endswith(".png") and lines[1].endswith(".jpg")
    gemini_call = next(call for call in env.calls() if "generateContent" in call["url"])
    assert gemini_call["data"]["generationConfig"]["imageConfig"] == {"aspectRatio": "9:16", "imageSize": "2K"}


def test_batch_reports_failed_job(env):
    jobs = env.root / "jobs.jsonl"
    jobs.write_text('"ok"\n{"prompt":"bad","size":"4k"}\n', encoding="utf-8")
    env.script([{"match": "/v1/images/generations", "json": {"data": [{"b64_json": base64.b64encode(PNG_1PX).decode()}]}}])
    proc = env.run("generate-batch", "--input", str(jobs), "--output-dir", str(env.root / "out"), extra_env={"IMAGE_CURL_API_KEY": GPT_KEY})
    assert proc.returncode == 1
    assert "job 2 failed" in proc.stderr and len(proc.stdout.strip().splitlines()) == 1


def test_argv_file_keeps_quotes_and_hash(env, tmp_path):
    prompt = 'a "quoted" [Image #1] prompt'
    argv_file = tmp_path / "argv.json"
    argv_file.write_text(json.dumps(["generate", "--dry-run", "--prompt", prompt, "--output", str(tmp_path / "x.png")]), encoding="utf-8")
    proc = env.run("--argv-file", str(argv_file))
    assert proc.returncode == 0, proc.stderr
    assert json.loads(proc.stdout)["payload"]["prompt"].startswith(prompt)


def test_models_lists_both_groups(env):
    env.script([
        {"match": "/v1/models", "json": {"data": [{"id": "gpt-image-2"}]}},
        {"match": "/v1beta/models", "json": {"models": [{"name": "models/gemini-3.1-flash-image"}]}},
    ])
    proc = env.run("models", extra_env={"IMAGE_CURL_API_KEY": GPT_KEY, "IMAGE_CURL_GEMINI_API_KEY": GEMINI_KEY})
    assert proc.returncode == 0, proc.stderr
    report = json.loads(proc.stdout)
    assert report["openai"]["models"] == ["gpt-image-2"]
    assert report["gemini"]["models"] == ["gemini-3.1-flash-image"]


def test_existing_output_is_protected(env):
    target = env.root / "taken.png"
    target.write_bytes(b"x")
    proc = env.run("generate", "--prompt", "p", "--output", str(target), "--dry-run")
    assert proc.returncode == 1 and "输出文件已存在" in proc.stderr
