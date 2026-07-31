# Agent 指引（image-curl）

本文档面向在 Codex / Claude 等环境中代为执行生图任务的 Agent。用户文档见 `README.md`，技能细则见 `skill_src/image-curl/SKILL.md`，CLI 速查见 `skill_src/image-curl/references/cli.md`。

## 强制调用

只要用户提出绘制、生成、创作、编辑、变换图片，或图生图并希望得到**本地位图文件**，就必须调用 `image-curl` 并执行脚本。**不得**在未运行脚本的情况下用文字描述画面冒充生图结果，也**不得**改用 `cpa`、`cliproxy-image-cli` 或其他生图 CLI。

排除情形：网页搜图、纯 SVG / 矢量编辑。

## 技能选型

| 场景 | 选用 |
|---|---|
| 用户要本地图片文件；走 aicode.cat；已配生图专用 Key | **image-curl**（本技能） |
| 用户要 `curl` 直连 Images API，轻量跨平台 shell | **image-curl** |
| 用户要批量 JSONL、线程占位符改图、`--mask` | **image-curl** |
| 用户明确要 Responses API、`--transport responses`、续接 `response_id` | **codex-image** |
| 用户要 codex-image 的 Pillow 本地 resize 等后处理 | **codex-image** |
| 用户只需最快跟图、不需控制输出路径 | 内置 **imagegen**（非本仓库） |

**默认**：对话中生图请求优先 **image-curl**，除非用户点名其他工具或任务明显需要 Responses API。

## 平台与脚本选择

| 平台 | 统一入口 | 禁止 |
|---|---|---|
| macOS / Linux | `image-curl.sh` → `generate` / `edit` / `generate-batch` | 在 Windows 上强推 `.sh` |
| Windows PowerShell | `image-curl.ps1` → 同上 | 用 `Invoke-WebRequest` 代替 `curl.exe` |

可直接调用子脚本（`generate_image.*`、`edit_image.*`、`generate_batch.*`），参数与统一入口一致。

脚本路径（Agent 必须按实际环境选择，**不要**在仓库内硬编码 `~/.codex/skills/...`）：

| 场景 | macOS / Linux | Windows |
|---|---|---|
| **仓库内开发 / 安装验证**（未 cp 到 skill 目录） | `<仓库绝对路径>/skill_src/image-curl/scripts/image-curl.sh` | `<仓库>\skill_src\image-curl\scripts\image-curl.ps1` |
| **已安装到 Codex skill 目录** | `~/.codex/skills/image-curl/scripts/image-curl.sh` | `%USERPROFILE%\.codex\skills\image-curl\scripts\image-curl.ps1` |

判定顺序：若当前工作区存在 `skill_src/image-curl/scripts/image-curl.sh`（或 `.ps1`），**优先用仓库内脚本**；`local.env` 写在同目录的上一级 `skill_src/image-curl/local.env`。仅当用户明确要求「安装到 Codex」或仓库内不存在 skill 时，再 `cp -R` 到 `~/.codex/skills/image-curl`。

## 配置与 Key

- 默认 base URL：**`https://aicode.cat`**
- 生图专用 API Key **只能**写在 skill 目录 `local.env` 的 `IMAGE_CURL_API_KEY`
- **禁止**写入 `~/.codex/auth.json`、`~/.claude/settings.json` 或全局配置
- 安装后先 `--dry-run` 再真实生图（generate / edit / batch 的 `--dry-run` 均可在无 API Key 时做自检）

## 子命令选型

| 用户意图 | 子命令 | 注意 |
|---|---|---|
| 纯文字生图 | `generate` | 不要传 `--image` |
| 基于已有图片编辑 / 多图融合 | `edit` | 必须让模型看到图 → 用 `edit` |
| 多张 prompt 批量出图 | `generate-batch` | 需 `--input` JSONL + `--output-dir` |
| 继续改上次输出 | `edit` + `--image-set last-output` 或 `--image '[Last Output]'` | edit 不隐式继承状态 |
| 引用对话附件 | `edit` + `--image '[Image #N]'` 等 | 需 Codex 线程 ID |
| 局部编辑（蒙版） | `edit` + `--mask` | PNG，透明区为编辑区 |
| 高保真保留输入 | `edit` + `--input-fidelity high` | 仅 `low` / `high` |

## 输出路径策略

1. 用户给了明确路径 → `--output`
2. 用户只要文件名或语义名 → `--name`（默认目录见下）
3. 批量或多文件到指定目录 → `--output-dir` + `--name`
4. 三者都不给 → 脚本报错，Agent 应补 `--name` 或 `--output`

**默认输出目录**（仅 `--name`、无 `--output-dir` 时）：按优先级选**首个可写**路径：

1. `local.env` 或环境中的 `IMAGE_CURL_OUTPUT_DIR/<thread|manual>/`
2. `${CODEX_HOME:-~/.codex}/generated_images/<thread|manual>/`
3. `./.image-curl-output/<thread|manual>/`（沙箱禁止写 `~/.codex` 时的自动回退）

沙箱 / 只读 home 下做 dry-run 或真实生图时，若未指定 `--output`，脚本会自动落到工作区 `.image-curl-output/`；也可显式 `--output-dir ./generated` 指向仓库或工作区。

## 尺寸

`--size` **只能**用白名单（运行时源：`scripts/lib/allowed_sizes.json`）。下表为紧凑参考；维护以 JSON / `SKILL.md` 为准。

### 要用

| 输入 | 发给上游 | 说明 |
|---|---|---|
| `1024x1024` | `1024x1024` | **默认** |
| `auto` | `auto` | 自适应 |
| `1280x720` | `1280x720` | 720p 横版 |
| `1k` | `1024x1024` | 1K 正方形 |
| `2k` | `2048x2048` | 2K 正方形 |
| `16:9` | `3840x2160` | 横版全尺寸 |
| `9:16` | `2160x3840` | 竖版全尺寸 |
| `1:1` | `2880x2880` | 正方形全尺寸 |
| `3:1` | `3840x1280` | 超宽横版 |
| `1:3` | `1280x3840` | 超高竖版 |
| `9:16@1k` | `1008x1792` | 1K 竖版 |
| `9:16@2k` | `2016x3584` | 2K 竖版 |
| `1k@16:9` | `1792x1008` | 1K 横版 |
| `16:9@1k` | `1792x1008` | 1K 横版（等价） |
| `16:9@2k` | `3584x2016` | 2K 横版 |
| `4k@16:9` | `3840x2160` | 4K 横版 |
| `16:9@4k` | `3840x2160` | 4K 横版（等价） |
| `4k@9:16` | `2160x3840` | 4K 竖版 |
| `9:16@4k` | `2160x3840` | 4K 竖版（等价） |

### 不要用

| 输入 | 请改用 |
|---|---|
| `4k` | `4k@16:9` / `16:9@4k` / `4k@9:16` / `9:16@4k` |
| `1000x1800` | `9:16@1k` / `9:16` |
| `1920x1080` | `16:9` |
| `1080x1920` | `9:16` |
| `800x600` | `16:9@1k` / `1k@16:9` |
| `512x512` | `1k` / `1024x1024` |
| `4096x4096` | `4k@16:9` / `16:9` / `2k` |
| `3840x2160` | `16:9` / `4k@16:9` |
| `2160x3840` | `9:16` / `9:16@4k` |

- 用户说横版 → `16:9`；竖版 → `9:16`；要 4K → `4k@16:9` / `9:16@4k`（**不要**单独写 `4k`）
- 未指定尺寸 → `1024x1024`

## 错误处理

按以下顺序排查并向用户说明：

| 现象 | 处理 |
|---|---|
| `缺少 API Key` / 401 | 检查 `local.env` 中 `IMAGE_CURL_API_KEY`；勿写 `auth.json` |
| `输出文件已存在` | 换 `--name` / 新路径，或用户同意后 `--overwrite` |
| `必须提供 --output、--output-dir 或 --name` | 补输出参数 |
| rollout 占位符 / `--image-set` 报错 | 确认在 Codex 线程内（`CODEX_THREAD_ID`）；或改本地 `--image` 路径 |
| `未找到线程 … rollout` | 线程无 session 记录；改用本地文件路径 |
| `curl` 非零退出 / HTTP 错误 | 保留 stderr 正文；检查 base URL 是否为 `https://aicode.cat` |
| 缺少 `b64_json` / `url` | 网关应给 `data[].b64_json` 或可下载 `data[].url`；脚本会先解码 b64，否则下载 url（预签名无鉴权优先，401/403 再带 Bearer）。仍失败则上报响应字段与下载错误 |
| Windows 找不到 `curl` | 提示启用系统 `curl.exe`，不用 `Invoke-WebRequest` |
| `.sh` Permission denied | `chmod +x scripts/*.sh` |
| macOS `local -n` / `mapfile` / 语法错误 | 仓库脚本已兼容 Bash 3.2；请更新到最新 skill 并重新 `cp -R` 安装 |
| `unbound variable` / 空数组（仅 `--image`、无 `--image-set`） | 更新到最新版 `common.sh` / `edit_image.sh`；勿在客户环境手改兼容补丁 |
| dry-run 在 `~/.codex/generated_images` 建目录失败 | 沙箱限制；用仓库内脚本 + 自动回退 `.image-curl-output`，或 `--output-dir` 指向工作区 |
| `generate` 收到 `--image` | 改用 `edit` |
| `requested_count` ≠ `returned_count` | 上游忽略 `n`；告知用户实际返回张数 |
| 尺寸校验失败 / `不要用` / `不支持的 --size` | 从 SKILL.md「要用」表选值；1080p 用 `16:9`/`9:16`，4K 用 `4k@16:9` 等 |

失败时保留命令输出中的错误正文，不要泄露完整 Bearer Token 或 base64 图片。

## 验证改动（维护者）

```bash
bash skill_src/image-curl/scripts/image-curl.sh help
bash skill_src/image-curl/scripts/generate_image.sh --dry-run --prompt "测试" --name t
bash skill_src/image-curl/tests/run_bash_compat_check.sh
bash skill_src/image-curl/tests/run_dry_run_no_key.sh
bash skill_src/image-curl/tests/run_batch_dry_run_no_key.sh
bash skill_src/image-curl/tests/run_saved_files_schema_tests.sh
bash skill_src/image-curl/tests/run_size_tests.sh
bash skill_src/image-curl/tests/run_allowed_size_tests.sh
bash skill_src/image-curl/tests/run_catalog_consistency_tests.sh
bash skill_src/image-curl/tests/run_thread_state_tests.sh
bash skill_src/image-curl/tests/run_batch_aggregate_tests.sh
bash skill_src/image-curl/tests/run_edit_dry_run_fixture.sh
bash skill_src/image-curl/tests/run_default_output_dir_tests.sh
```

Windows：

```powershell
& skill_src/image-curl/scripts/image-curl.ps1 help
& skill_src/image-curl/tests/run_dry_run_no_key.ps1
& skill_src/image-curl/tests/run_edit_dry_run_fixture.ps1
& skill_src/image-curl/tests/run_size_tests.ps1
& skill_src/image-curl/tests/run_allowed_size_tests.ps1
& skill_src/image-curl/tests/run_thread_state_tests.ps1
& skill_src/image-curl/tests/run_saved_files_schema_tests.ps1
& skill_src/image-curl/tests/run_catalog_consistency_tests.ps1
```

仅 bash、尚无 PS 对应：`run_bash_compat_check`、`run_batch_dry_run_no_key`、`run_batch_aggregate_tests`、`run_default_output_dir_tests`。

## 仓库结构（维护者）

- `skill_src/image-curl/SKILL.md` — 触发规则、工作流程
- `skill_src/image-curl/references/cli.md` — CLI 速查
- `skill_src/image-curl/scripts/` — 实现（`common.sh`、`ImageCurl.Common.ps1` 共享层）
- `skill_src/image-curl/tests/` — 尺寸、线程状态、batch fixture

修改行为时同步更新中文文档。不要提交 `local.env`、API Key 或生成的图片文件。