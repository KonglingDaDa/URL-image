# Repository Guidelines

## Project Structure & Module Organization

This repository packages a Codex skill named `image-curl`.

- `skill_src/image-curl/SKILL.md` contains the skill metadata, trigger guidance, defaults, workflow, and user-facing examples.
- `skill_src/image-curl/scripts/generate_image.sh` implements text-to-image requests against `/v1/images/generations`.
- `skill_src/image-curl/scripts/edit_image.sh` implements image-to-image requests against `/v1/images/edits`.
- `skill_src/image-curl/agents/openai.yaml` defines the skill display metadata and implicit invocation policy.
- `README.md` mirrors installation and usage documentation for end users.

There is currently no dedicated test directory or build output directory. Generated images and metadata are intentionally ignored by `.gitignore`.

## Build, Test, and Development Commands

There is no build step. Validate changes with script help and dry-run flows:

```bash
bash skill_src/image-curl/scripts/generate_image.sh --help
bash skill_src/image-curl/scripts/edit_image.sh --help
bash skill_src/image-curl/scripts/generate_image.sh --prompt "test" --output ./tmp.png --dry-run
```

Install locally for manual Codex testing:

```bash
mkdir -p ~/.codex/skills
cp -R ./skill_src/image-curl ~/.codex/skills/image-curl
chmod +x ~/.codex/skills/image-curl/scripts/*.sh
```

On Windows, run these scripts from Git Bash or WSL with LF line endings.

## Coding Style & Naming Conventions

Shell scripts use Bash with `set -euo pipefail`, long `--kebab-case` flags, lowercase variable names, and small helper functions such as `usage` and `die`. Keep scripts portable: prefer POSIX-friendly shell constructs where practical, quote variables, and validate user input before network calls. Preserve LF line endings for `.sh` files.

Markdown files should use concise headings, fenced examples, and repository-relative paths. Keep English and Chinese documentation consistent when changing behavior.

## Testing Guidelines

No automated test framework is configured. For behavioral changes, run `--help` plus at least one `--dry-run` generation path. For edit behavior, add a small local sample image outside the repository or in an ignored path and test `edit_image.sh --dry-run`. Do not commit generated `.png`, `.jpg`, `.jpeg`, `.webp`, or `*.metadata.json` files.

## Commit & Pull Request Guidelines

The existing history uses short imperative commit subjects, for example `Add output compression option` and `Validate full GPT image size constraints`. Follow that style: start with a verb, keep the subject specific, and avoid trailing punctuation.

Pull requests should include a brief summary, changed script or documentation paths, manual validation commands, and any API compatibility notes. Link related issues when available. Include screenshots only when documenting generated visual output.

## Security & Configuration Tips

Never commit API keys, tokens, local Codex config, or real `auth.json` data. Prefer environment variables such as `IMAGE_CURL_API_KEY` and `IMAGE_CURL_BASE_URL` for local testing. Keep error output useful, but avoid logging full bearer tokens or base64 image payloads.
