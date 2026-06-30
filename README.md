# URL-image（curl 生图技能）

<p align="center">
  <img src="aicodecat.png" alt="aicode.cat 标识">
</p>

> Codex 生图技能 `image-curl` — 通过 `curl` 调用 OpenAI 兼容图片 API，完成文生图、图生图、批量生图与线程内改图。

`URL-image` 仓库打包了面向 [aicode.cat](https://aicode.cat) API 中转聚合平台的 Codex 生图技能。它通过 `curl` 直接调用图片接口，读取 skill 目录 `local.env` 中的生图专用 Key，并把结果保存为本地图片文件。

- 面向对话式生图，**默认接入 `https://aicode.cat`**
- 直接调用 `POST /v1/images/generations` 与 `POST /v1/images/edits`
- 默认模型：`gpt-image-2`
- 不依赖 `cpa`、`cliproxy-image-cli` 或其他额外生图 CLI
- 生图专用 API Key **仅**写入 skill 目录 `local.env`
- **用户一旦提出生图或改图需求，Codex 必须调用本技能，不得跳过脚本直接作答**

## 与 codex-image 的定位对比

| 维度 | **image-curl**（本仓库） | **codex-image** |
|---|---|---|
| 实现方式 | Bash / PowerShell + `curl` | Python 启动器 + 本地后处理 |
| 默认 API | Images API（`/v1/images/*`） | Images API，可选 Responses API |
| 默认 base URL | `https://aicode.cat` | 依安装配置 |
| Key 存放 | skill 目录 `local.env`（强制） | 依安装配置 |
| 尺寸简写 | `16:9`、`9:16@2k`、`2k` 等 | 同类简写 + 本地 resize 兜底 |
| 线程占位符 | `[Image #N]`、`[Last Output]`、`--image-set` | 同类机制 |
| 批量 | `generate-batch` + JSONL | `generate-batch` + JSONL |
| 适用场景 | 轻量 curl 直连、aicode.cat 生图专用 Key、跨平台 shell | 需要 Responses API、更复杂运行时或 Pillow 后处理 |

**选型建议：**

- 用户要本地文件、明确走 aicode.cat、或已配置生图专用 Key → **image-curl**
- 用户需要 Responses API 续接、`--transport responses`、或 codex-image 专属后处理 → **codex-image**
- 用户只需最快简单跟图、不需要本地路径控制 → 内置 `imagegen`（非本仓库）

## 功能

- 统一入口 `image-curl.sh` / `image-curl.ps1`：`generate`、`edit`、`generate-batch`
- 文生图与图生图编辑（multipart `images/edits`）
- 尺寸简写：`16:9`、`9:16@2k`、`2k`、`1k@16:9` 等
- 输出：`--output`、`--output-dir`、`--name`；默认 `~/.codex/generated_images/<thread|manual>/`
- 线程占位符：`[Image #N]`、`[Turn -1 Image #1]`、`[Thread Image #N]`、`[Last Output]`
- `--image-set`：`active`、`last-output`、`latest-turn`、`turn:-K`、`thread:1,2,5`
- 编辑增强：`--mask`（PNG 蒙版）、`--input-fidelity`（`low` / `high`）
- 批量 JSONL：`generate_batch.sh` / `generate_batch.ps1`
- dry-run、metadata、覆盖保护、多图 `count` / `n`

本技能支持文字生成图片和基于本地/线程引用的图生图编辑，不做网页搜图或 SVG 编辑。

## 系统要求

| 平台 | 统一入口 | 子脚本 | 额外依赖 |
|---|---|---|---|
| macOS / Linux | `image-curl.sh` | `*.sh` | `bash`、`curl`、`python3` |
| Windows | `image-curl.ps1` | `*.ps1` | PowerShell 5.1+、`curl.exe` |

### macOS

- 使用 `.sh` 脚本，skill 路径：`~/.codex/skills/image-curl/`

```bash
bash --version && curl --version && python3 --version
```

### Windows

- **推荐**在 **PowerShell** 里运行 `.ps1`，无需 Git Bash / WSL
- skill 路径：`%USERPROFILE%\.codex\skills\image-curl\`

```powershell
$PSVersionTable.PSVersion; curl.exe --version
```

## 安装

```bash
git clone https://github.com/KonglingDaDa/URL-image.git
cd URL-image

mkdir -p ~/.codex/skills
cp -R ./skill_src/image-curl ~/.codex/skills/image-curl
chmod +x ~/.codex/skills/image-curl/scripts/*.sh

cp ~/.codex/skills/image-curl/local.env.example ~/.codex/skills/image-curl/local.env
chmod 600 ~/.codex/skills/image-curl/local.env
```

Windows（PowerShell）：

```powershell
$skill = Join-Path $env:USERPROFILE '.codex\skills\image-curl'
Copy-Item (Join-Path $skill 'local.env.example') (Join-Path $skill 'local.env')
```

自定义 `CODEX_HOME` 时，将 `~/.codex/skills` 替换为 `$CODEX_HOME/skills`。

## 配置生图专用 Key（重要）

用户在密钥页面为「绿色生图专用分组」新生成的 Key，**只能配置在本 skill 内**：

```text
~/.codex/skills/image-curl/local.env
```

```bash
IMAGE_CURL_API_KEY=用户提供的生图专用-key
IMAGE_CURL_BASE_URL=https://aicode.cat
```

**禁止写入** `~/.codex/auth.json`、`~/.codex/config.toml`、`~/.claude/settings.json` 或任何全局配置。

验证配置：

```bash
~/.codex/skills/image-curl/scripts/image-curl.sh generate \
  --prompt "测试" --name test --dry-run
```

```powershell
& "$env:USERPROFILE\.codex\skills\image-curl\scripts\image-curl.ps1" generate `
  --prompt "测试" --name test --dry-run
```

确认 `authorization` 为 `Bearer ***` 且 `endpoint` 指向 `https://aicode.cat` 后，再执行真实生图。

## 在 Codex 中使用

```text
$image-curl 可爱猫女
$image-curl 生成横版赛博城市壁纸，尺寸 16:9，保存名 cyber-city
画一只坐在窗边的橘猫，温暖自然光
$image-curl image="./photo.png" prompt="把背景换成星空" name="starry"
$image-curl image="[Last Output]" prompt="继续细化上次结果" name="refined"
```

批量：

```text
$image-curl generate-batch input="./prompts.jsonl" output_dir="./batch-out"
```

完整参数与占位符规则见 `skill_src/image-curl/SKILL.md` 与 `skill_src/image-curl/references/cli.md`。

## 直接运行脚本

### 统一入口

```bash
~/.codex/skills/image-curl/scripts/image-curl.sh generate \
  --prompt "一只猫咪" --name cat --size 9:16@2k
```

### 文生图

```bash
~/.codex/skills/image-curl/scripts/generate_image.sh \
  --prompt "日系插画猫女头像" \
  --output ./catgirl.png \
  --size 1024x1024
```

### 图生图

```bash
~/.codex/skills/image-curl/scripts/edit_image.sh \
  --image ./photo.png \
  --prompt "把背景换成星空" \
  --mask ./mask.png \
  --input-fidelity high \
  --name starry
```

### 批量

```bash
~/.codex/skills/image-curl/scripts/generate_batch.sh \
  --input ./prompts.jsonl \
  --output-dir ./batch-out
```

## 配置读取规则

**base URL** 顺序：`local.env` 的 `IMAGE_CURL_BASE_URL` → 环境变量 → 默认 **`https://aicode.cat`**

**API Key** 顺序：`local.env` 的 `IMAGE_CURL_API_KEY`（推荐）→ `--api-key` → 环境变量 → `auth.json`（兜底，勿放生图 Key）

## 项目结构

```text
skill_src/
  image-curl/
    SKILL.md
    local.env.example
    references/
      cli.md
    agents/
      openai.yaml
    scripts/
      image-curl.sh / image-curl.ps1
      common.sh / ImageCurl.Common.ps1
      generate_image.sh / generate_image.ps1
      edit_image.sh / edit_image.ps1
      generate_batch.sh / generate_batch.ps1
      lib/
        normalize_size.py
        thread_state.py
        parse_batch_jsonl.py
    tests/
README.md
AGENTS.md
```