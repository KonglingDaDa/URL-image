#requires -Version 5.1
# Unified entry: generate | edit | generate-batch | models | help (see lib/image_curl.py).
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/ImageCurl.Common.ps1"
Invoke-ImageCurlCore -Command '' -Arguments $args
exit $LASTEXITCODE
