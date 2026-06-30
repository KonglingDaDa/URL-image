#requires -Version 5.1
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/ImageCurl.Common.ps1"

$SkillDir = Split-Path -Parent $PSScriptRoot
Import-ImageCurlLocalEnv -SkillDir $SkillDir

function Show-GenerateBatchUsage {
    @'
用法：
  generate_batch.ps1 --input prompts.jsonl --output-dir 目录 [选项]

选项：
  --input FILE          JSONL 批量任务文件（每行一个字符串 prompt 或 job 对象）
  --output-dir DIR      批量输出目录（必填）
  --concurrency N       并发请求数，默认 4，范围 1–25
  --model NAME          默认图片模型，默认：gpt-image-2
  --size SIZE           默认尺寸，默认：1024x1024
  --quality VALUE       默认质量，默认：auto
  --format FORMAT       默认输出格式 png、jpeg 或 webp，默认：png
  --output-compression N
                        默认 jpeg/webp 压缩级别，0-100
  --moderation VALUE    默认审核级别，默认：auto
  --background VALUE    默认背景值，例如 transparent 或 auto
  --count N, --n N      默认单次请求生成数量，默认 1，最大 10
  --metadata FILE       默认 metadata 输出路径（job 可覆盖）
  --base-url URL        覆盖默认 base URL，默认：https://aicode.cat
  --api-key KEY         临时覆盖 API Key；常规请写入 skill 目录 local.env
  --timeout SECONDS     curl 超时时间，默认 300
  --overwrite           允许覆盖已有输出文件
  --dry-run             按 job 打印脱敏 JSON 预览，不调用接口
  -h, --help            显示此帮助

JSONL 每行示例：
  "画一只猫"
  {"prompt":"夕阳","size":"16:9","n":2,"name":"sunset-01"}
  {"prompt":"海报","out":"./batch-out/custom.png"}
'@ | Write-Output
}

function Invoke-BatchGenerateJobs {
    param(
        [object[]]$Descriptors,
        [string]$ResolvedOutputDir,
        [string]$Endpoint,
        [string]$ApiKey,
        [string]$Timeout,
        [bool]$Overwrite,
        [bool]$DryRun,
        [int]$Concurrency
    )

    $results = New-Object 'System.Collections.Generic.Dictionary[int, object]'
    $failures = New-Object System.Collections.Generic.List[string]

    if ($DryRun -or $Concurrency -le 1 -or $Descriptors.Count -le 1) {
        foreach ($descriptor in $Descriptors) {
            try {
                $jobResult = Invoke-ImageCurlBatchJob -Index $descriptor.index -Descriptor $descriptor `
                    -ResolvedOutputDir $ResolvedOutputDir -Endpoint $Endpoint -ApiKey $ApiKey `
                    -Timeout $Timeout -Overwrite $Overwrite -DryRun $DryRun
                $results[$descriptor.index] = $jobResult
            } catch {
                $message = "job $($descriptor.index) failed: $($_.Exception.Message)"
                $failures.Add($message) | Out-Null
            }
        }
        return [pscustomobject]@{
            Results  = $results
            Failures = $failures
        }
    }

    $runspacePool = [runspacefactory]::CreateRunspacePool(1, $Concurrency)
    $runspacePool.Open()
    $commonPath = Join-Path $PSScriptRoot 'ImageCurl.Common.ps1'
    $handles = New-Object System.Collections.Generic.List[object]

    try {
        foreach ($descriptor in $Descriptors) {
            $powershell = [powershell]::Create()
            $null = $powershell.AddScript({
                param(
                    $CommonPath,
                    $SkillDir,
                    $Index,
                    $Descriptor,
                    $ResolvedOutputDir,
                    $Endpoint,
                    $ApiKey,
                    $Timeout,
                    $Overwrite,
                    $DryRun
                )
                $ErrorActionPreference = 'Stop'
                . $CommonPath
                Import-ImageCurlLocalEnv -SkillDir $SkillDir
                try {
                    $jobResult = Invoke-ImageCurlBatchJob -Index $Index -Descriptor $Descriptor `
                        -ResolvedOutputDir $ResolvedOutputDir -Endpoint $Endpoint -ApiKey $ApiKey `
                        -Timeout $Timeout -Overwrite $Overwrite -DryRun $DryRun
                    return $jobResult
                } catch {
                    return [pscustomobject]@{
                        Success = $false
                        Preview = $null
                        Result  = $null
                        Error   = $_.Exception.Message
                    }
                }
            })
            $null = $powershell.AddArgument($commonPath).AddArgument($SkillDir).AddArgument($descriptor.index).AddArgument($descriptor).AddArgument($ResolvedOutputDir).AddArgument($Endpoint).AddArgument($ApiKey).AddArgument($Timeout).AddArgument($Overwrite).AddArgument($DryRun)
            $powershell.RunspacePool = $runspacePool
            $handles.Add([pscustomobject]@{
                Index  = $descriptor.index
                Pipe   = $powershell
                Handle = $powershell.BeginInvoke()
            }) | Out-Null
        }

        foreach ($item in $handles) {
            $jobResult = $item.Pipe.EndInvoke($item.Handle)
            $item.Pipe.Dispose()
            if ($jobResult.Success) {
                $results[$item.Index] = $jobResult
            } else {
                $failures.Add("job $($item.Index) failed: $($jobResult.Error)") | Out-Null
            }
        }
    } finally {
        $runspacePool.Close()
        $runspacePool.Dispose()
    }

    return [pscustomobject]@{
        Results  = $results
        Failures = $failures
    }
}

$argsObj = Parse-ImageCurlBatchArgs -ArgList $args
if ($argsObj.help) {
    Show-GenerateBatchUsage
    exit 0
}

if (-not $argsObj.input) { Write-ImageCurlError '必须提供 --input。' }
if (-not $argsObj.output_dir) { Write-ImageCurlError '必须提供 --output-dir。' }
if (-not $argsObj.model) { Write-ImageCurlError '--model 不能为空。' }
if (-not $argsObj.size) { Write-ImageCurlError '--size 不能为空。' }
if (-not $argsObj.format) { Write-ImageCurlError '--format 不能为空。' }
Test-BatchConcurrency -Value $argsObj.concurrency

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

$resolvedOutputDir = Resolve-FullPath $argsObj.output_dir
if (-not (Test-Path -LiteralPath $resolvedOutputDir)) {
    New-Item -ItemType Directory -Path $resolvedOutputDir -Force | Out-Null
}

$defaults = @{
    model              = $argsObj.model
    size               = $argsObj.size
    quality            = $argsObj.quality
    format             = $format
    output_compression = $argsObj.output_compression
    moderation         = $argsObj.moderation
    background         = $argsObj.background
    count              = $argsObj.count
    metadata           = $argsObj.metadata
}

$jobs = Read-BatchJobsJsonl -Path $argsObj.input
$descriptors = @()
$index = 0
foreach ($job in $jobs) {
    $index++
    $descriptors += Build-BatchJobDescriptor -Index $index -Job $job -Defaults $defaults
}

$config = Get-ImageCurlConfig -OverrideBaseUrl $argsObj.base_url -OverrideApiKey $argsObj.api_key
if (-not $config.BaseUrl) {
    Write-ImageCurlError '无法解析 base URL，请传入 --base-url 或设置 IMAGE_CURL_BASE_URL。'
}
if (-not $argsObj.dry_run -and -not $config.ApiKey) {
    Write-ImageCurlError "未找到 API Key。请在 $SkillDir/local.env 中设置 IMAGE_CURL_API_KEY，或传入 --api-key。"
}

$endpoint = Get-ImageEndpoint -BaseUrl $config.BaseUrl -Kind 'generations'
$batchResult = Invoke-BatchGenerateJobs -Descriptors $descriptors -ResolvedOutputDir $resolvedOutputDir `
    -Endpoint $endpoint -ApiKey $config.ApiKey -Timeout $argsObj.timeout -Overwrite $argsObj.overwrite `
    -DryRun $argsObj.dry_run -Concurrency ([int]$argsObj.concurrency)

if ($argsObj.dry_run) {
    foreach ($jobIndex in ($batchResult.Results.Keys | Sort-Object)) {
        ConvertTo-ImageCurlJson -InputObject $batchResult.Results[$jobIndex].Preview -Depth 10
    }
} else {
    $allSavedPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($jobIndex in ($batchResult.Results.Keys | Sort-Object)) {
        $result = $batchResult.Results[$jobIndex].Result
        $savedPaths = [string[]]@(Get-SavedPathsFromResult -Result $result)
        foreach ($path in $savedPaths) {
            Write-Output $path
            $allSavedPaths.Add($path)
        }
    }
    if ($allSavedPaths.Count -gt 0) {
        $threadId = Get-ImageCurlThreadId
        Save-ThreadState -ThreadId $threadId -LastOutput @($allSavedPaths)
    }
}

if ($batchResult.Failures.Count -gt 0) {
    foreach ($failure in $batchResult.Failures) {
        Write-Error $failure
    }
    exit 1
}

exit 0