#requires -Version 5.1
$ErrorActionPreference = 'Stop'

$ScriptDir = $PSScriptRoot

function Show-ImageCurlUsage {
    @'
用法：
  image-curl.ps1 <子命令> [选项...]

子命令：
  generate         文生图（转发至 generate_image.ps1）
  edit             图生图/编辑（转发至 edit_image.ps1）
  generate-batch   批量文生图（转发至 generate_batch.ps1）
  generate_batch   generate-batch 的别名
  help             显示此帮助（默认）

示例：
  image-curl.ps1 generate --prompt "一只猫" --output .\cat.png
  image-curl.ps1 edit --image .\photo.png --prompt "换背景" --output .\out.png
  image-curl.ps1 generate-batch --input prompts.jsonl --output-dir .\batch-out

也可用各子命令独立脚本：generate_image.ps1、edit_image.ps1、generate_batch.ps1
'@ | Write-Output
}

if ($args.Count -eq 0) {
    Show-ImageCurlUsage
    exit 0
}

$cmd = $args[0]
$rest = @()
if ($args.Count -gt 1) {
    $rest = $args[1..($args.Count - 1)]
}

switch -Regex ($cmd) {
    '^(help|-h|--help)$' {
        Show-ImageCurlUsage
        exit 0
    }
    '^generate$' {
        & (Join-Path $ScriptDir 'generate_image.ps1') @rest
        exit $LASTEXITCODE
    }
    '^edit$' {
        & (Join-Path $ScriptDir 'edit_image.ps1') @rest
        exit $LASTEXITCODE
    }
    '^(generate-batch|generate_batch)$' {
        & (Join-Path $ScriptDir 'generate_batch.ps1') @rest
        exit $LASTEXITCODE
    }
    default {
        [Console]::Error.WriteLine("未知子命令: $cmd")
        Show-ImageCurlUsage | ForEach-Object { [Console]::Error.WriteLine($_) }
        exit 1
    }
}