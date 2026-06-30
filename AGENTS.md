# 仓库协作指南

## 项目结构与模块划分

本仓库打包了一个名为 `image-curl` 的 Codex 技能。

- `skill_src/image-curl/SKILL.md`：skill metadata、触发规则、默认配置、工作流程与用户示例。
- `skill_src/image-curl/scripts/generate_image.sh`：面向 `/v1/images/generations` 的文生图实现。
- `skill_src/image-curl/scripts/edit_image.sh`：面向 `/v1/images/edits` 的图生图实现。
- `skill_src/image-curl/agents/openai.yaml`：技能展示信息与隐式调用策略。
- `README.md`：面向终端用户的安装与使用说明。

当前没有独立的测试目录或构建产物目录。生成图片与 metadata 已由 `.gitignore` 排除。

## 构建、测试与开发命令

本项目无构建步骤。请通过脚本帮助信息与 dry-run 流程验证改动：

```bash
bash skill_src/image-curl/scripts/generate_image.sh --help
bash skill_src/image-curl/scripts/edit_image.sh --help
bash skill_src/image-curl/scripts/generate_image.sh --prompt "测试" --output ./tmp.png --dry-run
```

本地安装以便手动测试 Codex：

```bash
mkdir -p ~/.codex/skills
cp -R ./skill_src/image-curl ~/.codex/skills/image-curl
chmod +x ~/.codex/skills/image-curl/scripts/*.sh
```

在 Windows 上，请通过 Git Bash 或 WSL 运行这些脚本，并保持 LF 换行。本 skill 依赖 `bash`、`curl`、`python3` 三个本机命令；跨平台说明与 Agent 排障规则见 `README.md` 的「系统要求」与 `SKILL.md` 的「运行环境与跨平台」。

## 代码风格与命名约定

Shell 脚本使用 Bash，启用 `set -euo pipefail`；参数采用 `--kebab-case` 长选项，变量名小写，并辅以 `usage`、`die` 等小型辅助函数。尽量保持可移植：在可行处使用偏 POSIX 的写法，变量要加引号，网络请求前先校验用户输入。`.sh` 文件保持 LF 换行。

Markdown 应结构清晰、示例完整，并尽量使用仓库内相对路径。修改行为时，请同步维护中文文档的一致性。

## 测试指南

当前未配置自动化测试框架。行为变更后，至少执行 `--help` 与一次 `--dry-run` 文生图路径。若涉及编辑逻辑，可在仓库外或忽略路径放置小样例图片，并测试 `edit_image.sh --dry-run`。不要提交生成的 `.png`、`.jpg`、`.jpeg`、`.webp` 或 `*.metadata.json` 文件。

## 提交与拉取请求（PR）规范

现有历史多采用简短祈使句提交说明，例如 `Add output compression option`、`Validate full GPT image size constraints`。请沿用这一风格：以动词开头，主题具体，句末不加标点。提交信息可继续使用英文祈使句，这是本仓库的 Git 惯例。

拉取请求（PR）应包含简要说明、变更的脚本或文档路径、手动验证命令，以及必要的 API 兼容性说明。如有相关议题（issue）请附上链接。仅在记录可视化输出时附带截图。

## 安全与配置提示

切勿提交 API Key、token、`local.env` 或真实 `auth.json` 数据。生图专用 Key 只放在 skill 目录 `local.env`，不要写入 `~/.codex/auth.json` 或 `~/.claude/settings.json`。错误信息应便于排查，但不要记录完整 Bearer Token 或 base64 图片内容。