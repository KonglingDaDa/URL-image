#requires -Version 5.1
# Acceptance helper: edit_image.ps1 --image-set last-output --dry-run with fixture CODEX_HOME
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SkillRoot = Split-Path -Parent $ScriptDir
$EditScript = Join-Path $SkillRoot 'scripts/edit_image.ps1'

$codexHome = Join-Path $env:TEMP ("image-curl-edit-dry-" + [guid]::NewGuid().ToString('N'))
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

$out = & $EditScript --image-set last-output --prompt test --name dry-test --api-key dry-run-test-key --dry-run
$json = ($out | Out-String).Trim() | ConvertFrom-Json
$images = @($json.multipart.'image[]')
if ($images.Count -ne 1) {
    Write-Error "expected 1 resolved image, got $($images.Count)"
}
$expected = $first.Replace('\', '/')
if ($images[0] -ne $expected) {
    Write-Error "path mismatch: $($images[0]) vs $expected"
}
Write-Host "OK edit_image.ps1 dry-run resolved $($images[0])" -ForegroundColor Green
Remove-Item -LiteralPath $codexHome -Recurse -Force -ErrorAction SilentlyContinue