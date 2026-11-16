#requires -Version 5.1
# Thin wrapper: see lib/image_curl.py (edit).
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/ImageCurl.Common.ps1"
Invoke-ImageCurlCore -Command 'edit' -Arguments $args
exit $LASTEXITCODE
