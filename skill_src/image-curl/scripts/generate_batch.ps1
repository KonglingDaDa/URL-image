#requires -Version 5.1
# Thin wrapper: see lib/image_curl.py (generate-batch).
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/ImageCurl.Common.ps1"
Invoke-ImageCurlCore -Command 'generate-batch' -Arguments $args
exit $LASTEXITCODE
