#requires -Version 5.1
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SkillRoot = Split-Path -Parent $ScriptDir
$CommonPath = Join-Path $SkillRoot 'scripts/ImageCurl.Common.ps1'
$AllowedJsonPath = Join-Path $SkillRoot 'scripts/lib/allowed_sizes.json'

if (-not (Test-Path -LiteralPath $CommonPath)) {
    Write-Error "错误：未找到 $CommonPath"
    exit 1
}
if (-not (Test-Path -LiteralPath $AllowedJsonPath)) {
    Write-Error "错误：未找到 $AllowedJsonPath"
    exit 1
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
$total = 0

foreach ($case in $catalog.allowed) {
    $total++
    $actual = Resolve-ImageSize -Spec $case.input
    $actualNote = if ($null -eq $actual.SizeNote) { '' } else { $actual.SizeNote }

    if ($actual.ApiSize -ne $case.api_size) {
        $failures++
        Write-Host "FAIL $($case.input)" -ForegroundColor Red
        Write-Host "  expected api_size=$($case.api_size)"
        Write-Host "  actual   api_size=$($actual.ApiSize) size_note=$actualNote"
    } else {
        Write-Host "OK   $($case.input) -> $($actual.ApiSize)" -ForegroundColor Green
    }
}

if ($failures -gt 0) {
    Write-Host ""
    Write-Error "$failures/$total size normalization tests failed."
    exit 1
}

Write-Host ""
Write-Host "All $total size normalization tests passed." -ForegroundColor Green