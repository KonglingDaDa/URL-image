# CLI 速查（`image-curl` 统一入口）

默认 base URL：`https://aicode.cat`。生图专用 API Key **只**写入 skill 目录 `local.env`。

## 统一入口

| 平台 | 启动器 |
|---|---|
| macOS / Linux | `scripts/image-curl.sh` |
| Windows PowerShell | `scripts/image-curl.ps1` |

子命令：`generate`（文生图）、`edit`（图生图/编辑）、`generate-batch`（批量文生图）、`help`。

也可直接调用子脚本：`generate_image.*`、`edit_image.*`、`generate_batch.*`。

**脚本根目录**：仓库内为 `skill_src/image-curl`；安装后为 `~/.codex/skills/image-curl`（Windows：`%USERPROFILE%\.codex\skills\image-curl`）。Agent 在仓库内开发时**必须用仓库路径**，不要写死 `~/.codex/skills/...`。

```bash
# macOS / Linux — SKILL_ROOT 按上表替换
SKILL_ROOT=./skill_src/image-curl
"$SKILL_ROOT/scripts/image-curl.sh" generate --prompt "一只猫" --name cat
"$SKILL_ROOT/scripts/image-curl.sh" edit --image ./in.png --prompt "换背景" --name out
"$SKILL_ROOT/scripts/image-curl.sh" generate-batch --input prompts.jsonl --output-dir ./batch-out
```

```powershell
# Windows
& "$env:USERPROFILE\.codex\skills\image-curl\scripts\image-curl.ps1" generate --prompt "一只猫" --name cat
```

## 关键规则

- 用户要生图或改图并得到本地文件时，**必须调用本 skill**，不得跳过脚本直接作答。
- 模型需要看到真实图片输入时，用 `edit`，不要用 `generate`（`generate` 传 `--image` 会警告并应改用 `edit`）。
- `edit` **不隐式继承**线程图片状态；复用历史图须显式 `--image` 占位符或 `--image-set` 选择器。
- 占位符与 rollout 类 `--image-set` 需要 `CODEX_THREAD_ID` 或 `CODEX_SESSION_ID`；无会话时仍可用本地路径与 `[Last Output]`（若状态文件存在）。
- 默认输出目录（首个可写）：`IMAGE_CURL_OUTPUT_DIR` → `${CODEX_HOME:-~/.codex}/generated_images` → `./.image-curl-output`，其下 `<thread_id|manual>/`。
- `--output` 写精确路径；`--output-dir` + `--name` 生成「前缀-随机后缀」；仅 `--name` 写入默认目录。

## 常用选项

**generate / edit 共用：**

- `--prompt` / `--prompt-file`
- `--output` / `--output-dir` / `--name`
- `--model`（默认 `gpt-image-2`）
- `--size`：仅允许白名单格式（见下文「要用 / 不要用」）；完整列表见 `scripts/lib/allowed_sizes.json`
- `--quality`、`--format`、`--output-compression`、`--moderation`
- `--count` / `--n`（1–10）
- `--metadata`、`--overwrite`、`--dry-run`
- `--base-url`、`--api-key`（临时覆盖；常规 Key 在 `local.env`）

**edit 额外：**

- `--image`（本地路径或占位符，可重复）
- `--image-set`：`active`、`last-output`、`latest-turn`、`turn:-K`、`thread:1,2,5`
- `--mask`（PNG 蒙版，透明区域为编辑区）
- `--input-fidelity`：`low` 或 `high`

**generate-batch：**

- `--input` JSONL（必填）、`--output-dir`（必填）、`--concurrency`（默认 4）

## 占位符（`edit --image`）

| 占位符 | 含义 |
|---|---|
| `[Image #N]` | 最近一个含附件用户轮次第 N 张图 |
| `[Turn -K Image #N]` | 往前第 K 个含附件轮次第 N 张图 |
| `[Thread Image #N]` | 线程全局附件顺序第 N 张 |
| `[Last Output]` / `[Last Output #N]` | 本线程上次保存的输出图 |

变体如 `[Image#1]`、`[image # 1]` 会自动规范化。

## 尺寸：要用 / 不要用

完整白名单：`scripts/lib/allowed_sizes.json`。`--size` 只能填「要用」列中的值。

### 要用

| 输入 | 发给上游 |
|---|---|
| `1024x1024`（默认） | `1024x1024` |
| `auto` | `auto` |
| `1280x720` | `1280x720` |
| `1k` / `2k` | `1024x1024` / `2048x2048` |
| `16:9` / `9:16` / `1:1` | `3840x2160` / `2160x3840` / `2880x2880` |
| `3:1` / `1:3` | `3840x1280` / `1280x3840` |
| `9:16@1k` / `9:16@2k` | `1008x1792` / `2016x3584` |
| `1k@16:9` / `16:9@1k` / `16:9@2k` | `1792x1008` / `1792x1008` / `3584x2016` |
| `4k@16:9` / `16:9@4k` | `3840x2160` |
| `4k@9:16` / `9:16@4k` | `2160x3840` |

### 不要用

| 输入 | 请改用 |
|---|---|
| `4k` | `4k@16:9`、`16:9@4k`、`4k@9:16`、`9:16@4k` |
| `1920x1080` / `1080x1920` | `16:9` / `9:16` |
| `1000x1800` | `9:16@1k` / `9:16` |
| `3840x2160` / `2160x3840` | `16:9` / `9:16` |
| `512x512` | `1k` / `1024x1024` |
| 其他任意 `宽x高` | 最接近的「要用」简写 |

白名单内的显式像素（`1024x1024`、`1280x720`）会在提示词末尾追加画布约束说明。

## 批量 JSONL

每行一个字符串 prompt 或 job 对象：

```jsonl
"画一只猫"
{"prompt":"夕阳","size":"16:9","n":2,"name":"sunset-01"}
{"prompt":"海报","out":"./batch-out/custom.png"}
```

Job 可覆盖：`prompt`、`model`、`size`、`quality`、`background`、`format`、`compression`、`moderation`、`n`、`name`、`out`。

## 相关文档

- `SKILL.md`：触发规则、工作流程、Agent 必读
- `../agents/openai.yaml`：隐式调用策略