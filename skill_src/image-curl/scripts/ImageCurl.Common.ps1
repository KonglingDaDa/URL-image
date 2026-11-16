# image-curl: shared PowerShell helpers for the thin entry scripts.
# All behaviour lives in lib/image_curl.py. Arguments travel as a UTF-8 JSON file
# (--argv-file) so Windows PowerShell 5.1 cannot mangle quotes, spaces or '#'.

function Get-ImageCurlPython {
    $candidates = @(
        @{ Exe = 'py'; Prefix = @('-3') },
        @{ Exe = 'python3'; Prefix = @() },
        @{ Exe = 'python'; Prefix = @() }
    )
    foreach ($candidate in $candidates) {
        if (-not (Get-Command $candidate.Exe -ErrorAction SilentlyContinue)) { continue }
        # Skips the Microsoft Store "python" stub, which exists but cannot run code.
        $probe = @($candidate.Prefix + @('-c', 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)'))
        try {
            & $candidate.Exe @probe 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { return $candidate }
        } catch {
            continue
        }
    }
    [Console]::Error.WriteLine('错误：未找到 Python 3.8+。请安装 Python 3（python.org 或 Microsoft Store），并确保 py -3、python3 或 python 可用。')
    exit 1
}

# Runs the core; its stdout/stderr flow straight to the caller. Read $LASTEXITCODE afterwards.
function Invoke-ImageCurlCore {
    param(
        [string]$Command,
        [object[]]$Arguments
    )
    # Windows PowerShell 5.1 turns redirected native stderr into terminating errors under 'Stop'.
    $ErrorActionPreference = 'Continue'
    $python = Get-ImageCurlPython
    $core = Join-Path (Join-Path $PSScriptRoot 'lib') 'image_curl.py'
    $argv = @()
    if ($Command) { $argv += $Command }
    foreach ($item in @($Arguments)) {
        if ($null -ne $item) { $argv += [string]$item }
    }
    $argvFile = [System.IO.Path]::GetTempFileName()
    try {
        $json = ConvertTo-Json -InputObject ([string[]]$argv) -Compress
        if (-not $json -or $json -eq 'null') { $json = '[]' }
        [System.IO.File]::WriteAllText($argvFile, $json, (New-Object System.Text.UTF8Encoding($false)))
        $env:PYTHONIOENCODING = 'utf-8'
        $env:PYTHONUTF8 = '1'
        try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
        & $python.Exe @($python.Prefix + @($core, '--argv-file', $argvFile))
    } finally {
        Remove-Item -LiteralPath $argvFile -ErrorAction SilentlyContinue
    }
}
