#requires -Version 5.1
$ErrorActionPreference = 'Stop'

if (-not $env:USERPROFILE -and $env:HOME) {
    $env:USERPROFILE = $env:HOME
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SkillRoot = Split-Path -Parent $ScriptDir
$CommonPath = Join-Path $SkillRoot 'scripts/ImageCurl.Common.ps1'
$AllowedJsonPath = Join-Path $SkillRoot 'scripts/lib/allowed_sizes.json'
$GenerateScript = Join-Path $SkillRoot 'scripts/generate_image.ps1'

foreach ($path in @($CommonPath, $AllowedJsonPath, $GenerateScript)) {
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Error "错误：未找到 $path"
        exit 1
    }
}

# Resolves --size through the real entry script (dry-run) and returns the payload size.
function Resolve-ImageSize {
    param([string]$Spec)
    $generate = Join-Path $SkillRoot 'scripts/generate_image.ps1'
    $target = Join-Path ([System.IO.Path]::GetTempPath()) ("size-" + [guid]::NewGuid().ToString('N') + '.png')
    $out = & $generate --dry-run --prompt t --size $Spec --output $target 2>$null
    if ($LASTEXITCODE -ne 0) { throw "dry-run rejected size $Spec" }
    $json = ($out | Out-String).Trim() | ConvertFrom-Json
    return [pscustomobject]@{ ApiSize = $json.payload.size; SizeNote = $json.size_note }
}

$catalog = Get-Content -LiteralPath $AllowedJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
$failures = 0

function Test-GenerateDryRun {
    param([string]$Size)

    try {
        & $GenerateScript --dry-run --prompt t --size $Size --name t *> $null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

foreach ($item in $catalog.allowed) {
    if (Test-GenerateDryRun -Size $item.input) {
        Write-Host "OK   allowed: $($item.input)" -ForegroundColor Green
    } else {
        Write-Host "FAIL allowed rejected: $($item.input)" -ForegroundColor Red
        $failures++
    }
}

foreach ($item in $catalog.forbidden) {
    if (Test-GenerateDryRun -Size $item.input) {
        Write-Host "FAIL forbidden accepted: $($item.input)" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "OK   forbidden: $($item.input)" -ForegroundColor Green
    }
}

# Generic forbidden case not listed in catalog (non-allowlisted WxH).
$forbiddenExtra = '1344x768'
if (Test-GenerateDryRun -Size $forbiddenExtra) {
    Write-Host "FAIL forbidden accepted: $forbiddenExtra" -ForegroundColor Red
    $failures++
} else {
    Write-Host "OK   forbidden: $forbiddenExtra" -ForegroundColor Green
}

foreach ($item in $catalog.allowed) {
    try {
        $resolved = Resolve-ImageSize -Spec $item.input
        if ($resolved.ApiSize -ne $item.api_size) {
            Write-Host ("FAIL catalog normalize mismatch: {0} expected={1} actual={2}" -f $item.input, $item.api_size, $resolved.ApiSize) -ForegroundColor Red
            $failures++
        } else {
            Write-Host "OK   catalog normalize: $($item.input) -> $($resolved.ApiSize)" -ForegroundColor Green
        }
    } catch {
        Write-Host ("FAIL catalog normalize rejected: {0}" -f $item.input) -ForegroundColor Red
        $failures++
    }
}

if ($failures -gt 0) {
    Write-Host ""
    Write-Error "$failures allowed-size tests failed."
    exit 1
}

Write-Host ""
Write-Host 'All allowed-size tests passed.' -ForegroundColor Green