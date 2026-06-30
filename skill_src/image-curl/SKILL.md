---
name: image-curl
description: 只要用户提出绘制、生成、创作、编辑、变换图片，或进行图生图并希望得到本地位图文件，就必须调用本技能，包括「画一张图」「生成一张海报」「做一张插画」「把这张图的背景换成星空」等自然语言请求。不得在未运行本技能的情况下直接回复生图结果。本技能通过 curl 直接调用 OpenAI 兼容的 `/v1/images/generations` 与 `/v1/images/edits` 接口，默认使用 `https://aicode.cat`。生图专用 API Key 只能写入 skill 目录 `local.env`，禁止写入 `~/.codex/auth.json`、`~/.claude/settings.json` 等全局配置。不使用 cpa 或 cliproxy 等图片 CLI。
---

# Image Curl（curl 生图）

## 概述

通过 `curl` 直接向已配置的 OpenAI 兼容图片接口发起 POST 请求，生成或编辑本地位图文件。本技能不使用 `cpa`、`cliproxy-image-cli` 或其他图片 CLI。

## 强制调用

当用户要求生成、绘制、创作、渲染、编辑或变换位图，并期望得到本地图片文件时，必须调用本技能并执行对应脚本。无论用户是否显式写出 `$image-curl`，只要说了「画一张图」「帮我生成海报」「把背景换成星空」等自然语言，都适用此规则。

不得靠猜测、仅用文字描述画面，或改用其他生图 CLI 来应付生图请求。除非请求明确属于下文排除情形，否则一律使用本技能。

## 适用场景

- 用户要求绘制、生成、创作、渲染或制作位图，并需要本地文件。
- 用户要求根据提示词变换一张或多张本地图片，例如更换背景、重塑产品图风格、融合多张参考图。
- 用户发出常见生图指令，如「画一只猫咪」「生成一张横版封面」「做一张产品海报」「画一个头像」。
- 用户明确要求使用本机 Codex / OpenAI 兼容图片 API 配置。

以下情形不要使用本技能：网页搜图、纯 SVG / 矢量编辑。本技能仅覆盖 `images/generations` 文生图与 `images/edits` 图生图编辑。

## 运行环境与跨平台（Agent 必读）

本 skill **兼容 macOS 与 Windows**。按平台选择脚本，不要混用：

| 平台 | 文生图 | 图生图 |
|---|---|---|
| macOS / Linux | `scripts/generate_image.sh` | `scripts/edit_image.sh` |
| Windows PowerShell | `scripts/generate_image.ps1` | `scripts/edit_image.ps1` |

### 必需依赖

**macOS / Linux（.sh）**

- `bash`、`curl`、`python3`

**Windows（.ps1）**

- PowerShell 5.1+（或 PowerShell 7+）
- `curl.exe`（Windows 10/11 通常自带）

### 平台差异

- **macOS**：优先使用 `.sh` 脚本。
- **Windows**：**优先使用 `.ps1` 脚本**，可直接在 PowerShell 中运行；仅当用户明确要求或 `.ps1` 不可用时，再退回 Git Bash / WSL 运行 `.sh`。
- Windows skill 路径示例：`$env:USERPROFILE\.codex\skills\image-curl`
- macOS skill 路径示例：`~/.codex/skills/image-curl`

### 环境异常时 Agent 怎么处理

1. **Windows + PowerShell**：默认调用 `generate_image.ps1` / `edit_image.ps1`，参数格式与 `.sh` 相同。
2. **找不到 curl.exe**：提示用户安装或启用 Windows 自带 `curl.exe`，不要用 `Invoke-WebRequest` 代替。
3. **macOS / Linux 缺 bash/python3**：补齐依赖后再运行 `.sh`。
4. **Permission denied（.sh）**：执行 `chmod +x scripts/*.sh`。
5. **路径找不到**：使用当前 shell 能识别的绝对路径传 `--output` / `--image`。
6. **API Key 已配置但仍报错**：检查 skill 目录下 `local.env` 是否存在，且包含 `IMAGE_CURL_API_KEY`。

## 安装与 Key 配置（Agent 必读）

当用户要求安装本 skill 并配置生图专用 Key 时，按以下步骤执行：

1. 判断用户系统：Windows 优先用 `.ps1`，macOS / Linux 用 `.sh`。
2. 克隆 `https://github.com/KonglingDaDa/URL-image`，将 `skill_src/image-curl` 复制到 skill 目录（Windows：`%USERPROFILE%\.codex\skills\image-curl`；macOS：`~/.codex/skills/image-curl`）。
3. macOS / Linux：为 `scripts/*.sh` 执行 `chmod +x`。
4. 复制 `local.env.example` 为 `local.env`，写入 `IMAGE_CURL_API_KEY=`；macOS / Linux 可执行 `chmod 600 local.env`。
5. 运行 `generate_image.ps1` 或 `generate_image.sh --dry-run` 验证配置，再执行一次真实生图测试。

**禁止**把生图专用 Key 写入：

- `~/.codex/auth.json`
- `~/.codex/config.toml`
- `~/.claude/settings.json` 或 Claude 全局配置
- 任何全局客户端配置文件

生图专用 Key **只能**存在于本 skill 目录的 `local.env` 中。

## 默认配置

- 默认模型：`gpt-image-2`
- 默认尺寸：`1024x1024`
- 默认质量：`auto`
- 默认输出格式：`png`
- 默认审核：`auto`
- 生图专用 API Key 路径：`~/.codex/skills/image-curl/local.env`（脚本启动时自动加载）
- 默认 base URL：`https://aicode.cat`；可通过 `local.env` 中的 `IMAGE_CURL_BASE_URL` 或 `--base-url` 覆盖
- API Key 读取顺序：`local.env` → `--api-key` → 环境变量 → `auth.json`（后两者仅兜底，生图专用 Key 不要放那里）

## 尺寸选择

上游在 1K、2K、4K 输出档位内支持任意 `宽x高` 尺寸。不要限制为固定白名单，也不要在生成后本地裁剪或缩放。

已确认的上游约束：

- 最长边不得超过 `3840`
- 宽、高均须为 `16` 的倍数
- 最大宽高比为 `3:1`
- 总像素数须在 `[655360, 8294400]` 范围内

选择规则：

- 用户给出合法精确尺寸（如 `1344x768`、`1200x1600`、`2048x1152`）时，原样传入。
- 用户给出不合法尺寸时，仅在满足约束所需的最小范围内调整，并尽量保留原意。例如 4K 横版长图 `4096x1024` 应调整为 `3840x1280`，因为最长边上限为 `3840`，宽高比上限为 `3:1`。
- 用户只说明横竖版或画幅方向时，选择能保留该意图的尺寸，不要强行输出正方形。
- 用户要求 1K、2K 或 4K 时，在该档位内选择尺寸，并保留所需宽高比。
- 未指定尺寸、档位或方向时，使用 `1024x1024`。
- 仅当用户明确要求自动、原比例或自适应尺寸时，才使用 `auto`。

示例：

- 横版海报 / 横幅：`1536x864`、`1600x900`，或其他合适的横版尺寸
- 4K 横版长图：`3840x1280`
- 竖版海报 / 手机壁纸：`896x1600`、`1024x1536`，或其他合适的竖版尺寸
- 方形头像 / 图标：`1024x1024`

## 工作流程

1. 确定输出路径。若用户未指定，在当前工作目录以语义清晰且不覆盖已有文件的名称保存，例如 `generated-image.png`。
2. 判断用户提示词是否已足够具体。若过于笼统，先改写成简洁、可直接用于生图的提示词，再调用接口。
3. 文生图：Windows 运行 `scripts/generate_image.ps1`，macOS / Linux 运行 `scripts/generate_image.sh`。脚本组装 JSON，默认调用 `POST https://aicode.cat/v1/images/generations`，解码返回的 `data[].b64_json` 并写入图片文件。
4. 图生图编辑：Windows 运行 `scripts/edit_image.ps1`，macOS / Linux 运行 `scripts/edit_image.sh`。脚本以 multipart 调用 `POST https://aicode.cat/v1/images/edits`，并附加 `image[]=@<文件>` 字段。
5. 确认命令以退出码 `0` 结束，且输出文件存在且非空。
6. 向用户报告保存路径；仅在用户要求时说明 metadata。

## 文生图命令

```bash
~/.codex/skills/image-curl/scripts/generate_image.sh \
  --prompt "一只可爱的猫咪，毛茸茸的，正坐着看向镜头，干净背景，温暖自然光，写实风格，高质量" \
  --output ./cat.png \
  --size 1024x1024 \
  --count 1 \
  --quality auto \
  --format png \
  --moderation auto
```

## 图生图命令

```bash
~/.codex/skills/image-curl/scripts/edit_image.sh \
  --image ./photo1.png \
  --image ./photo2.jpg \
  --prompt "把背景换成星空，保留主体轮廓和服装细节" \
  --output ./edited.png \
  --size 1024x1024 \
  --count 1 \
  --quality auto \
  --format png \
  --moderation auto
```

## 传参调用

Codex 技能没有严格的参数协议。用户以 `key=value` 或自然语言说明参数时，应映射到对应脚本参数。

示例：

```text
$image-curl prompt="可爱猫女" output="./catgirl.png" size="1024x1024" quality="auto" format="png"
```

```text
$image-curl prompt="一只猫咪" output="./cat.png" base_url="https://aicode.cat" api_key="<API_KEY>"
```

```text
$image-curl 画一只可爱猫咪，保存为 ./cat.png，尺寸 1024x1024，使用 base_url=https://aicode.cat，api_key=<API_KEY>
```

```text
$image-curl 画一只猫咪，保存为 ./cat.png，使用默认域名 https://aicode.cat 和环境变量 IMAGE_CURL_API_KEY
```

生图专用 API Key 只写入 skill 目录 `local.env`。除非用户明确愿意，否则不要要求其把真实 API Key 写进对话，也不要写入全局客户端配置。

文生图常用字段与脚本参数对应：`prompt`、`output`、`size`、`count`、`n`、`quality`、`format`、`output_compression`、`output-compression`、`moderation`、`background`、`metadata`、`overwrite`、`dry_run`、`base_url`、`api_key`。图生图另支持重复 `image` 字段。`size` 可为 `auto` 或上游支持的 `宽x高`，并保留用户所需宽高比。`count` / `n` 对应 API 的 `n` 参数，用于一次请求多张图。`output_compression` 仅对 `jpeg` 或 `webp` 输出有效。

当 `count` 大于 1 时，输出路径会在扩展名前插入序号。例如 `output="./poster.png" count=4` 将保存为 `poster-1.png`、`poster-2.png`、`poster-3.png`、`poster-4.png`。

脚本会把 `count` / `n` 传给上游，并保存 `data[]` 中返回的每一张图。若上游接受但忽略 `n`，脚本会输出 `requested_count` 与 `returned_count`，便于发现数量不一致。

多图输出示例：

```text
$image-curl prompt="四张不同风格的新疆旅游海报" output="./xinjiang-poster.png" size="1280x1920" count=4
```

压缩 WebP 示例：

```text
$image-curl prompt="两张猫咪头像" output="./cat.webp" size="1024x1024" format="webp" output_compression=80 count=2
```

图生图示例：

```text
$image-curl image="./photo1.png" prompt="把背景换成星空" output="./starry.png" size="1024x1024"
```

```text
$image-curl image="./photo1.png" image="./photo2.jpg" prompt="融合两张参考图，生成统一风格海报" output="./merged.png"
```

实用选项：

- `--prompt-file <txt>`：读取较长或多行提示词
- `--metadata <json>`：保存响应 metadata，省略体积庞大的 base64 图片内容
- `--overwrite`：仅在确需覆盖已有输出时使用
- `--dry-run`：dry-run 模式，校验配置发现与请求体，不实际调用接口
- `--base-url <url>` 或 `--api-key <key>`：仅在需要显式覆盖时使用

文生图请求形态：

```bash
curl -sS --fail-with-body -X POST "https://aicode.cat/v1/images/generations" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -H "Cache-Control: no-store, no-cache, max-age=0" \
  -H "Pragma: no-cache" \
  -d '{
    "model": "gpt-image-2",
    "prompt": "...",
    "size": "1024x1024",
    "n": 1,
    "quality": "auto",
    "output_format": "png",
    "output_compression": 80,
    "moderation": "auto"
  }'
```

图生图请求形态：

```bash
curl -sS --fail-with-body -X POST "https://aicode.cat/v1/images/edits" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Cache-Control: no-store, no-cache, max-age=0" \
  -H "Pragma: no-cache" \
  -F "model=gpt-image-2" \
  -F "prompt=把背景换成星空" \
  -F "size=1024x1024" \
  -F "n=1" \
  -F "quality=auto" \
  -F "output_format=png" \
  -F "output_compression=80" \
  -F "moderation=auto" \
  -F "image[]=@photo1.png" \
  -F "image[]=@photo2.jpg"
```

## 异常处理

- 覆盖 base URL：传入 `--base-url` 或设置 `IMAGE_CURL_BASE_URL`；否则使用 `https://aicode.cat`。
- 缺少 API Key：检查 skill 目录 `local.env` 是否已设置 `IMAGE_CURL_API_KEY`，或临时传入 `--api-key`。不要把生图专用 Key 补写到 `auth.json`。
- 输出文件已存在：改用新路径，或在用户同意覆盖时使用 `--overwrite`。
- 非 JSON / HTTP 错误：保留命令输出中的错误正文，并向上游报告具体信息。
- 缺少 `b64_json`：检查响应 JSON，说明图片未按预期格式返回。