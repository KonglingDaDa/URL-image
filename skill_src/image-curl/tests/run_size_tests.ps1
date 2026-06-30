#requires -Version 5.1
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SkillRoot = Split-Path -Parent $ScriptDir
$CommonPath = Join-Path $SkillRoot 'scripts/ImageCurl.Common.ps1'
$FixturesPath = Join-Path $ScriptDir 'size_fixtures.json'

if (-not (Test-Path -LiteralPath $CommonPath)) {
    Write-Error "错误：未找到 $CommonPath"
    exit 1
}
if (-not (Test-Path -LiteralPath $FixturesPath)) {
    Write-Error "错误：未找到 $FixturesPath"
    exit 1
}

. $CommonPath

$fixtures = Get-Content -LiteralPath $FixturesPath -Raw -Encoding UTF8 | ConvertFrom-Json
$failures = 0
$total = 0

foreach ($case in $fixtures) {
    $total++
    $actual = Resolve-ImageSize -Spec $case.input
    $actualNote = if ($null -eq $actual.SizeNote) { '' } else { $actual.SizeNote }
    $expectedNote = if ($null -eq $case.size_note) { '' } else { $case.size_note }

    $ok = ($actual.ApiSize -eq $case.api_size) -and
          ($actualNote -eq $expectedNote) -and
          ($actual.IsExplicitDimension -eq $case.is_explicit_dimension)

    if (-not $ok) {
        $failures++
        Write-Host "FAIL $($case.input)" -ForegroundColor Red
        Write-Host "  expected api_size=$($case.api_size) size_note=$expectedNote is_explicit=$($case.is_explicit_dimension)"
        Write-Host "  actual   api_size=$($actual.ApiSize) size_note=$actualNote is_explicit=$($actual.IsExplicitDimension)"
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