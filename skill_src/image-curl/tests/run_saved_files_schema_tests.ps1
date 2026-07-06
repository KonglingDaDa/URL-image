#requires -Version 5.1
# saved_files / saved_file result JSON uses canonical "file" field (Bash + PS parity).
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SkillRoot = Split-Path -Parent $ScriptDir
$CommonPath = Join-Path $SkillRoot 'scripts/ImageCurl.Common.ps1'
. $CommonPath

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

Assert-Test 'Get-SavedPathsFromResult reads file field' {
    $result = [pscustomobject]@{
        saved_files = @(
            [pscustomobject]@{ file = 'C:/tmp/a.png'; bytes = 1 }
            [pscustomobject]@{ file = 'C:/tmp/b.png'; bytes = 2 }
        )
    }
    $paths = @(Get-SavedPathsFromResult -Result $result)
    if ($paths.Count -ne 2 -or $paths[0] -ne 'C:/tmp/a.png') {
        throw "unexpected paths: $($paths -join ', ')"
    }
}

Assert-Test 'Get-SavedPathsFromResult accepts legacy path field' {
    $result = [pscustomobject]@{
        saved_files = @(
            [pscustomobject]@{ path = 'C:/tmp/legacy.png'; bytes = 1 }
        )
    }
    $paths = @(Get-SavedPathsFromResult -Result $result)
    if ($paths.Count -ne 1 -or $paths[0] -ne 'C:/tmp/legacy.png') {
        throw "unexpected paths: $($paths -join ', ')"
    }
}

Assert-Test 'Save-ImageCurlResponse emits file field not path' {
    $png = [Convert]::FromBase64String(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='
    )
    $response = @{
        data = @(@{ b64_json = [Convert]::ToBase64String($png) })
    } | ConvertTo-Json -Depth 5 -Compress
    $responseFile = Join-Path $env:TEMP ("schema-resp-$([guid]::NewGuid().ToString('N')).json")
    $outputFile = Join-Path $env:TEMP ("schema-out-$([guid]::NewGuid().ToString('N')).png")
    Set-Content -LiteralPath $responseFile -Value $response -Encoding UTF8 -NoNewline
    try {
        $result = Save-ImageCurlResponse -ResponseFile $responseFile -OutputPath $outputFile -Format 'png' -RequestedCount 1
        if (-not $result.PSObject.Properties['saved_file']) {
            throw 'missing saved_file'
        }
        if ($result.PSObject.Properties['path']) {
            throw 'unexpected top-level path property'
        }
    } finally {
        Remove-Item -LiteralPath $responseFile, $outputFile -Force -ErrorAction SilentlyContinue
    }
}

if ($failures -gt 0) {
    Write-Error "$failures/$total saved_files schema tests failed."
    exit 1
}

Write-Host ""
Write-Host "All $total saved_files schema tests passed." -ForegroundColor Green