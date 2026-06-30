---
name: image-curl
description: 只要用户提出绘制、生成、创作、编辑、变换图片，或进行图生图并希望得到本地位图文件，就必须调用本技能，包括「画一张图」「生成一张海报」「做一张插画」「把这张图的背景换成星空」等自然语言请求。不得在未运行本技能的情况下直接回复生图结果。本技能通过 curl 直接调用 OpenAI 兼容的 `/v1/images/generations` 与 `/v1/images/edits` 接口，默认使用 `https://aicode.cat`。生图专用 API Key 只能写入 skill 目录 `local.env`，禁止写入 `~/.codex/auth.json`、`~/.claude/settings.json` 等全局配置。不使用 cpa 或 cliproxy 等图片 CLI。
---

# Image Curl（curl 生图）

## 概述

通过 `curl` 直接向已配置的 OpenAI 兼容图片接口发起 POST 请求，生成或编辑本地位图文件。本技能不使用 `cpa`、`cliproxy-image-cli` 或其他图片 CLI。

统一入口：`scripts/image-curl.sh`（macOS / Linux）与 `scripts/image-curl.ps1`（Windows），子命令 `generate`、`edit`、`generate-batch` 分别转发至对应子脚本。CLI 速查见 `references/cli.md`。

## 强制调用

当用户要求生成、绘制、创作、渲染、编辑或变换位图，并期望得到本地图片文件时，**必须调用本技能并执行对应脚本**。无论用户是否显式写出 `$image-curl`，只要说了「画一张图」「帮我生成海报」「把背景换成星空」等自然语言，都适用此规则。

不得靠猜测、仅用文字描述画面，或改用其他生图 CLI 来应付生图请求。除非请求明确属于下文排除情形，否则一律使用本技能。

## 适用场景

- 用户要求绘制、生成、创作、渲染或制作位图，并需要本地文件。
- 用户要求根据提示词变换一张或多张本地图片，例如更换背景、重塑产品图风格、融合多张参考图。
- 用户发出常见生图指令，如「画一只猫咪」「生成一张横版封面」「做一张产品海报」「画一个头像」。
- 用户需要批量从文生图 JSONL 生成多张图。
- 用户在 Codex 线程中需要引用历史附件或上次输出继续改图。
- 用户明确要求使用本机 Codex / OpenAI 兼容图片 API 配置。

以下情形不要使用本技能：网页搜图、纯 SVG / 矢量编辑。本技能仅覆盖 `images/generations` 文生图与 `images/edits` 图生图编辑。

## 运行环境与跨平台（Agent 必读）

本 skill **兼容 macOS 与 Windows**。按平台选择脚本，不要混用：

| 平台 | 统一入口 | 文生图 | 图生图 | 批量 |
|---|---|---|---|---|
| macOS / Linux | `image-curl.sh` | `generate_image.sh` | `edit_image.sh` | `generate_batch.sh` |
| Windows PowerShell | `image-curl.ps1` | `generate_image.ps1` | `edit_image.ps1` | `generate_batch.ps1` |

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

1. **Windows + PowerShell**：默认调用 `image-curl.ps1` 或 `generate_image.ps1` / `edit_image.ps1`，参数格式与 `.sh` 相同。
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
5. 运行 `image-curl.ps1 generate --dry-run` 或 `image-curl.sh generate --dry-run`（配合 `--prompt` 与 `--name`）验证配置，再执行一次真实生图测试。

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
- 默认 base URL：**`https://aicode.cat`**；可通过 `local.env` 中的 `IMAGE_CURL_BASE_URL` 或 `--base-url` 覆盖
- 生图专用 API Key 路径：`~/.codex/skills/image-curl/local.env`（脚本启动时自动加载）
- API Key 读取顺序：`local.env` → `--api-key` → 环境变量 → `auth.json`（后两者仅兜底，生图专用 Key 不要放那里）
- 默认输出目录：`${CODEX_HOME:-~/.codex}/generated_images/<CODEX_THREAD_ID|CODEX_SESSION_ID|manual>/`

## 输出路径

三者至少提供一个：`--output`、`--output-dir`、`--name`。

| 参数 | 行为 |
|---|---|
| `--output FILE` | 写入精确路径（优先级最高） |
| `--output-dir DIR` + `--name PREFIX` | 在目录下生成 `前缀-随机后缀.扩展名` |
| `--name PREFIX`（无 `--output-dir`） | 写入默认线程目录，文件名带随机后缀 |
| 均未指定 | 报错 |

`--count` / `--n` 大于 1 时，在扩展名前插入序号（如 `poster-1.png`、`poster-2.png`）。成功生图后会更新线程的 `last_output_set.json`；`edit` 还会更新 `active_image_set.json`。

## 尺寸选择

上游在 1K、2K、4K 输出档位内支持任意 `宽x高` 尺寸。支持比例与档位简写，由 `lib/normalize_size.py`（及 PowerShell `Resolve-ImageSize`）本地解析后传给 API。

已确认的上游约束：

- 最长边不得超过 `3840`
- 宽、高均须为 `16` 的倍数
- 最大宽高比为 `3:1`
- 总像素数须在 `[655360, 8294400]` 范围内

### 简写形式

除 `auto` 与 `宽x高` 外，还支持：

- 比例：`16:9`、`9:16`、`1:1` 等 → 解析为档位内最大合法像素
- 档位：`1k`、`2k`、`4k` → 正方形边长
- 组合：`9:16@1k`、`9:16@2k`、`1k@16:9` 等

常见解析示例：

| 输入 | 解析结果 |
|---|---|
| `16:9` | `3840x2160` |
| `9:16` | `2160x3840` |
| `9:16@1k` | `1008x1792` |
| `9:16@2k` | `2016x3584` |
| `2k` | `2048x2048` |

显式 `宽x高`（如 `1000x1800`）原样发送，并在提示词末尾追加画布约束说明。

选择规则：

- 用户给出合法精确尺寸时，原样传入。
- 用户给出不合法尺寸时，仅在满足约束所需的最小范围内调整，并尽量保留原意。
- 用户只说明横竖版或画幅方向时，选择能保留该意图的尺寸，不要强行输出正方形。
- 用户要求 1K、2K 或 4K 时，在该档位内选择尺寸，并保留所需宽高比。
- 未指定尺寸、档位或方向时，使用 `1024x1024`。
- 仅当用户明确要求自动、原比例或自适应尺寸时，才使用 `auto`。

## 线程占位符与 `--image-set`（edit 专用）

`edit` **不隐式继承**线程图片状态。要复用历史附件或上次输出，必须显式传 `--image` 占位符或 `--image-set` 选择器。

### `--image` 占位符

| 占位符 | 含义 |
|---|---|
| `[Image #N]` | 最近一个含附件用户轮次第 N 张图 |
| `[Turn -K Image #N]` | 往前第 K 个含附件轮次第 N 张图 |
| `[Thread Image #N]` | 线程全局附件顺序第 N 张 |
| `[Last Output]` / `[Last Output #N]` | 本线程上次保存的输出图列表 |

`[Image #N]` 指向最近含附件轮次，不一定是当前轮次。当前轮只有一张新附件时，`[Image #1]` 仅指该新图；要引用更早的图，用 `[Turn -1 Image #N]`、`[Thread Image #N]` 或 `--image-set`。

占位符解析使用 rollout 记录的 cwd，不回退到当前 shell cwd。变体如 `[Image#1]` 会自动规范化。

### `--image-set` 选择器

可重复传入：

- `active`：上次 `edit` 解析后的输入图列表
- `last-output`：上次保存的输出图列表
- `latest-turn`：最近含附件轮次的全部图
- `turn:-K`：往前第 K 个含附件轮次的全部图（K 为正整数，写法如 `turn:-1`）
- `thread:1,2,5`：线程全局附件顺序中的指定序号

rollout 类占位符与选择器需要 `CODEX_THREAD_ID` 或 `CODEX_SESSION_ID`。无会话时（`manual`）仍可用本地路径与 `[Last Output]`（若 `last_output_set.json` 存在）。

## 工作流程

1. 确定输出方式：用户指定路径时用 `--output`；否则用 `--name`（写入默认线程目录）或 `--output-dir` + `--name`。
2. 判断用户提示词是否已足够具体。若过于笼统，先改写成简洁、可直接用于生图的提示词，再调用接口。
3. 文生图：运行 `image-curl.sh generate` 或 `image-curl.ps1 generate`（亦可直接调用 `generate_image.*`）。
4. 图生图编辑：运行 `image-curl.sh edit` 或 `image-curl.ps1 edit`。需要历史图时显式加 `--image` 占位符或 `--image-set`；需要局部编辑时加 `--mask`；需要输入保真时加 `--input-fidelity low|high`。
5. 批量：运行 `image-curl.* generate-batch --input prompts.jsonl --output-dir <目录>`。
6. 确认命令以退出码 `0` 结束，且输出文件存在且非空。
7. 向用户报告保存路径；仅在用户要求时说明 metadata。

## 统一入口命令

```bash
# macOS / Linux
~/.codex/skills/image-curl/scripts/image-curl.sh generate \
  --prompt "一只可爱的猫咪" \
  --name cat \
  --size 16:9

~/.codex/skills/image-curl/scripts/image-curl.sh edit \
  --image '[Last Output]' \
  --image '[Image #1]' \
  --prompt "在上次结果基础上融合新参考图的风格" \
  --name refined

~/.codex/skills/image-curl/scripts/image-curl.sh generate-batch \
  --input ./prompts.jsonl \
  --output-dir ./batch-out
```

```powershell
# Windows
& "$env:USERPROFILE\.codex\skills\image-curl\scripts\image-curl.ps1" generate `
  --prompt "一只可爱的猫咪" --name cat --size 16:9
```

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

或使用默认线程目录：

```bash
~/.codex/skills/image-curl/scripts/generate_image.sh \
  --prompt "横版赛博城市壁纸" \
  --name cyber-city \
  --size 16:9
```

## 图生图命令

```bash
~/.codex/skills/image-curl/scripts/edit_image.sh \
  --image ./photo1.png \
  --image ./photo2.jpg \
  --prompt "把背景换成星空，保留主体轮廓和服装细节" \
  --output ./edited.png \
  --size 1024x1024 \
  --mask ./mask.png \
  --input-fidelity high
```

线程内继续改图：

```bash
~/.codex/skills/image-curl/scripts/edit_image.sh \
  --image-set last-output \
  --prompt "只调整天空颜色，其余保持不变" \
  --name sky-tweak
```

## 批量文生图

JSONL 每行一个字符串 prompt 或 job 对象：

```jsonl
"画一只猫"
{"prompt":"夕阳下的山脉","size":"16:9","name":"mountain-01"}
{"prompt":"机器人插画","size":"1:1","n":2,"name":"robot-02"}
```

```bash
~/.codex/skills/image-curl/scripts/generate_batch.sh \
  --input prompts.jsonl \
  --output-dir ./batch-out \
  --concurrency 4
```

`generate-batch` 不支持全局 `--output` / `--name`；精确输出路径在 job 对象中用 `out` 字段，文件名前缀用 `name` 字段。

## 传参调用

Codex 技能没有严格的参数协议。用户以 `key=value` 或自然语言说明参数时，应映射到对应脚本参数。

示例：

```text
$image-curl prompt="可爱猫女" name="catgirl" size="9:16@2k" quality="auto" format="png"
```

```text
$image-curl prompt="一只猫咪" output="./cat.png" base_url="https://aicode.cat"
```

```text
$image-curl image="./photo1.png" prompt="把背景换成星空" name="starry" size="1024x1024"
```

```text
$image-curl image="[Last Output]" image="[Image #1]" prompt="融合风格" name="merged"
```

生图专用 API Key 只写入 skill 目录 `local.env`。除非用户明确愿意，否则不要要求其把真实 API Key 写进对话，也不要写入全局客户端配置。

文生图常用字段：`prompt`、`output`、`output_dir`、`name`、`size`、`count`、`n`、`quality`、`format`、`output_compression`、`moderation`、`background`、`metadata`、`overwrite`、`dry_run`、`base_url`、`api_key`。

图生图另支持：`image`（可重复）、`image_set`、`mask`、`input_fidelity`。

`size` 可为 `auto`、`宽x高`、比例简写（如 `16:9`、`9:16@2k`）或档位（如 `2k`）。`count` / `n` 对应 API 的 `n` 参数。若上游接受但忽略 `n`，脚本会输出 `requested_count` 与 `returned_count`。

实用选项：

- `--prompt-file <txt>`：读取较长或多行提示词
- `--metadata <json>`：保存响应 metadata，省略体积庞大的 base64 图片内容
- `--overwrite`：仅在确需覆盖已有输出时使用
- `--dry-run`：校验配置与请求体，不实际调用接口
- `--base-url <url>` 或 `--api-key <key>`：仅在需要显式覆盖时使用

## 异常处理

- 覆盖 base URL：传入 `--base-url` 或设置 `IMAGE_CURL_BASE_URL`；否则使用 **`https://aicode.cat`**。
- 缺少 API Key：检查 skill 目录 `local.env` 是否已设置 `IMAGE_CURL_API_KEY`，或临时传入 `--api-key`。不要把生图专用 Key 补写到 `auth.json`。
- 输出文件已存在：改用新路径，或在用户同意覆盖时使用 `--overwrite`。
- 占位符 / `--image-set` 在无 `CODEX_THREAD_ID` 时报错：改用本地 `--image` 路径，或提示用户在 Codex 线程内运行。
- 非 JSON / HTTP 错误：保留命令输出中的错误正文，并向上游报告具体信息。
- 缺少 `b64_json`：检查响应 JSON，说明图片未按预期格式返回。