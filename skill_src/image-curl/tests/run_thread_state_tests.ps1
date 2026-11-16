#requires -Version 5.1
# Thread placeholders through the real entry script (edit_image.ps1 --dry-run).
# Also proves '#', spaces and quotes survive PowerShell -> Python (argv JSON file).
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

function New-TempDir {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("image-curl-thread-test-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    return $tmp
}

function Write-MinimalPng {
    param([string]$Path)
    $bytes = [Convert]::FromBase64String(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='
    )
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

function Get-DryRunImages {
    param($Output)
    $json = ($Output | Out-String).Trim() | ConvertFrom-Json
    return [string[]]@($json.multipart.'image[]')
}

foreach ($name in 'IMAGE_CURL_API_KEY', 'IMAGE_CURL_GEMINI_API_KEY', 'OPENAI_API_KEY', 'CLIPROXY_API_KEY', 'CODEX_THREAD_ID', 'CODEX_SESSION_ID') {
    Remove-Item "Env:$name" -ErrorAction SilentlyContinue
}
$env:IMAGE_CURL_ENV_FILE = Join-Path ([System.IO.Path]::GetTempPath()) 'image-curl-tests-no-local.env'
$savedCodexHome = $env:CODEX_HOME

try {
    Assert-Test 'edit resolves [Last Output #2] from manual fixture' {
        $codexHome = New-TempDir
        try {
            $threadDir = Join-Path (Join-Path $codexHome 'generated_images') 'manual'
            New-Item -ItemType Directory -Path $threadDir -Force | Out-Null
            $first = Join-Path $threadDir 'first-out.png'
            $second = Join-Path $threadDir 'second-out.png'
            Write-MinimalPng -Path $first
            Write-MinimalPng -Path $second
            $state = @{ thread_id = 'manual'; images = @($first, $second) } | ConvertTo-Json -Depth 5
            [System.IO.File]::WriteAllText((Join-Path $threadDir 'last_output_set.json'), $state)
            $env:CODEX_HOME = $codexHome

            $out = & $EditScript --image '[Last Output #2]' --prompt t --name t --dry-run
            if ($LASTEXITCODE -ne 0) { throw "exit code ${LASTEXITCODE}: $out" }
            $images = @(Get-DryRunImages $out)
            if ($images.Count -ne 1) { throw "expected 1 image, got $($images.Count)" }
            if ($images[0] -ne $second.Replace('\', '/')) { throw "expected $second, got $($images[0])" }

            $out = & $EditScript --image-set last-output --prompt t --name t --dry-run
            if (@(Get-DryRunImages $out).Count -ne 2) { throw 'expected 2 images from --image-set last-output' }
        } finally {
            Remove-Item -LiteralPath $codexHome -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Assert-Test 'rollout placeholder fails without thread env' {
        $codexHome = New-TempDir
        try {
            $env:CODEX_HOME = $codexHome
            $err = & $EditScript --image '[Image #1]' --prompt t --name t --dry-run 2>&1
            if ($LASTEXITCODE -eq 0) { throw 'expected [Image #1] to fail without CODEX_THREAD_ID' }
            if (($err | Out-String) -notmatch 'CODEX_THREAD_ID') { throw "unexpected error: $err" }
        } finally {
            Remove-Item -LiteralPath $codexHome -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Assert-Test "local path with '#' and spaces survives the wrapper" {
        $dir = New-TempDir
        try {
            $env:CODEX_HOME = $dir
            $img = Join-Path $dir 'my img#2.png'
            Write-MinimalPng -Path $img
            $out = & $EditScript --image $img --prompt 'say "hi" #1' --name t --dry-run
            if ($LASTEXITCODE -ne 0) { throw "exit code ${LASTEXITCODE}: $out" }
            $json = ($out | Out-String).Trim() | ConvertFrom-Json
            if (@($json.multipart.'image[]')[0] -ne $img.Replace('\', '/')) { throw "path mangled: $(@($json.multipart.'image[]')[0])" }
            if (-not $json.multipart.prompt.StartsWith('say "hi" #1')) { throw "prompt mangled: $($json.multipart.prompt)" }
        } finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
} finally {
    $env:CODEX_HOME = $savedCodexHome
}

if ($failures -gt 0) {
    Write-Error "$failures/$total thread state tests failed."
    exit 1
}

Write-Host ""
Write-Host "All $total thread state tests passed." -ForegroundColor Green
