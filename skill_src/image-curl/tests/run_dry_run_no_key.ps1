#requires -Version 5.1
# generate/edit --dry-run should work without API Key (install self-check).
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SkillRoot = Split-Path -Parent $ScriptDir
$GenerateScript = Join-Path $SkillRoot 'scripts/generate_image.ps1'
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
    Assert-Test 'generate_image.ps1 --dry-run without API key' {
        $out = & $GenerateScript --dry-run --prompt 'install check' --name dry-no-key 2>&1
        if ($LASTEXITCODE -ne 0) { throw "exit code ${LASTEXITCODE}: $out" }
        $json = ($out | Out-String).Trim() | ConvertFrom-Json
        if (-not $json.endpoint) { throw 'missing endpoint in dry-run JSON' }
    }

    Assert-Test 'edit_image.ps1 --dry-run without API key' {
        $img = Join-Path $env:TEMP ("dry-no-key-$([guid]::NewGuid().ToString('N')).png")
        $bytes = [Convert]::FromBase64String(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='
        )
        [IO.File]::WriteAllBytes($img, $bytes)
        try {
            $out = & $EditScript --image $img --prompt 'install check' --name dry-no-key --dry-run 2>&1
            if ($LASTEXITCODE -ne 0) { throw "exit code ${LASTEXITCODE}: $out" }
            $json = ($out | Out-String).Trim() | ConvertFrom-Json
            if (-not $json.endpoint) { throw 'missing endpoint in dry-run JSON' }
        } finally {
            Remove-Item -LiteralPath $img -Force -ErrorAction SilentlyContinue
        }
    }
} finally {
    if ($savedKey) { $env:IMAGE_CURL_API_KEY = $savedKey }
}

if ($failures -gt 0) {
    Write-Error "$failures/$total dry-run no-key tests failed."
    exit 1
}

Write-Host ""
Write-Host "All $total dry-run no-key tests passed." -ForegroundColor Green