#requires -Version 5.1
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SkillRoot = Split-Path -Parent $ScriptDir
$ThreadStatePy = Join-Path $SkillRoot 'scripts/lib/thread_state.py'
$CommonPath = Join-Path $SkillRoot 'scripts/ImageCurl.Common.ps1'

if (-not (Test-Path -LiteralPath $ThreadStatePy)) {
    Write-Error "错误：未找到 $ThreadStatePy"
    exit 1
}
. $CommonPath

function New-TempCodexHome {
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

Assert-Test 'resolve [Last Output] from manual fixture' {
    $codexHome = New-TempCodexHome
    try {
        $threadDir = Join-Path (Join-Path $codexHome 'generated_images') 'manual'
        New-Item -ItemType Directory -Path $threadDir -Force | Out-Null
        $first = Join-Path $threadDir 'first-out.png'
        $second = Join-Path $threadDir 'second-out.png'
        Write-MinimalPng -Path $first
        Write-MinimalPng -Path $second
        @{
            thread_id = 'manual'
            images    = @(
                ([System.IO.Path]::GetFullPath($first)),
                ([System.IO.Path]::GetFullPath($second))
            )
        } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $threadDir 'last_output_set.json') -Encoding UTF8

        $env:CODEX_HOME = $codexHome
        Remove-Item Env:CODEX_THREAD_ID -ErrorAction SilentlyContinue
        Remove-Item Env:CODEX_SESSION_ID -ErrorAction SilentlyContinue

        $placeholder = '[Last Output #2]'
        $paths = [string[]]@(Resolve-ImageRefs -ThreadId 'manual' -Images @($placeholder))
        if ($paths.Count -ne 1) { throw "expected 1 path, got $($paths.Count)" }
        $expected = [System.IO.Path]::GetFullPath($second)
        $actual = [System.IO.Path]::GetFullPath($paths[0])
        if ($actual -ne $expected) { throw "expected $expected, got $actual" }

        $all = [string[]]@(Resolve-ImageRefs -ThreadId 'manual' -ImageSets @('last-output'))
        if ($all.Count -ne 2) { throw "expected 2 paths from last-output set, got $($all.Count)" }
    } finally {
        Remove-Item -LiteralPath $codexHome -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Assert-Test 'rollout placeholder fails without thread env' {
    $codexHome = New-TempCodexHome
    try {
        $env:CODEX_HOME = $codexHome
        Remove-Item Env:CODEX_THREAD_ID -ErrorAction SilentlyContinue
        Remove-Item Env:CODEX_SESSION_ID -ErrorAction SilentlyContinue
        try {
            [void](Resolve-ImageRefs -ThreadId 'manual' -Images @('[Image #1]'))
            throw 'expected rollout placeholder to fail for manual thread'
        } catch {
            if ($_.Exception.Message -notmatch 'CODEX_THREAD_ID') {
                throw "unexpected error: $($_.Exception.Message)"
            }
        }
    } finally {
        Remove-Item -LiteralPath $codexHome -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Assert-Test 'Resolve-ImageRefs --image-set last-output returns saved paths' {
    $codexHome = New-TempCodexHome
    try {
        $threadDir = Join-Path (Join-Path $codexHome 'generated_images') 'manual'
        New-Item -ItemType Directory -Path $threadDir -Force | Out-Null
        $first = Join-Path $threadDir 'first-out.png'
        Write-MinimalPng -Path $first
        @{
            thread_id = 'manual'
            images    = @(([System.IO.Path]::GetFullPath($first)))
        } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $threadDir 'last_output_set.json') -Encoding UTF8

        $env:CODEX_HOME = $codexHome
        Remove-Item Env:CODEX_THREAD_ID -ErrorAction SilentlyContinue
        Remove-Item Env:CODEX_SESSION_ID -ErrorAction SilentlyContinue

        $resolved = [string[]]@(Resolve-ImageRefs -ThreadId 'manual' -ImageSets @('last-output'))
        if ($resolved.Count -ne 1) { throw "expected 1 image from last-output set, got $($resolved.Count)" }
        $expected = Normalize-PathForJson ([System.IO.Path]::GetFullPath($first))
        if ($resolved[0] -ne $expected) {
            throw "last-output path mismatch: $($resolved[0]) vs $expected"
        }
    } finally {
        Remove-Item -LiteralPath $codexHome -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failures -gt 0) {
    Write-Host ""
    Write-Error "$failures/$total thread state tests failed."
    exit 1
}

Write-Host ""
Write-Host "All $total thread state tests passed." -ForegroundColor Green