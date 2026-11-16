#requires -Version 5.1
# Thin wrapper: see lib/image_curl.py (generate).
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/ImageCurl.Common.ps1"
Invoke-ImageCurlCore -Command 'generate' -Arguments $args
exit $LASTEXITCODE
