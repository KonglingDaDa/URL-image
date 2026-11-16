#requires -Version 5.1
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SkillRoot = Split-Path -Parent $ScriptDir
$AllowedJsonPath = Join-Path $SkillRoot 'scripts/lib/allowed_sizes.json'
$NormalizePy = Join-Path $SkillRoot 'scripts/lib/normalize_size.py'
$CommonPath = Join-Path $SkillRoot 'scripts/ImageCurl.Common.ps1'

foreach ($path in @($CommonPath, $AllowedJsonPath, $NormalizePy)) {
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Error "错误：未找到 $path"
        exit 1
    }
}

. $CommonPath

$python = Get-ImageCurlPython
$catalog = Get-Content -LiteralPath $AllowedJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
$failures = 0

function Invoke-NormalizeSize {
    param([string[]]$Arguments)

    $stderrFile = [System.IO.Path]::GetTempFileName()
    try {
        $stdout = & $python.Exe @($python.Prefix + $NormalizePy + $Arguments) 2>$stderrFile
        return @{
            ExitCode = $LASTEXITCODE
            Stdout   = ($stdout | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
        }
    } finally {
        if (Test-Path -LiteralPath $stderrFile) {
            Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
        }
    }
}

$seenApiSizes = @{}
foreach ($item in $catalog.allowed) {
    if ($seenApiSizes.ContainsKey($item.api_size)) {
        continue
    }
    $seenApiSizes[$item.api_size] = $true

    $result = Invoke-NormalizeSize -Arguments @('--validate-api-size', $item.api_size)
    if ($result.ExitCode -ne 0) {
        Write-Host "FAIL api_size invalid: $($item.api_size)"
        $failures++
    } else {
        Write-Host "OK   api_size valid: $($item.api_size)"
    }
}

foreach ($item in $catalog.allowed) {
    $result = Invoke-NormalizeSize -Arguments @($item.input)
    if ($result.ExitCode -ne 0) {
        Write-Host "FAIL normalize mismatch: $($item.input) expected=$($item.api_size) actual=<failed>"
        $failures++
        continue
    }

    try {
        $parsed = $result.Stdout | ConvertFrom-Json
        $actualApi = $parsed.api_size
    } catch {
        Write-Host "FAIL normalize mismatch: $($item.input) expected=$($item.api_size) actual=<invalid json>"
        $failures++
        continue
    }

    if ($actualApi -ne $item.api_size) {
        Write-Host "FAIL normalize mismatch: $($item.input) expected=$($item.api_size) actual=$actualApi"
        $failures++
    } else {
        Write-Host "OK   normalize: $($item.input) -> $actualApi"
    }
}

foreach ($item in $catalog.forbidden) {
    $result = Invoke-NormalizeSize -Arguments @($item.input)
    if ($result.ExitCode -eq 0) {
        Write-Host "FAIL forbidden accepted: $($item.input)"
        $failures++
    } else {
        Write-Host "OK   forbidden rejected: $($item.input)"
    }
}

if ($failures -gt 0) {
    Write-Host ''
    Write-Error "$failures catalog consistency tests failed."
    exit 1
}

Write-Host ''
Write-Host 'All catalog consistency tests passed.'