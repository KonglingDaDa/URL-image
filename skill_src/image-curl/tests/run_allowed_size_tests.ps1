#requires -Version 5.1
$ErrorActionPreference = 'Stop'

if (-not $env:USERPROFILE -and $env:HOME) {
    $env:USERPROFILE = $env:HOME
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SkillRoot = Split-Path -Parent $ScriptDir
$CommonPath = Join-Path $SkillRoot 'scripts/ImageCurl.Common.ps1'
$AllowedJsonPath = Join-Path $SkillRoot 'scripts/lib/allowed_sizes.json'
$FixturesPath = Join-Path $ScriptDir 'size_fixtures.json'
$NormalizePy = Join-Path $SkillRoot 'scripts/lib/normalize_size.py'

foreach ($path in @($CommonPath, $AllowedJsonPath, $FixturesPath, $NormalizePy)) {
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Error "错误：未找到 $path"
        exit 1
    }
}

. $CommonPath

$catalog = Get-Content -LiteralPath $AllowedJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
$fixtures = Get-Content -LiteralPath $FixturesPath -Raw -Encoding UTF8 | ConvertFrom-Json
$failures = 0
$python = Get-ThreadStatePython

function Test-NormalizeSizeRejected {
    param([string]$Size)

    $stderrFile = [System.IO.Path]::GetTempFileName()
    try {
        & $python.Exe @($python.Prefix + $NormalizePy, $Size) 2>$stderrFile | Out-Null
        return ($LASTEXITCODE -ne 0)
    } finally {
        if (Test-Path -LiteralPath $stderrFile) {
            Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
        }
    }
}

foreach ($item in $catalog.allowed) {
    try {
        $null = Resolve-ImageSize -Spec $item.input
        Write-Host "OK   allowed: $($item.input)" -ForegroundColor Green
    } catch {
        Write-Host "FAIL allowed rejected: $($item.input)" -ForegroundColor Red
        $failures++
    }
}

foreach ($item in $catalog.forbidden) {
    if (Test-NormalizeSizeRejected -Size $item.input) {
        Write-Host "OK   forbidden: $($item.input)" -ForegroundColor Green
    } else {
        Write-Host "FAIL forbidden accepted: $($item.input)" -ForegroundColor Red
        $failures++
    }
}

# Generic forbidden case not listed in catalog (non-allowlisted WxH).
$forbiddenExtra = '1344x768'
if (Test-NormalizeSizeRejected -Size $forbiddenExtra) {
    Write-Host "OK   forbidden: $forbiddenExtra" -ForegroundColor Green
} else {
    Write-Host "FAIL forbidden accepted: $forbiddenExtra" -ForegroundColor Red
    $failures++
}

$catalogInputs = @($catalog.allowed | ForEach-Object { $_.input })
$fixtureInputs = @($fixtures | ForEach-Object { $_.input })
$missing = @($catalogInputs | Where-Object { $_ -notin $fixtureInputs })
if ($missing.Count -gt 0) {
    Write-Host ("FAIL allowed_sizes.json 白名单条目未出现在 size_fixtures.json：{0}" -f ($missing -join ', ')) -ForegroundColor Red
    $failures++
}

if ($failures -gt 0) {
    Write-Host ""
    Write-Error "$failures allowed-size tests failed."
    exit 1
}

Write-Host ""
Write-Host 'All allowed-size tests passed.' -ForegroundColor Green