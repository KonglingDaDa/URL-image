#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
用法：
  image-curl.sh <子命令> [选项...]

子命令：
  generate         文生图（转发至 generate_image.sh）
  edit             图生图/编辑（转发至 edit_image.sh）
  generate-batch   批量文生图（转发至 generate_batch.sh）
  generate_batch   generate-batch 的别名
  help             显示此帮助（默认）

示例：
  image-curl.sh generate --prompt "一只猫" --output ./cat.png
  image-curl.sh edit --image ./photo.png --prompt "换背景" --output ./out.png
  image-curl.sh generate-batch --input prompts.jsonl --output-dir ./batch-out

也可用各子命令独立脚本：generate_image.sh、edit_image.sh、generate_batch.sh
USAGE
}

if [[ $# -eq 0 ]]; then
  usage
  exit 0
fi

cmd="$1"
shift

case "$cmd" in
  help|-h|--help)
    usage
    exit 0
    ;;
  generate)
    exec "$script_dir/generate_image.sh" "$@"
    ;;
  edit)
    exec "$script_dir/edit_image.sh" "$@"
    ;;
  generate-batch|generate_batch)
    exec "$script_dir/generate_batch.sh" "$@"
    ;;
  *)
    printf '未知子命令: %s\n' "$cmd" >&2
    usage >&2
    exit 1
    ;;
esac