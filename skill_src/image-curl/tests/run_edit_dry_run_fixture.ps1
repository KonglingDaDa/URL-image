#requires -Version 5.1
# Acceptance helper: edit_image.ps1 --image-set last-output --dry-run with fixture CODEX_HOME
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SkillRoot = Split-Path -Parent $ScriptDir
$EditScript = Join-Path $SkillRoot 'scripts/edit_image.ps1'

$failures = 0
$total = 0

function Assert-Test {
    param([string]$Name, [scriptblock]$Body)
    $script:total++
    try {
        & $Body
        Write-Host "OK   $Name" -ForegroundColor Green
    } catch {
        $script:failures++
        Write-Host "FAIL $Name" -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)"
    }
}

$savedKey = $env:IMAGE_CURL_API_KEY
Remove-Item Env:IMAGE_CURL_API_KEY -ErrorAction SilentlyContinue
Remove-Item Env:OPENAI_API_KEY -ErrorAction SilentlyContinue
Remove-Item Env:CLIPROXY_API_KEY -ErrorAction SilentlyContinue

try {
    Assert-Test 'edit_image.ps1 dry-run resolves last-output without API key' {
        $codexHome = Join-Path $env:TEMP ("image-curl-edit-dry-" + [guid]::NewGuid().ToString('N'))
        try {
            $threadDir = Join-Path $codexHome 'generated_images\manual'
            New-Item -ItemType Directory -Path $threadDir -Force | Out-Null
            $first = Join-Path $threadDir 'first-out.png'
            $bytes = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==')
            [IO.File]::WriteAllBytes($first, $bytes)
            @{ thread_id = 'manual'; images = @(([System.IO.Path]::GetFullPath($first))) } |
                ConvertTo-Json | Set-Content (Join-Path $threadDir 'last_output_set.json') -Encoding UTF8

            $env:CODEX_HOME = $codexHome
            Remove-Item Env:CODEX_THREAD_ID -ErrorAction SilentlyContinue
            Remove-Item Env:CODEX_SESSION_ID -ErrorAction SilentlyContinue

            $out = & $EditScript --image-set last-output --prompt test --name dry-test --dry-run
            $json = ($out | Out-String).Trim() | ConvertFrom-Json
            $images = @($json.multipart.'image[]')
            if ($images.Count -ne 1) { throw "expected 1 resolved image, got $($images.Count)" }
            $expected = $first.Replace('\', '/')
            if ($images[0] -ne $expected) { throw "path mismatch: $($images[0]) vs $expected" }
        } finally {
            Remove-Item -LiteralPath $codexHome -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Assert-Test 'edit_image.ps1 dry-run preserves quoted prompt' {
        $img = Join-Path $env:TEMP ("edit-dry-quote-$([guid]::NewGuid().ToString('N')).png")
        $bytes = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==')
        [IO.File]::WriteAllBytes($img, $bytes)
        try {
            $quotedPrompt = 'say "hello"'
            $out = & $EditScript --image $img --prompt $quotedPrompt --name dry-quote --dry-run
            $json = ($out | Out-String).Trim() | ConvertFrom-Json
            if ($json.multipart.prompt -notmatch [regex]::Escape('say "hello"')) {
                throw "quoted prompt not preserved: $($json.multipart.prompt)"
            }
        } finally {
            Remove-Item -LiteralPath $img -Force -ErrorAction SilentlyContinue
        }
    }
} finally {
    if ($savedKey) { $env:IMAGE_CURL_API_KEY = $savedKey }
}

if ($failures -gt 0) {
    Write-Error "$failures/$total edit dry-run fixture tests failed."
    exit 1
}

Write-Host ""
Write-Host "All $total edit dry-run fixture tests passed." -ForegroundColor Green