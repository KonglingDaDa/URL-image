#requires -Version 5.1
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/ImageCurl.Common.ps1"

$SkillDir = Split-Path -Parent $PSScriptRoot
Import-ImageCurlLocalEnv -SkillDir $SkillDir

function Show-EditUsage {
    @'
用法：
  edit_image.ps1 --image 文件 --prompt 文本 --output 文件 [选项]
  edit_image.ps1 --image 文件 --prompt-file 文件 --output 文件 [选项]

选项：
  --image FILE          输入图片，可重复传入多张
  --model NAME          图片模型，默认：gpt-image-2
  --size SIZE           auto 或 宽x高；边长须为 16 的倍数，最长边 <=3840，宽高比 <=3:1
  --quality VALUE       默认：auto
  --format FORMAT       png、jpeg 或 webp，默认：png
  --output-compression N
                        jpeg/webp 输出压缩级别，0-100
  --moderation VALUE    默认：auto
  --count N, --n N      单次 API 请求生成的图片数量，默认 1，最大 10
  --metadata FILE       保存响应 metadata，省略 b64_json
  --base-url URL        覆盖默认 base URL，默认：https://aicode.cat
  --api-key KEY         临时覆盖 API Key；常规请写入 skill 目录 local.env
  --timeout SECONDS     curl 超时时间，默认 300
  --overwrite           允许覆盖已有输出文件
  --dry-run             dry-run 模式，打印脱敏后的请求信息，不调用接口
  -h, --help            显示此帮助
'@ | Write-Output
}

$argsObj = Parse-ImageCurlArgs -ArgList $args
if ($argsObj.help) {
    Show-EditUsage
    exit 0
}

if ($argsObj.images.Count -eq 0) { Write-ImageCurlError '至少需要一个 --image 参数。' }
if (-not $argsObj.output) { Write-ImageCurlError '必须提供 --output。' }
if (-not $argsObj.model) { Write-ImageCurlError '--model 不能为空。' }
if (-not $argsObj.size) { Write-ImageCurlError '--size 不能为空。' }
if (-not $argsObj.format) { Write-ImageCurlError '--format 不能为空。' }

$size = $argsObj.size.ToLowerInvariant()
Test-ImageSize -Size $size

$format = $argsObj.format.ToLowerInvariant()
if ($format -eq 'jpg') { $format = 'jpeg' }
if ($format -notin @('png', 'jpeg', 'webp')) {
    Write-ImageCurlError '--format 须为 png、jpeg、jpg 或 webp。'
}

if ($argsObj.output_compression) {
    if ($argsObj.output_compression -notmatch '^\d+$' -or [int]$argsObj.output_compression -lt 0 -or [int]$argsObj.output_compression -gt 100) {
        Write-ImageCurlError '--output-compression 须为 0 至 100 之间的整数。'
    }
    if ($format -notin @('jpeg', 'webp')) {
        Write-ImageCurlError '--output-compression 仅适用于 jpeg 或 webp 输出。'
    }
}

if ($argsObj.timeout -notmatch '^\d+$' -or [int]$argsObj.timeout -le 0) {
    Write-ImageCurlError '--timeout 须为正整数。'
}
if ($argsObj.count -notmatch '^\d+$' -or [int]$argsObj.count -lt 1 -or [int]$argsObj.count -gt 10) {
    Write-ImageCurlError '--count/--n 须为 1 至 10 之间的整数。'
}

if ($argsObj.prompt -and $argsObj.prompt_file) {
    Write-ImageCurlError '请只提供 --prompt 或 --prompt-file 其中之一，不可同时使用。'
}

$prompt = $argsObj.prompt
if ($argsObj.prompt_file) {
    if (-not (Test-Path -LiteralPath $argsObj.prompt_file)) {
        Write-ImageCurlError "未找到提示词文件：$($argsObj.prompt_file)"
    }
    $prompt = Get-Content -LiteralPath $argsObj.prompt_file -Raw -Encoding UTF8
}
$prompt = $prompt.Trim()
if (-not $prompt) { Write-ImageCurlError '必须提供 --prompt 或 --prompt-file。' }

$resolvedImages = @()
foreach ($image in $argsObj.images) {
    if (-not $image) { Write-ImageCurlError '--image 不能为空。' }
    if (-not (Test-Path -LiteralPath $image)) { Write-ImageCurlError "未找到图片文件：$image" }
    if ((Get-Item -LiteralPath $image).Length -eq 0) { Write-ImageCurlError "图片文件为空：$image" }
    $resolvedImages += (Resolve-FullPath $image)
}

$output = Resolve-FullPath $argsObj.output
$outputDir = Split-Path -Parent $output
if ($outputDir -and -not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$count = [int]$argsObj.count
$targets = Get-OutputTargets -OutputPath $output -Format $format -Count $count
Assert-OutputTargetsAvailable -Targets $targets -Overwrite $argsObj.overwrite

$metadata = ''
if ($argsObj.metadata) {
    $metadata = Resolve-FullPath $argsObj.metadata
    $metaDir = Split-Path -Parent $metadata
    if ($metaDir -and -not (Test-Path -LiteralPath $metaDir)) {
        New-Item -ItemType Directory -Path $metaDir -Force | Out-Null
    }
}

$config = Get-ImageCurlConfig -OverrideBaseUrl $argsObj.base_url -OverrideApiKey $argsObj.api_key
if (-not $config.BaseUrl) {
    Write-ImageCurlError '无法解析 base URL，请传入 --base-url 或设置 IMAGE_CURL_BASE_URL。'
}
if (-not $config.ApiKey) {
    Write-ImageCurlError "未找到 API Key。请在 $SkillDir/local.env 中设置 IMAGE_CURL_API_KEY，或传入 --api-key。"
}

$endpoint = Get-ImageEndpoint -BaseUrl $config.BaseUrl -Kind 'edits'

if ($argsObj.dry_run) {
    [pscustomobject]@{
        endpoint      = $endpoint
        authorization = 'Bearer ***'
        multipart     = [pscustomobject]@{
            model           = $argsObj.model
            prompt          = $prompt
            size            = $size
            quality         = $argsObj.quality
            output_format   = $format
            moderation      = $argsObj.moderation
            n               = $count
            'image[]'       = $resolvedImages
            output_compression = if ($argsObj.output_compression) { [int]$argsObj.output_compression } else { $null }
        }
        output        = $output
        count         = $count
        metadata      = if ($metadata) { $metadata } else { $null }
    } | ConvertTo-Json -Depth 10
    exit 0
}

$tempFile = [System.IO.Path]::GetTempFileName()
try {
    $curlArgs = @(
        '-sS', '--fail-with-body', '-X', 'POST', $endpoint,
        '-H', "Authorization: Bearer $($config.ApiKey)",
        '-H', 'Cache-Control: no-store, no-cache, max-age=0',
        '-H', 'Pragma: no-cache',
        '--max-time', $argsObj.timeout,
        '--form-string', "model=$($argsObj.model)",
        '--form-string', "prompt=$prompt",
        '--form-string', "size=$size",
        '--form-string', "quality=$($argsObj.quality)",
        '--form-string', "output_format=$format",
        '--form-string', "moderation=$($argsObj.moderation)",
        '--form-string', "n=$count"
    )
    if ($argsObj.output_compression) {
        $curlArgs += @('--form-string', "output_compression=$($argsObj.output_compression)")
    }
    foreach ($image in $resolvedImages) {
        $curlArgs += @('-F', "image[]=@$image")
    }
    $curlArgs += @('-o', $tempFile)

    & curl.exe @curlArgs
    if ($LASTEXITCODE -ne 0) {
        $errorBody = if (Test-Path -LiteralPath $tempFile) { Get-Content -LiteralPath $tempFile -Raw } else { '' }
        Write-ImageCurlError "curl 请求失败（退出码 $LASTEXITCODE）。$errorBody"
    }
    $responseJson = Get-Content -LiteralPath $tempFile -Raw -Encoding UTF8
    $result = Save-ImageCurlResponse -ResponseJson $responseJson -OutputPath $output -MetadataPath $metadata -Format $format -RequestedCount $count
    $result | ConvertTo-Json -Depth 10 -Compress
} finally {
    if (Test-Path -LiteralPath $tempFile) {
        Remove-Item -LiteralPath $tempFile -Force
    }
}