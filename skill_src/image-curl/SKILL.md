---
name: image-curl
description: 只要用户提出绘制、生成、创作、编辑、变换图片，或进行图生图并希望得到本地位图文件，就必须调用本技能，包括「画一张图」「生成一张海报」「用 Gemini / Nano Banana 画」「把这张图的背景换成星空」等自然语言请求。不得在未运行本技能的情况下直接回复生图结果。本技能通过 curl 调用 aicode.cat：GPT 生图走 `/v1/images/generations` 与 `/v1/images/edits`，Gemini 生图走 `/v1beta/models/{model}:generateContent`。生图专用 Key 只能写入 skill 目录 `local.env`（GPT 用 `IMAGE_CURL_API_KEY`，Gemini 用 `IMAGE_CURL_GEMINI_API_KEY`），禁止写入 `~/.codex/auth.json`、`~/.claude/settings.json` 等全局配置。不使用 cpa 或 cliproxy 等图片 CLI。
---

# Image Curl（curl 生图）

## 概述

通过 `curl` 调用 aicode.cat 的生图接口，生成或编辑本地位图文件。支持两类模型：

| 类别 | 模型（以 `models` 子命令输出为准） | 接口 | Key 变量 |
|---|---|---|---|
| GPT 生图 | `gpt-image-2.6`（默认）、`gpt-image-2`、`gpt-image-2.5` 及其 `-flare` / `-sunburst` 档位 | `POST /v1/images/generations`、`/v1/images/edits` | `IMAGE_CURL_API_KEY` |
| Gemini 生图 | `gemini-nano-banana-2.1`（Gemini 默认）、`gemini-3.1-flash-image` | `POST /v1beta/models/{model}:generateContent` | `IMAGE_CURL_GEMINI_API_KEY` |

接口按模型名自动选：`gemini-*` 或含 `nano-banana` 的模型走 Gemini，其余走 GPT。也可用 `--provider gemini|openai` 强制指定。

统一入口：`scripts/image-curl.sh`（macOS / Linux）与 `scripts/image-curl.ps1`（Windows）。子命令：`generate`、`edit`、`generate-batch`、`models`。CLI 速查见 `references/cli.md`。

## 强制调用

当用户要求生成、绘制、创作、渲染、编辑或变换位图，并期望得到本地图片文件时，**必须调用本技能并执行脚本**。用户没写 `$image-curl` 也一样。不得仅用文字描述画面，也不得改用其他生图 CLI。

排除：网页搜图、纯 SVG / 矢量编辑。

## 选模型

1. 用户点名模型 → 用点名的模型。
2. 用户说「Gemini」「Nano Banana」「香蕉」 → `--model gemini-nano-banana-2.1`。
3. 用户要透明背景、蒙版局部改图、PNG / WebP 输出 → 用 GPT 模型（Gemini 不支持这些）。
4. 其余 → 默认 `gpt-image-2.6`；`local.env` 里设了 `IMAGE_CURL_MODEL` 就用它。
5. 不确定当前 Key 能用哪些模型 → 先跑 `image-curl.sh models`。

## 运行环境

| 平台 | 统一入口 | 子脚本 | 依赖 |
|---|---|---|---|
| macOS / Linux | `image-curl.sh` | `generate_image.sh`、`edit_image.sh`、`generate_batch.sh` | `bash`、`curl`、Python 3.8+ |
| Windows | `image-curl.ps1` | `generate_image.ps1`、`edit_image.ps1`、`generate_batch.ps1` | PowerShell 5.1+、`curl.exe`、Python 3.8+（`py -3` / `python3` / `python`） |

所有逻辑在 `scripts/lib/image_curl.py`，`.sh` / `.ps1` 只负责找到 Python 再把参数原样转交，两端行为一致。Windows 优先用 `.ps1`，不要用 `Invoke-WebRequest` 代替 `curl.exe`。

脚本路径：工作区里有 `skill_src/image-curl/scripts/` 就用仓库内的绝对路径；只有安装到 Codex 后才用 `~/.codex/skills/image-curl/scripts/`（Windows：`%USERPROFILE%\.codex\skills\image-curl\scripts\`）。Claude Code 安装在 `~/.claude/skills/image-curl/`。

## 安装与 Key 配置（Agent 必读）

1. 克隆 `https://github.com/KonglingDaDa/URL-image`。
2. 用户要求安装时，把 `skill_src/image-curl` 复制到 skill 目录（Codex：`~/.codex/skills/image-curl`；Claude Code：`~/.claude/skills/image-curl`）。macOS / Linux 执行 `chmod +x scripts/*.sh`。
3. 在 skill 根目录把 `local.env.example` 复制为 `local.env`，填入用户在 aicode.cat 控制台创建的 Key：
   - GPT 生图分组的 Key → `IMAGE_CURL_API_KEY=`
   - Gemini 生图分组的 Key → `IMAGE_CURL_GEMINI_API_KEY=`
   - 只有 Gemini Key 的用户，再加一行 `IMAGE_CURL_MODEL=gemini-nano-banana-2.1`，不传 `--model` 时就走 Gemini。
   - macOS / Linux 执行 `chmod 600 local.env`。
4. 先 `--dry-run`（无 Key 也能跑），确认 `endpoint` 指向 `https://aicode.cat`、`authorization` 已打码；再真实生图一次。

**禁止**把生图 Key 写入 `~/.codex/auth.json`、`~/.codex/config.toml`、`~/.claude/settings.json` 或任何全局配置；不要让用户把真实 Key 贴进对话，也不要提交进 git。

Key 读取顺序：

- GPT：`--api-key` → `IMAGE_CURL_API_KEY` → `OPENAI_API_KEY` → `CLIPROXY_API_KEY` → `auth.json`（后几项只为兼容）
- Gemini：`--api-key` → `IMAGE_CURL_GEMINI_API_KEY` → `IMAGE_CURL_API_KEY`（复合分组 Key 可同时用两类模型）

`local.env` 的值优先于同名环境变量。base URL：`--base-url` → `IMAGE_CURL_BASE_URL` → `https://aicode.cat`（写成 `https://aicode.cat/v1` 或 `/v1beta` 也会自动纠正）。

## 默认值

| 项 | GPT | Gemini |
|---|---|---|
| 模型 | `gpt-image-2.6` | `gemini-nano-banana-2.1`（`--provider gemini` 不给 `--model` 时） |
| 尺寸 | `1024x1024` | 文生图 `1:1` 1K；改图沿用输入图比例 |
| 输出格式 | `png`（可 `jpeg` / `webp`） | 固定 JPEG，文件名改为 `.jpg` |
| 张数 | 一次请求 `n` 张（1–10） | 每张单独请求，最多 4 张并行（1–10） |
| 超时 | 300 秒 | 300 秒（4K 实测约 90 秒） |

## 输出路径

至少给一个：`--output`、`--output-dir`、`--name`。

| 参数 | 行为 |
|---|---|
| `--output FILE` | 精确路径（优先级最高；Gemini 会把扩展名改成 `.jpg`） |
| `--output-dir DIR` + `--name PREFIX` | `DIR/前缀-随机后缀.扩展名` |
| 只给 `--name` | 写入默认目录：`IMAGE_CURL_OUTPUT_DIR` → `${CODEX_HOME:-~/.codex}/generated_images` → `./.image-curl-output`（取首个可写），其下 `<CODEX_THREAD_ID|manual>/` |

张数大于 1 时在扩展名前加序号（`poster-1.png`、`poster-2.png`）。已有文件默认不覆盖，用户同意后加 `--overwrite`。

## 尺寸

### GPT：只能用白名单

运行时白名单：`scripts/lib/allowed_sizes.json`（`allowed` / `forbidden`）。**只从下表选值，不要自造像素尺寸。**

| `--size` | 发给上游 | 场景 |
|---|---|---|
| `1024x1024` | `1024x1024` | **默认** |
| `auto` | `auto` | 用户明确要自适应 |
| `1280x720` | `1280x720` | 720p 横版 |
| `1k` / `2k` | `1024x1024` / `2048x2048` | 正方形 |
| `16:9` / `9:16` / `1:1` | `3840x2160` / `2160x3840` / `2880x2880` | 全尺寸 |
| `3:1` / `1:3` | `3840x1280` / `1280x3840` | 超宽 / 超高 |
| `16:9@1k`（= `1k@16:9`）/ `9:16@1k` | `1792x1008` / `1008x1792` | 1K 横 / 竖 |
| `16:9@2k` / `9:16@2k` | `3584x2016` / `2016x3584` | 2K 横 / 竖 |
| `4k@16:9`（= `16:9@4k`）/ `4k@9:16`（= `9:16@4k`） | `3840x2160` / `2160x3840` | 4K 横 / 竖 |

不要用：单独的 `4k`（会变 4096x4096，超过最长边 3840）、`1920x1080`、`1080x1920`、`1000x1800`、`800x600`、`512x512`、`4096x4096`、手写的 `3840x2160` / `2160x3840`。脚本会拒绝并给出替代写法。白名单像素（`1024x1024`、`1280x720`）会在提示词末尾追加画布约束。2026-11-16 已用 `gpt-image-2.6` 把白名单全部实测一遍（之前用 `gpt-image-2` 测过）；其他 GPT 型号报尺寸错误时改用 `1024x1024`。

### Gemini：宽高比 + 档位

写法：`<宽高比>`、`<档位>`、`<宽高比>@<档位>` 或 `<档位>@<宽高比>`，大小写不限。

- 宽高比：`1:1`、`16:9`、`9:16`、`4:3`、`3:4`、`3:2`、`2:3`、`5:4`、`4:5`、`21:9`、`4:1`、`1:4`、`8:1`、`1:8`
- 档位：`1k`（默认）、`2k`、`4k`；单独写档位时为 `1:1`
- `auto`：不传宽高比，由模型决定（`gemini-nano-banana-2.1` 文生图会出 16:9；改图时沿用输入图比例）
- `1024x1024` → `1:1` 1K；`1280x720` → `16:9` 1K；其他像素写法会报错
- 不要用：`3:1` / `1:3`（Gemini 没有，改用 `4:1` / `1:4`）、`512`（网关实测被忽略，仍出 1K）

实测输出（2026-11-16，aicode.cat）：

| 模型 | `--size` | 实际像素 |
|---|---|---|
| `gemini-nano-banana-2.1` | `1:1` / `16:9` / `9:16` | 1024x1024 / 1376x768 / 768x1376 |
| `gemini-nano-banana-2.1` | `16:9@2k` / `4k` | 2752x1536 / 4096x4096 |
| `gemini-nano-banana-2.1` | `4:1` | 2064x512 |
| `gemini-3.1-flash-image` | `1:1` / `2k` | 1024x1024 / 2048x2048 |

选择规则：用户说横版 → `16:9`；竖版 → `9:16`；正方形 → `1:1`；要高清 → 加 `@2k`，要 4K → 加 `@4k`（4K 慢且贵，用户明确要求才用）。

## 子命令

| 用户意图 | 子命令 | 注意 |
|---|---|---|
| 纯文字生图 | `generate` | 不要传 `--image` |
| 基于已有图改图 / 多图融合 | `edit` | 至少 `--image` 或 `--image-set`；Gemini 最多 14 张参考图，合计 ≤ 20 MB |
| 多个 prompt 批量出图 | `generate-batch` | `--input` JSONL + `--output-dir`；不支持全局 `--prompt` / `--output` / `--name` |
| 继续改上次结果 | `edit --image-set last-output` 或 `--image '[Last Output]'` | edit 不隐式继承状态 |
| 引用对话附件 | `edit --image '[Image #N]'` 等 | 需 `CODEX_THREAD_ID` / `CODEX_SESSION_ID` |
| 局部改图（蒙版） | `edit --mask` | 仅 GPT；与原图同尺寸的 PNG，透明区为编辑区；蒙版是引导，相邻内容可能被连带改动 |
| 高保真保留输入 | `edit --input-fidelity high` | 仅 GPT |
| 查当前 Key 能用的模型 | `models` | 两个 Key 都配了就两组都查 |

GPT 专用选项：`--quality`、`--format`、`--output-compression`、`--moderation`、`--background`（如 `transparent`）、`--mask`、`--input-fidelity`。对 Gemini 传这些会警告并忽略（`--mask` 直接报错）。

## 线程占位符与 `--image-set`（edit）

| `--image` 占位符 | 含义 |
|---|---|
| `[Image #N]` | 最近一个含附件用户轮次第 N 张 |
| `[Turn -K Image #N]` | 往前第 K 个含附件轮次第 N 张 |
| `[Thread Image #N]` | 线程全局附件顺序第 N 张 |
| `[Last Output]` / `[Last Output #N]` | 本线程上次保存的输出 |

`--image-set` 可重复：`active`（上次 edit 的输入）、`last-output`、`latest-turn`、`turn:-K`、`thread:1,2,5`。rollout 类占位符和选择器需要线程 ID；无会话（`manual`）时仍可用本地路径和 `[Last Output]`。占位符按 rollout 记录的 cwd 解析。成功后更新 `last_output_set.json`，`edit` 还会更新 `active_image_set.json`。`[Image#1]` 等变体会自动规范化。

## 工作流程

1. 选模型（见「选模型」）和输出方式。
2. 提示词太笼统时，先改写成简洁、可直接生图的提示词。
3. 文生图：`image-curl.sh generate`（Windows：`image-curl.ps1 generate`）。
4. 改图：`image-curl.sh edit`；用历史图要显式加占位符或 `--image-set`。
5. 批量：`image-curl.sh generate-batch --input prompts.jsonl --output-dir <目录>`；同一批可混用 GPT 与 Gemini。
6. 确认退出码为 0、输出文件存在且非空。stdout 是一行 JSON（`saved_file` 或 `saved_files`）；Gemini 还会给 `mime_type`，模型附带文字时给 `text`。
7. 向用户报告保存路径；用户要求时才展开 metadata。

## 命令示例

```bash
SKILL_ROOT=/path/to/skill_src/image-curl   # 或 ~/.codex/skills/image-curl

"$SKILL_ROOT/scripts/image-curl.sh" generate --prompt "一只可爱的猫咪，温暖自然光" --name cat --size 16:9

"$SKILL_ROOT/scripts/image-curl.sh" generate --model gemini-nano-banana-2.1 \
  --prompt "清晨的咖啡馆，写实摄影" --size 16:9@2k --name cafe

"$SKILL_ROOT/scripts/image-curl.sh" edit --model gemini-nano-banana-2.1 \
  --image ./cat.png --image ./cafe.jpg --prompt "把第一张图的猫放进第二张图的咖啡馆桌上" --name cat-cafe

"$SKILL_ROOT/scripts/image-curl.sh" edit --image ./photo.png --mask ./mask.png \
  --prompt "把背景换成星空，保留人物" --input-fidelity high --output ./edited.png

"$SKILL_ROOT/scripts/image-curl.sh" edit --image-set last-output --prompt "只调整天空颜色" --name sky

"$SKILL_ROOT/scripts/image-curl.sh" generate-batch --input ./prompts.jsonl --output-dir ./batch-out

"$SKILL_ROOT/scripts/image-curl.sh" models
```

```powershell
& "$env:USERPROFILE\.codex\skills\image-curl\scripts\image-curl.ps1" generate `
  --model gemini-nano-banana-2.1 --prompt "一只可爱的猫咪" --size 9:16 --name cat
```

批量 JSONL 每行一个字符串 prompt 或 job 对象；job 可覆盖 `prompt`、`model`、`provider`、`size`、`quality`、`background`、`format`、`compression`、`moderation`、`n`、`name`、`out`：

```jsonl
"画一只猫"
{"prompt":"夕阳下的山脉","size":"16:9","name":"mountain-01"}
{"prompt":"霓虹街道海报","model":"gemini-nano-banana-2.1","size":"9:16@2k","name":"neon"}
```

## 传参调用

用户以 `key=value` 或自然语言给参数时，映射到脚本参数：

```text
$image-curl prompt="可爱猫女" name="catgirl" size="9:16@2k"
$image-curl model="gemini-nano-banana-2.1" prompt="一只猫咪" size="16:9@2k" name="cat"
$image-curl image="./photo1.png" prompt="把背景换成星空" name="starry"
$image-curl image="[Last Output]" image="[Image #1]" prompt="融合风格" name="merged"
```

常用字段：`prompt`、`output`、`output_dir`、`name`、`model`、`provider`、`size`、`count`/`n`、`quality`、`format`、`output_compression`、`moderation`、`background`、`metadata`、`overwrite`、`dry_run`、`base_url`、`api_key`；改图另有 `image`（可重复）、`image_set`、`mask`、`input_fidelity`。

实用选项：`--prompt-file`（长提示词）、`--metadata FILE`（保存去掉图片 base64 的响应）、`--dry-run`（只打印脱敏请求）、`--timeout`。

## 异常处理

| 现象 | 处理 |
|---|---|
| `未找到 API Key` / HTTP 401 | 检查 `local.env`：GPT 用 `IMAGE_CURL_API_KEY`，Gemini 用 `IMAGE_CURL_GEMINI_API_KEY` |
| `API key group platform is not gemini` | 用了 GPT 分组的 Key 调 Gemini；在 `local.env` 配 `IMAGE_CURL_GEMINI_API_KEY` |
| `Images API is not supported for this platform` | 用了 Gemini 分组的 Key 调 GPT 生图；配 GPT 分组的 `IMAGE_CURL_API_KEY`，或改用 gemini 模型 |
| `Model ... is not available for this group` | 该分组没有这个模型；跑 `models` 看可用模型 |
| Gemini 没返回图片 / `IMAGE_SAFETY` | 脚本自动重试（默认共 3 次，`IMAGE_CURL_SAVE_RETRIES`）；仍失败就改写提示词 |
| HTTP 429 / 5xx、网络抖动 | 自动重试；仍失败报告原文 |
| curl `exit 28` | 超时；4K 图可把 `--timeout` 加大到 600 |
| `输出文件已存在` | 换 `--name` / 路径，或用户同意后 `--overwrite` |
| 尺寸被拒 | 按报错里的替代写法改；GPT 与 Gemini 的写法不同（见「尺寸」） |
| Gemini 收到 `--mask` | Gemini 不支持蒙版；在提示词里写清要改的区域，或改用 GPT 模型 |
| GPT 大图只返回 `url` / 下载失败 | 3840 级大图网关只给下载链接；脚本用 curl 下载（先无鉴权，401/403 再带 Bearer），只重试下载、不会重新生成；仍失败会打印链接，可用浏览器打开 |
| 占位符 / `--image-set` 报缺 `CODEX_THREAD_ID` | 不在 Codex 线程内；改用本地路径 |
| 找不到 curl / Python | 安装 curl（Windows 用系统 `curl.exe`）与 Python 3.8+ |
| `.sh` Permission denied | `chmod +x scripts/*.sh` |

失败时保留命令输出的错误正文；不要泄露完整 Key 或图片 base64。
