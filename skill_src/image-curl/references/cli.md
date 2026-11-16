# CLI 速查（`image-curl`）

默认 base URL：`https://aicode.cat`。生图 Key **只**写入 skill 目录 `local.env`：GPT 用 `IMAGE_CURL_API_KEY`，Gemini 用 `IMAGE_CURL_GEMINI_API_KEY`。

## 入口

| 平台 | 统一入口 | 子脚本 |
|---|---|---|
| macOS / Linux | `scripts/image-curl.sh` | `generate_image.sh`、`edit_image.sh`、`generate_batch.sh` |
| Windows PowerShell | `scripts/image-curl.ps1` | `generate_image.ps1`、`edit_image.ps1`、`generate_batch.ps1` |

子命令：`generate`、`edit`、`generate-batch`（别名 `generate_batch`）、`models`、`help`。各子命令加 `--help` 看完整选项。逻辑都在 `scripts/lib/image_curl.py`，两端参数与输出完全一致。

脚本根目录：仓库内为 `skill_src/image-curl`；安装后为 `~/.codex/skills/image-curl`（Claude Code：`~/.claude/skills/image-curl`）。在仓库内开发时用仓库路径。

```bash
SKILL_ROOT=./skill_src/image-curl
"$SKILL_ROOT/scripts/image-curl.sh" generate --prompt "一只猫" --name cat
"$SKILL_ROOT/scripts/image-curl.sh" generate --model gemini-nano-banana-2.1 --prompt "一只猫" --size 16:9@2k --name cat
"$SKILL_ROOT/scripts/image-curl.sh" edit --image ./in.png --prompt "换背景" --name out
"$SKILL_ROOT/scripts/image-curl.sh" generate-batch --input prompts.jsonl --output-dir ./batch-out
"$SKILL_ROOT/scripts/image-curl.sh" models
```

```powershell
& "$env:USERPROFILE\.codex\skills\image-curl\scripts\image-curl.ps1" generate --prompt "一只猫" --name cat
```

## 选接口

| 模型 | 接口 | 鉴权头 |
|---|---|---|
| `gpt-image-*` 等其余模型 | `POST /v1/images/generations`、`/v1/images/edits` | `Authorization: Bearer` |
| `gemini-*`、含 `nano-banana` | `POST /v1beta/models/{model}:generateContent` | `x-goog-api-key` |

`--provider openai|gemini` 可强制指定。Key 通过 stdin 交给 curl（`-K -`），不会出现在进程命令行里。

## 选项

**generate / edit 共用：** `--prompt` / `--prompt-file`、`--output` / `--output-dir` / `--name`、`--model`、`--provider`、`--size`、`--count` / `--n`（1–10）、`--metadata`、`--overwrite`、`--dry-run`、`--base-url`、`--api-key`、`--timeout`（默认 300）。

**仅 GPT：** `--quality`、`--format`（png / jpeg / webp）、`--output-compression`（jpeg / webp，0–100）、`--moderation`、`--background`（generate）、`--mask`、`--input-fidelity`（low / high）。Gemini 固定返回 JPEG，传这些会警告并忽略（`--mask` 报错）。

**edit 额外：** `--image`（路径或占位符，可重复）、`--image-set`（`active`、`last-output`、`latest-turn`、`turn:-K`、`thread:1,2,5`）。Gemini 最多 14 张参考图、合计 ≤ 20 MB；不给 `--size` 时沿用输入图比例。

**generate-batch：** `--input` JSONL（必填）、`--output-dir`（必填）、`--concurrency`（默认 4，1–25），其余选项作为每个 job 的默认值。

**models：** `--provider`、`--base-url`、`--api-key`。

## 尺寸

### GPT（白名单，源：`scripts/lib/allowed_sizes.json` 的 `allowed` / `forbidden`）

| 输入 | 发给上游 |
|---|---|
| `1024x1024`（默认） | `1024x1024` |
| `auto` | `auto` |
| `1280x720` | `1280x720` |
| `1k` / `2k` | `1024x1024` / `2048x2048` |
| `16:9` / `9:16` / `1:1` | `3840x2160` / `2160x3840` / `2880x2880` |
| `3:1` / `1:3` | `3840x1280` / `1280x3840` |
| `16:9@1k`（= `1k@16:9`）/ `9:16@1k` | `1792x1008` / `1008x1792` |
| `16:9@2k` / `9:16@2k` | `3584x2016` / `2016x3584` |
| `4k@16:9`（= `16:9@4k`）/ `4k@9:16`（= `9:16@4k`） | `3840x2160` / `2160x3840` |

不要用：`4k`（单独）、`1920x1080`、`1080x1920`、`1000x1800`、`800x600`、`512x512`、`4096x4096`、`3840x2160`、`2160x3840`。

### Gemini（源：`allowed_sizes.json` 的 `gemini`）

`<宽高比>[@<档位>]` 或 `<档位>[@<宽高比>]`：

- 宽高比：`1:1` `16:9` `9:16` `4:3` `3:4` `3:2` `2:3` `5:4` `4:5` `21:9` `4:1` `1:4` `8:1` `1:8`
- 档位：`1k`（默认）、`2k`、`4k`；只写档位时为 `1:1`
- `auto` 不传宽高比；`1024x1024` → `1:1` 1K；`1280x720` → `16:9` 1K
- 不要用：`3:1`、`1:3`、`512`

## 占位符（`edit --image`）

| 占位符 | 含义 |
|---|---|
| `[Image #N]` | 最近一个含附件用户轮次第 N 张图 |
| `[Turn -K Image #N]` | 往前第 K 个含附件轮次第 N 张图 |
| `[Thread Image #N]` | 线程全局附件顺序第 N 张 |
| `[Last Output]` / `[Last Output #N]` | 本线程上次保存的输出图 |

## 批量 JSONL

```jsonl
"画一只猫"
{"prompt":"夕阳","size":"16:9","n":2,"name":"sunset-01"}
{"prompt":"海报","model":"gemini-nano-banana-2.1","size":"9:16@2k","out":"./batch-out/poster.jpg"}
```

job 字段：`prompt`、`model`、`provider`、`size`、`quality`、`background`、`format`、`compression`、`moderation`、`n`、`name`、`out`。stdout 每行一个保存路径；失败的 job 以 `job N failed: …` 写到 stderr，退出码 1。

## 输出

成功时 stdout 一行 JSON：

```json
{"saved_file": "/abs/cat.png", "bytes": 123456, "revised_prompt": null}
{"saved_file": "/abs/cat.jpg", "bytes": 123456, "mime_type": "image/jpeg"}
{"saved_files": [{"file": "/abs/a-1.jpg", "bytes": 1, "mime_type": "image/jpeg"}], "requested_count": 2, "returned_count": 2}
```

## 相关文档

- `SKILL.md`：触发规则、选模型、工作流程
- `../agents/openai.yaml`：Codex 隐式调用策略
