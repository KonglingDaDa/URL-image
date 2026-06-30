#requires -Version 5.1
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/ImageCurl.Common.ps1"

$SkillDir = Split-Path -Parent $PSScriptRoot
Import-ImageCurlLocalEnv -SkillDir $SkillDir

function Show-EditUsage {
    @'
用法：
  edit_image.ps1 --image 文件 --prompt 文本 (--output 文件 | --output-dir 目录 [--name 前缀]) [选项]
  edit_image.ps1 --image 文件 --prompt-file 文件 (--output 文件 | --output-dir 目录 [--name 前缀]) [选项]

选项：
  --output FILE         输出文件路径（优先于 --output-dir/--name）
  --output-dir DIR      输出目录；与 --name 组合生成「前缀-随机后缀」文件名
  --name PREFIX         可读文件名前缀，默认 generated；未指定 --output-dir 时写入
                        ${CODEX_HOME:-~/.codex}/generated_images/<thread|manual>/
  --image FILE          输入图片或占位符（[Image #N]、[Last Output] 等），可重复
  --image-set SELECTOR  图片集选择器，可重复：active、last-output、latest-turn、
                        turn:-K、thread:1,2,5（edit 不隐式继承线程状态，须显式指定）
  --model NAME          图片模型，默认：gpt-image-2
  --size SIZE           auto、宽x高、宽:高 或 tier 简写（如 16:9、9:16@1k、2k、4k）
                        解析后须满足：边长为 16 的倍数，最长边 <=3840，宽高比 <=3:1
  --quality VALUE       默认：auto
  --format FORMAT       png、jpeg 或 webp，默认：png
  --output-compression N
                        jpeg/webp 输出压缩级别，0-100
  --moderation VALUE    默认：auto
  --mask FILE           可选 PNG 蒙版，透明区域为待编辑区域
  --input-fidelity VALUE
                        输入保真度：low 或 high
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

if ($argsObj.images.Count -eq 0 -and $argsObj.image_sets.Count -eq 0) {
    Write-ImageCurlError '至少需要 --image 或 --image-set 之一。'
}
if (-not $argsObj.output -and -not $argsObj.output_dir -and -not $argsObj.name) {
    Write-ImageCurlError '必须提供 --output、--output-dir 或 --name 至少其一。'
}
if (-not $argsObj.model) { Write-ImageCurlError '--model 不能为空。' }
if (-not $argsObj.size) { Write-ImageCurlError '--size 不能为空。' }
if (-not $argsObj.format) { Write-ImageCurlError '--format 不能为空。' }

$requestedSize = $argsObj.size
$resolvedSize = Resolve-ImageSize -Spec $requestedSize
$size = $resolvedSize.ApiSize.ToLowerInvariant()
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
Test-InputFidelity -Value $argsObj.input_fidelity

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
$prompt = Add-PromptSizeConstraint -Prompt $prompt -RawSpec $requestedSize -ApiSize $size

$threadId = Get-ImageCurlThreadId
$resolvedImages = [string[]]@(Resolve-ImageRefs -ThreadId $threadId -ImageSets @($argsObj.image_sets) -Images @($argsObj.images))
if ($resolvedImages.Count -eq 0) {
    Write-ImageCurlError '未能解析任何输入图片。'
}

$resolvedMask = ''
if ($argsObj.mask) {
    if (-not (Test-Path -LiteralPath $argsObj.mask)) { Write-ImageCurlError "未找到蒙版文件：$($argsObj.mask)" }
    if ((Get-Item -LiteralPath $argsObj.mask).Length -eq 0) { Write-ImageCurlError "蒙版文件为空：$($argsObj.mask)" }
    $resolvedMask = Resolve-FullPath $argsObj.mask
}

$output = Resolve-OutputPath -Output $argsObj.output -OutputDir $argsObj.output_dir -Name $argsObj.name -Format $format
$output = Resolve-FullPath $output
$outputDir = Split-Path -Parent $output
if ($outputDir -and -not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$count = [int]$argsObj.count
$targets = [string[]]@(Get-OutputTargets -OutputPath $output -Format $format -Count $count)
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
if (-not $argsObj.dry_run -and -not $config.ApiKey) {
    Write-ImageCurlError "未找到 API Key。请在 $SkillDir/local.env 中设置 IMAGE_CURL_API_KEY，或传入 --api-key。"
}

$endpoint = Get-ImageEndpoint -BaseUrl $config.BaseUrl -Kind 'edits'

if ($argsObj.dry_run) {
    Save-ThreadState -ThreadId $threadId -ActiveInput $resolvedImages
    $dryRun = [ordered]@{
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
            mask            = if ($resolvedMask) { $resolvedMask } else { $null }
            input_fidelity  = if ($argsObj.input_fidelity) { $argsObj.input_fidelity } else { $null }
        }
        output        = $output
        count         = $count
        metadata      = if ($metadata) { $metadata } else { $null }
    }
    if ($resolvedSize.SizeNote) {
        $dryRun['size_note'] = $resolvedSize.SizeNote
    }
    [pscustomobject]$dryRun | ConvertTo-ImageCurlJson -Depth 10
    exit 0
}

$tempFile = [System.IO.Path]::GetTempFileName()
$promptTmp = [System.IO.Path]::GetTempFileName()
try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($promptTmp, $prompt, $utf8NoBom)
    $curlArgs = @(
        '-sS', '--fail-with-body', '-X', 'POST', $endpoint,
        '-H', "Authorization: Bearer $($config.ApiKey)",
        '-H', 'Cache-Control: no-store, no-cache, max-age=0',
        '-H', 'Pragma: no-cache',
        '--max-time', $argsObj.timeout,
        '--form-string', "model=$($argsObj.model)",
        '-F', "prompt=<$promptTmp",
        '--form-string', "size=$size",
        '--form-string', "quality=$($argsObj.quality)",
        '--form-string', "output_format=$format",
        '--form-string', "moderation=$($argsObj.moderation)",
        '--form-string', "n=$count"
    )
    if ($argsObj.output_compression) {
        $curlArgs += @('--form-string', "output_compression=$($argsObj.output_compression)")
    }
    if ($argsObj.input_fidelity) {
        $curlArgs += @('--form-string', "input_fidelity=$($argsObj.input_fidelity)")
    }
    foreach ($image in $resolvedImages) {
        $curlArgs += @('-F', "image[]=@$(Get-CurlFilePath $image)")
    }
    if ($resolvedMask) {
        $curlArgs += @('-F', "mask=@$(Get-CurlFilePath $resolvedMask)")
    }
    $curlArgs += @('-o', $tempFile)

    & curl.exe @curlArgs
    if ($LASTEXITCODE -ne 0) {
        $errorBody = if (Test-Path -LiteralPath $tempFile) { Get-Content -LiteralPath $tempFile -Raw } else { '' }
        Write-ImageCurlError "curl 请求失败（退出码 $LASTEXITCODE）。$errorBody"
    }
    $responseJson = Get-Content -LiteralPath $tempFile -Raw -Encoding UTF8
    $result = Save-ImageCurlResponse -ResponseJson $responseJson -OutputPath $output -MetadataPath $metadata -Format $format -RequestedCount $count
    $savedPaths = [string[]]@(Get-SavedPathsFromResult -Result $result)
    if ($savedPaths.Count -gt 0) {
        Save-ThreadState -ThreadId $threadId -ActiveInput $resolvedImages -LastOutput $savedPaths
    } else {
        Save-ThreadState -ThreadId $threadId -ActiveInput $resolvedImages
    }
    ConvertTo-ImageCurlJson -InputObject $result -Depth 10 -Compress
} finally {
    if (Test-Path -LiteralPath $tempFile) {
        Remove-Item -LiteralPath $tempFile -Force
    }
    if (Test-Path -LiteralPath $promptTmp) {
        Remove-Item -LiteralPath $promptTmp -Force
    }
}