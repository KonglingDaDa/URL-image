# Agent 指引（image-curl）

本仓库技能名 **image-curl**（GitHub：`KonglingDaDa/URL-image`）。给所有在本仓干活的 Agent：对话生图必须跑脚本；改技能则对行为、测试与中文文档一起负责。

| 文档 | 职责 |
|---|---|
| **本文件** | 硬规则、架构、维护与验证、发布 |
| `skill_src/image-curl/SKILL.md` | 给使用方 Agent：触发、选模型、安装、尺寸、占位符、排错（**用法唯一真源**） |
| `skill_src/image-curl/references/cli.md` | CLI 速查 |
| `skill_src/image-curl/scripts/lib/allowed_sizes.json` | **`--size` 唯一运行时真源**（GPT `allowed` / `forbidden` + `gemini` 表） |
| `README.md` | 给人看的安装与使用说明 |

改行为时同步 `SKILL.md`、`cli.md`、`README.md`，必要时改本文件；改尺寸先改 JSON。

## 强制调用

只要用户提出绘制、生成、创作、编辑、变换图片，或图生图并希望得到**本地位图文件**，就必须调用 `image-curl` 并**实际执行脚本**。不得用文字描述画面冒充生图结果，也不得改用 `cpa`、`cliproxy-image-cli` 或其他生图 CLI。排除：网页搜图、纯 SVG / 矢量编辑。

成功后报告保存路径；未要求时不展开 metadata。提示词太笼统时先改写成可直接生图的短提示。失败时保留错误正文，不泄露完整 Key 或图片 base64。

## 技能选型

| 场景 | 选用 |
|---|---|
| 要本地图片文件、走 aicode.cat、已配生图 Key | **image-curl**（GPT 或 Gemini 模型） |
| 批量 JSONL、线程占位符改图、`--mask` | **image-curl** |
| 明确要 Responses API、续接 `response_id`、Pillow 后处理 | **codex-image**（非本仓库） |
| 只需最快跟图、不需控制输出路径 | 内置 **imagegen**（非本仓库） |

本仓库脚本**没有** Responses API / Pillow 实现。

## 架构

```text
image-curl.sh / *.sh  ─┐  只找 Python 3.8+，原样转交参数（common.sh）
image-curl.ps1 / *.ps1 ┘  参数写成 UTF-8 JSON 文件交给 --argv-file（ImageCurl.Common.ps1）
        ↓
scripts/lib/image_curl.py   全部行为：参数解析、Key / base URL、尺寸、输出路径、
                            请求构造、curl 调用、响应保存、重试、批量、models、dry-run
        ├─ normalize_size.py + allowed_sizes.json   尺寸
        ├─ thread_state.py                          占位符与线程状态
        └─ parse_batch_jsonl.py                     批量输入
```

硬规则：

- **行为只改 `image_curl.py`**（或它引用的 lib）。`.sh` / `.ps1` 不加业务逻辑，否则两端会再次分叉。
- 按模型名选接口：`gemini-*` / 含 `nano-banana` → `POST /v1beta/models/{model}:generateContent`（`x-goog-api-key`）；其余 → `POST /v1/images/*`（Bearer）。`--provider` 可覆盖。
- HTTP 一律走系统 `curl`；带 Key 的请求头经 stdin（`curl -K -`）传入，**不进命令行**。
- PowerShell 必须走 `--argv-file`：Windows PowerShell 5.1 给原生程序传参会弄坏引号、空格和 `#`。
- Bash 脚本兼容 macOS 自带 **Bash 3.2**：禁止 `local -n`、`mapfile`、`${var,,}` 等 Bash 4+ 语法（`run_bash_compat_check.sh` 会查）。
- Python 代码保持 3.8 可运行：不用 `match`、`str.removeprefix`、`zip(strict=)` 等新语法。
- 错误统一抛 `CliError`（主程序打印 `错误：…`，退出码 1）；值得重试的抛 `RetryableError`（无图返回、429/5xx、网络抖动、url 下载失败），次数由 `IMAGE_CURL_SAVE_RETRIES` 控制（默认 3）。不要吞错，也不要静默回退到别的接口。

## 网关事实（2026-11-16 实测 aicode.cat）

- GPT 分组 `/v1/models`：`gpt-image-2`、`gpt-image-2.5`、`gpt-image-2.6` 及 `-flare` / `-sunburst` 档位。
- Gemini 分组 `/v1beta/models`：`gemini-3.1-flash-image`、`gemini-nano-banana-2.1`。
- Gemini 分组的 Key 调 `/v1/images/*` 返回 404 `Images API is not supported for this platform`；GPT 分组的 Key 调 Gemini 返回 400 `API key group platform is not gemini`。
- Gemini 只返回 JPEG（`outputMimeType` 被忽略），每次一张；`imageSize` 的 `512` 被忽略；不合法的 `aspectRatio` 不报错而是被忽略，所以客户端必须自己校验。
- `gemini-nano-banana-2.1` 不传 `imageConfig` 时默认出 16:9；文生图要显式传 `1:1`。
- 实测像素见 `SKILL.md`「Gemini 尺寸」。网关或上游变化后，重测再改 JSON 和文档。

## 配置与 Key

Key **只能**写在 skill 目录 `local.env`：GPT 分组 → `IMAGE_CURL_API_KEY`，Gemini 分组 → `IMAGE_CURL_GEMINI_API_KEY`。禁止写入 `~/.codex/auth.json`、`~/.codex/config.toml`、`~/.claude/settings.json` 或任何全局配置；不要把真实 Key 写进对话或提交进 git。`local.env` 的值优先于同名环境变量；测试用 `IMAGE_CURL_ENV_FILE` 指向别的文件来隔离。读取顺序与其他变量见 `SKILL.md`。

本仓内生图用仓库脚本：`<仓库>/skill_src/image-curl/scripts/image-curl.sh`（Windows `.ps1`），`local.env` 在 `skill_src/image-curl/local.env`。用户明确要求时才复制到 `~/.codex/skills/image-curl` 或 `~/.claude/skills/image-curl`。

## 验证改动（维护者）

在仓库根运行（全部离线，不扣费；端到端用 `tests/fakes/curl` 假装网关）：

```bash
python3 -m pytest -q -p no:cacheprovider skill_src/image-curl/tests
for t in skill_src/image-curl/tests/*.sh; do bash "$t" || echo "FAIL $t"; done
for t in skill_src/image-curl/tests/*.ps1; do pwsh -NoProfile -File "$t" || echo "FAIL $t"; done
```

- `test_image_curl.py`：核心单测 + 假 curl 端到端（GPT / Gemini 生图、改图、多张、重试、报错提示、批量混用、`--argv-file`、`models`）。
- `test_thread_state.py`：占位符解析。
- `*.sh` / `*.ps1`：经真实入口脚本跑 dry-run（尺寸白名单、目录回退、占位符、带 `#` 的路径与引号）。

改 `allowed_sizes.json` 后必须跑 `run_catalog_consistency_tests.*`、`run_allowed_size_tests.*`、`run_size_tests.*`。改请求或保存逻辑后，再用真实 Key 各跑一次 GPT 与 Gemini 的 `generate` / `edit`（会扣费，次数从简）。

## 发布

1. 上面三组测试全绿，必要时完成真实调用。
2. 同步 `SKILL.md`、`cli.md`、`README.md`。
3. 提交到 `main` 并推送 `origin`（`KonglingDaDa/URL-image`）。用户安装方式是克隆后复制 `skill_src/image-curl`，推送即发布。

## 仓库结构

```text
AGENTS.md                 本文件
README.md                 用户文档
LICENSE / LICENSE.zh-CN
aicodecat.png             唯一入库的示例图
skill_src/image-curl/
  SKILL.md
  local.env.example       复制为 local.env（不入库）
  agents/openai.yaml      Codex 隐式调用策略
  references/cli.md
  scripts/
    image-curl.sh / image-curl.ps1
    generate_image.* / edit_image.* / generate_batch.*
    common.sh / ImageCurl.Common.ps1
    lib/
      image_curl.py
      allowed_sizes.json
      normalize_size.py
      thread_state.py
      parse_batch_jsonl.py
  tests/
    test_image_curl.py / test_thread_state.py
    fakes/curl            测试用假 curl
    run_*.sh / run_*.ps1
```

不要提交 `local.env`、API Key、生成的图片、`.image-curl-output/`。根目录其它 `*.png` 已被 gitignore（`aicodecat.png` 除外）。
