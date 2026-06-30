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

路径示例：

- macOS：`~/.codex/skills/image-curl/scripts/image-curl.sh`
- Windows：`%USERPROFILE%\.codex\skills\image-curl\scripts\image-curl.ps1`

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
2. 用户只要文件名或语义名 → `--name`（写入 `~/.codex/generated_images/<thread|manual>/`）
3. 批量或多文件到指定目录 → `--output-dir` + `--name`
4. 三者都不给 → 脚本报错，Agent 应补 `--name` 或 `--output`

## 尺寸

- 支持 `auto`、`宽x高`、比例（`16:9`）、档位（`2k`）、组合（`9:16@2k`）
- 不合法尺寸做最小调整以满足上游约束（最长边 ≤3840、16 倍数、宽高比 ≤3:1、像素范围）
- 用户只说横版/竖版/1K/2K/4K 时，选合适简写，不要强行正方形

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
| 缺少 `b64_json` | 上报响应 JSON 结构异常 |
| Windows 找不到 `curl` | 提示启用系统 `curl.exe`，不用 `Invoke-WebRequest` |
| `.sh` Permission denied | `chmod +x scripts/*.sh` |
| `generate` 收到 `--image` | 改用 `edit` |
| `requested_count` ≠ `returned_count` | 上游忽略 `n`；告知用户实际返回张数 |
| 尺寸校验失败 | 建议合法简写（如 `16:9`）或合规 `宽x高` |

失败时保留命令输出中的错误正文，不要泄露完整 Bearer Token 或 base64 图片。

## 验证改动（维护者）

```bash
bash skill_src/image-curl/scripts/image-curl.sh help
bash skill_src/image-curl/scripts/generate_image.sh --dry-run --prompt "测试" --name t
bash skill_src/image-curl/tests/run_size_tests.sh
bash skill_src/image-curl/tests/run_thread_state_tests.sh
```

Windows：

```powershell
& skill_src/image-curl/scripts/image-curl.ps1 help
& skill_src/image-curl/tests/run_size_tests.ps1
& skill_src/image-curl/tests/run_thread_state_tests.ps1
```

## 仓库结构（维护者）

- `skill_src/image-curl/SKILL.md` — 触发规则、工作流程
- `skill_src/image-curl/references/cli.md` — CLI 速查
- `skill_src/image-curl/scripts/` — 实现（`common.sh`、`ImageCurl.Common.ps1` 共享层）
- `skill_src/image-curl/tests/` — 尺寸、线程状态、batch fixture

修改行为时同步更新中文文档。不要提交 `local.env`、API Key 或生成的图片文件。