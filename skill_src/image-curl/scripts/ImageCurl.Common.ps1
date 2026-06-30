$script:ImageCurlScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-ImageCurlError {
    param([string]$Message)
    Write-Error "错误：$Message"
    exit 1
}

function Import-ImageCurlLocalEnv {
    param([string]$SkillDir)
    $localEnv = Join-Path $SkillDir 'local.env'
    if (-not (Test-Path -LiteralPath $localEnv)) {
        return
    }
    Get-Content -LiteralPath $localEnv -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { return }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { return }
        $name = $line.Substring(0, $eq).Trim()
        $value = $line.Substring($eq + 1).Trim().Trim('"').Trim("'")
        if ($name) {
            Set-Item -Path "Env:$name" -Value $value
        }
    }
}

function Get-FirstNonEmpty {
    param([string[]]$Values)
    foreach ($value in $Values) {
        if ($null -ne $value -and "$value".Trim() -ne '') {
            return "$value".Trim()
        }
    }
    return ''
}

function Get-ImageCurlConfig {
    param(
        [string]$OverrideBaseUrl,
        [string]$OverrideApiKey
    )

    $codexHome = Get-FirstNonEmpty @($env:CODEX_HOME, (Join-Path $env:USERPROFILE '.codex'))
    $authPath = Join-Path $codexHome 'auth.json'
    $baseUrl = Get-FirstNonEmpty @(
        $OverrideBaseUrl,
        $env:IMAGE_CURL_BASE_URL,
        'https://aicode.cat'
    ).TrimEnd('/')

    $apiKey = Get-FirstNonEmpty @(
        $OverrideApiKey,
        $env:IMAGE_CURL_API_KEY,
        $env:OPENAI_API_KEY,
        $env:CLIPROXY_API_KEY
    )

    if (-not $apiKey -and (Test-Path -LiteralPath $authPath)) {
        try {
            $auth = Get-Content -LiteralPath $authPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $apiKey = Get-FirstNonEmpty @(
                $auth.OPENAI_API_KEY,
                $auth.OPENAI_API_TOKEN,
                $auth.api_key,
                $auth.token,
                $auth.openai_api_key
            )
        } catch {
            $apiKey = ''
        }
    }

    [pscustomobject]@{
        CodexHome = $codexHome
        AuthPath  = $authPath
        BaseUrl   = $baseUrl
        ApiKey    = $apiKey
    }
}

function Get-ImageEndpoint {
    param(
        [string]$BaseUrl,
        [string]$Kind
    )
    $routeBase = $BaseUrl.TrimEnd('/')
    if ($routeBase.EndsWith('/v1')) {
        return "$routeBase/images/$Kind"
    }
    return "$routeBase/v1/images/$Kind"
}

$script:ImageSizeStep = 16
$script:ImageMaxEdge = 3840
$script:ImageMinPixels = 655360
$script:ImageMaxPixels = 8294400
$script:ImageMaxRatio = 3.0

function Get-ImageSizeGcd {
    param([long]$A, [long]$B)
    while ($B -ne 0) {
        $temp = $B
        $B = $A % $B
        $A = $temp
    }
    return $A
}

function Get-ImageSizeLcm {
    param([long]$A, [long]$B)
    if ($A -eq 0 -or $B -eq 0) { return 0 }
    return ($A / (Get-ImageSizeGcd -A $A -B $B)) * $B
}

function Test-ResolvedImageSizeCandidate {
    param([int]$Width, [int]$Height)
    if ($Width -le 0 -or $Height -le 0) { return $false }
    if (($Width % $script:ImageSizeStep) -ne 0 -or ($Height % $script:ImageSizeStep) -ne 0) { return $false }
    if ($Width -gt $script:ImageMaxEdge -or $Height -gt $script:ImageMaxEdge) { return $false }
    $pixels = $Width * $Height
    if ($pixels -lt $script:ImageMinPixels -or $pixels -gt $script:ImageMaxPixels) { return $false }
    $longEdge = [Math]::Max($Width, $Height)
    $shortEdge = [Math]::Min($Width, $Height)
    if (($longEdge / $shortEdge) -gt $script:ImageMaxRatio) { return $false }
    return $true
}

function Get-ImageRatioCandidates {
    param([int]$WidthRatio, [int]$HeightRatio)

    $gcd = Get-ImageSizeGcd -A $WidthRatio -B $HeightRatio
    $numerator = [int]($WidthRatio / $gcd)
    $denominator = [int]($HeightRatio / $gcd)

    if ([Math]::Max($numerator, $denominator) / [Math]::Min($numerator, $denominator) -gt $script:ImageMaxRatio) {
        return @()
    }

    $stepMultiplier = Get-ImageSizeLcm -A ($script:ImageSizeStep / (Get-ImageSizeGcd -A $numerator -B $script:ImageSizeStep)) -B ($script:ImageSizeStep / (Get-ImageSizeGcd -A $denominator -B $script:ImageSizeStep))
    $baseWidth = $numerator * $stepMultiplier
    $baseHeight = $denominator * $stepMultiplier
    $maxScale = [Math]::Min([int]($script:ImageMaxEdge / $baseWidth), [int]($script:ImageMaxEdge / $baseHeight))

    $candidates = New-Object System.Collections.Generic.List[object]
    for ($scale = 1; $scale -le $maxScale; $scale++) {
        $width = $baseWidth * $scale
        $height = $baseHeight * $scale
        if (Test-ResolvedImageSizeCandidate -Width $width -Height $height) {
            $candidates.Add([pscustomobject]@{ Width = $width; Height = $height })
        }
    }
    return $candidates
}

function Compare-ImageSizeCandidateKeys {
    param(
        [object[]]$Left,
        [object[]]$Right
    )
    for ($index = 0; $index -lt $Left.Count; $index++) {
        if ($Left[$index] -lt $Right[$index]) { return -1 }
        if ($Left[$index] -gt $Right[$index]) { return 1 }
    }
    return 0
}

function Get-ImageSizeCandidateKey {
    param(
        [object]$Candidate,
        [int]$TargetWidth,
        [int]$TargetHeight
    )
    $targetPixels = $TargetWidth * $TargetHeight
    $distance = ($Candidate.Width - $TargetWidth) * ($Candidate.Width - $TargetWidth) +
        ($Candidate.Height - $TargetHeight) * ($Candidate.Height - $TargetHeight)
    $overshoot = [int](
        ($Candidate.Width -gt $TargetWidth) -or
        ($Candidate.Height -gt $TargetHeight) -or
        ($Candidate.Width * $Candidate.Height -gt $targetPixels)
    )
    $pixelDiff = [Math]::Abs(($Candidate.Width * $Candidate.Height) - $targetPixels)
    return @($distance, $overshoot, $pixelDiff, ($Candidate.Width * $Candidate.Height))
}

function Select-ImageSizeCandidate {
    param(
        [System.Collections.IEnumerable]$Candidates,
        [int]$TargetWidth = -1,
        [int]$TargetHeight = -1
    )

    $list = @($Candidates)
    if ($list.Count -eq 0) {
        Write-ImageCurlError "no valid image size candidate found under OpenAI constraints (edge <= $($script:ImageMaxEdge), divisible by $($script:ImageSizeStep), pixels $($script:ImageMinPixels)-$($script:ImageMaxPixels), ratio <= $($script:ImageMaxRatio):1)"
    }

    if ($TargetWidth -lt 0 -or $TargetHeight -lt 0) {
        $best = $null
        $bestKey = $null
        foreach ($candidate in $list) {
            $key = @(
                ($candidate.Width * $candidate.Height),
                [Math]::Max($candidate.Width, $candidate.Height),
                [Math]::Min($candidate.Width, $candidate.Height)
            )
            if ($null -eq $bestKey -or (Compare-ImageSizeCandidateKeys -Left $key -Right $bestKey) -gt 0) {
                $best = $candidate
                $bestKey = $key
            }
        }
        return $best
    }

    $best = $null
    $bestKey = $null
    foreach ($candidate in $list) {
        $key = Get-ImageSizeCandidateKey -Candidate $candidate -TargetWidth $TargetWidth -TargetHeight $TargetHeight
        if ($null -eq $bestKey -or (Compare-ImageSizeCandidateKeys -Left $key -Right $bestKey) -lt 0) {
            $best = $candidate
            $bestKey = $key
        }
    }
    return $best
}

function Resolve-ImageSize {
    param([string]$Spec)

    $rawSpec = $Spec.Trim()
    if ($rawSpec.ToLowerInvariant() -eq 'auto') {
        return [pscustomobject]@{
            ApiSize               = 'auto'
            SizeNote              = $null
            IsExplicitDimension   = $false
        }
    }

    if ($rawSpec -match '^\s*([1-9]\d*)\s*[kK]\s*$') {
        $tierEdge = [int]$Matches[1] * 1024
        $normalized = "${tierEdge}x${tierEdge}"
        if (Test-ResolvedImageSizeCandidate -Width $tierEdge -Height $tierEdge) {
            return [pscustomobject]@{
                ApiSize               = $normalized
                SizeNote              = "normalized image size $rawSpec -> $normalized"
                IsExplicitDimension   = $false
            }
        }
        Write-ImageCurlError "invalid image size tier: $rawSpec"
    }

    if ($rawSpec -match '^\s*(?:(\d+\s*:\s*\d+)\s*(?:@|,|\s+)\s*([1-9]\d*\s*[kK])|([1-9]\d*\s*[kK])\s*(?:@|,|\s+)\s*(\d+\s*:\s*\d+))\s*$') {
        $ratioText = if ($Matches[1]) { $Matches[1] } else { $Matches[4] }
        $tierText = if ($Matches[2]) { $Matches[2] } else { $Matches[3] }
        if ($ratioText -notmatch '^\s*(\d+)\s*:\s*(\d+)\s*$') {
            Write-ImageCurlError "invalid image ratio: $ratioText"
        }
        $widthRatio = [int]$Matches[1]
        $heightRatio = [int]$Matches[2]
        if ($widthRatio -le 0 -or $heightRatio -le 0) {
            Write-ImageCurlError "invalid image ratio: $ratioText"
        }
        if ($tierText -notmatch '^\s*([1-9]\d*)\s*[kK]\s*$') {
            Write-ImageCurlError "invalid image size tier: $tierText"
        }
        $tierEdge = [int]$Matches[1] * 1024
        $candidates = Get-ImageRatioCandidates -WidthRatio $widthRatio -HeightRatio $heightRatio
        $gcd = Get-ImageSizeGcd -A $widthRatio -B $heightRatio
        $numerator = [int]($widthRatio / $gcd)
        $denominator = [int]($heightRatio / $gcd)
        if ($numerator -ge $denominator) {
            $targetHeight = $tierEdge
            $targetWidth = [int][Math]::Round($tierEdge * $numerator / $denominator)
        } else {
            $targetWidth = $tierEdge
            $targetHeight = [int][Math]::Round($tierEdge * $denominator / $numerator)
        }
        $chosen = Select-ImageSizeCandidate -Candidates $candidates -TargetWidth $targetWidth -TargetHeight $targetHeight
        $normalized = "$($chosen.Width)x$($chosen.Height)"
        return [pscustomobject]@{
            ApiSize               = $normalized
            SizeNote              = "normalized image size $rawSpec -> $normalized"
            IsExplicitDimension   = $false
        }
    }

    if ($rawSpec -match '^\s*(\d+)\s*[xX×]\s*(\d+)\s*$') {
        $width = [int]$Matches[1]
        $height = [int]$Matches[2]
        $normalized = "${width}x${height}"
        return [pscustomobject]@{
            ApiSize               = $normalized
            SizeNote              = $null
            IsExplicitDimension   = $true
        }
    }

    if ($rawSpec -match '^\s*(\d+)\s*:\s*(\d+)\s*$') {
        $widthRatio = [int]$Matches[1]
        $heightRatio = [int]$Matches[2]
        if ($widthRatio -le 0 -or $heightRatio -le 0) {
            Write-ImageCurlError "invalid image ratio: $rawSpec"
        }
        $candidates = Get-ImageRatioCandidates -WidthRatio $widthRatio -HeightRatio $heightRatio
        $chosen = Select-ImageSizeCandidate -Candidates $candidates
        $normalized = "$($chosen.Width)x$($chosen.Height)"
        return [pscustomobject]@{
            ApiSize               = $normalized
            SizeNote              = "normalized image size $rawSpec -> $normalized"
            IsExplicitDimension   = $false
        }
    }

    Write-ImageCurlError 'invalid image size. Use auto, WIDTHxHEIGHT, or WIDTH:HEIGHT (examples: 3840x2160, 1792x1024, 9:16, 9:16@1k)'
}

function Get-PromptSizeConstraint {
    param([string]$Size)
    if ($Size -notmatch '^\s*(\d+)\s*[xX×]\s*(\d+)\s*$') { return $null }
    $width = [int]$Matches[1]
    $height = [int]$Matches[2]
    if ($width -eq $height) {
        $orientation = 'square'
    } elseif ($width -gt $height) {
        $orientation = 'landscape'
    } else {
        $orientation = 'portrait'
    }
    return "Final output constraint: compose for an exact ${width}x${height} pixel ${orientation} canvas. The generated image should visually match that final canvas size and aspect ratio; do not imply a different resolution, crop, border, or padding."
}

function Add-PromptSizeConstraint {
    param(
        [string]$Prompt,
        [string]$RawSpec,
        [string]$ApiSize
    )
    if ($RawSpec -notmatch '^\s*(\d+)\s*[xX×]\s*(\d+)\s*$') {
        return $Prompt
    }
    $constraint = Get-PromptSizeConstraint -Size $ApiSize
    if (-not $constraint -or $Prompt.Contains($constraint)) {
        return $Prompt
    }
    return ($Prompt.TrimEnd() + "`n`n" + $constraint)
}

function Test-ImageSize {
    param([string]$Size)
    if ($Size -eq 'auto') { return }
    if ($Size -notmatch '^([1-9][0-9]*)x([1-9][0-9]*)$') {
        Write-ImageCurlError '--size 须为 auto 或 宽x高，例如 1024x1024、1344x768、2048x1152。'
    }
    $width = [int]$Matches[1]
    $height = [int]$Matches[2]
    $pixelCount = $width * $height
    if ($width -gt 3840 -or $height -gt 3840) {
        Write-ImageCurlError "--size '$Size' 不受上游支持：最长边不得超过 3840。"
    }
    if (($width % 16) -ne 0 -or ($height % 16) -ne 0) {
        Write-ImageCurlError "--size '$Size' 不受上游支持：宽和高均须为 16 的倍数。"
    }
    if ($width -gt ($height * 3) -or $height -gt ($width * 3)) {
        Write-ImageCurlError "--size '$Size' 不受上游支持：最大宽高比为 3:1。"
    }
    if ($pixelCount -lt 655360 -or $pixelCount -gt 8294400) {
        Write-ImageCurlError "--size '$Size' 不受上游支持：总像素数须在 655360 至 8294400 之间。"
    }
}

function Test-InputFidelity {
    param([string]$Value)
    if (-not $Value) { return }
    if ($Value -notin @('low', 'high')) {
        Write-ImageCurlError '--input-fidelity 须为 low 或 high。'
    }
}

function Get-ImageCurlThreadId {
    $threadId = Get-FirstNonEmpty @($env:CODEX_THREAD_ID, $env:CODEX_SESSION_ID)
    if (-not $threadId) {
        return 'manual'
    }
    return $threadId
}

function Sanitize-PathSegment {
    param([string]$Value)
    if (-not $Value) {
        return 'generated_image'
    }
    $chars = $Value.ToCharArray() | ForEach-Object {
        if ([char]::IsAsciiLetterOrDigit($_) -or $_ -in '-', '_') {
            [string]$_
        } else {
            '_'
        }
    }
    $sanitized = -join $chars
    if (-not $sanitized) {
        return 'generated_image'
    }
    return $sanitized
}

function Get-RandomOutputSuffix {
    param([int]$Length = 8)
    return [guid]::NewGuid().ToString('N').Substring(0, $Length)
}

function Get-DefaultOutputDir {
    $codexHome = Get-FirstNonEmpty @($env:CODEX_HOME, (Join-Path $env:USERPROFILE '.codex'))
    $threadId = Sanitize-PathSegment (Get-ImageCurlThreadId)
    return (Join-Path (Join-Path $codexHome 'generated_images') $threadId)
}

function Resolve-OutputPath {
    param(
        [string]$Output,
        [string]$OutputDir,
        [string]$Name,
        [string]$Format
    )

    $ext = ".$Format"

    if ($Output) {
        $path = $Output
        if (-not [System.IO.Path]::IsPathRooted($path)) {
            $path = [System.IO.Path]::GetFullPath($path)
        }
        if (-not [System.IO.Path]::GetExtension($path)) {
            $path = $path + $ext
        }
        return $path
    }

    if ($OutputDir) {
        $baseDir = $OutputDir
        if (-not [System.IO.Path]::IsPathRooted($baseDir)) {
            $baseDir = [System.IO.Path]::GetFullPath($baseDir)
        }
    } else {
        $baseDir = Get-DefaultOutputDir
    }

    if (-not (Test-Path -LiteralPath $baseDir)) {
        New-Item -ItemType Directory -Path $baseDir -Force | Out-Null
    }

    $prefix = Sanitize-PathSegment $(if ($Name) { $Name } else { 'generated' })
    return Join-Path $baseDir ("{0}-{1}{2}" -f $prefix, (Get-RandomOutputSuffix), $ext)
}

function Get-OutputTargets {
    param(
        [string]$OutputPath,
        [string]$Format,
        [int]$Count
    )
    if ($Count -eq 1) {
        return @($OutputPath)
    }
    $resolved = [System.IO.Path]::GetFullPath($OutputPath)
    $dir = [System.IO.Path]::GetDirectoryName($resolved)
    $fileName = [System.IO.Path]::GetFileName($resolved)
    $suffix = [System.IO.Path]::GetExtension($fileName)
    if (-not $suffix) { $suffix = ".$Format" }
    $stem = if ($suffix) { $fileName.Substring(0, $fileName.Length - $suffix.Length) } else { $fileName }
    $targets = @()
    for ($i = 1; $i -le $Count; $i++) {
        $targets += Join-Path $dir "${stem}-${i}${suffix}"
    }
    return $targets
}

function Assert-OutputTargetsAvailable {
    param(
        [string[]]$Targets,
        [bool]$Overwrite
    )
    if ($Overwrite) { return }
    $conflicts = $Targets | Where-Object { Test-Path -LiteralPath $_ }
    if ($conflicts.Count -gt 0) {
        Write-ImageCurlError ("输出文件已存在：{0}（如需覆盖请加 --overwrite）" -f ($conflicts -join ', '))
    }
}

function Save-ImageCurlResponse {
    param(
        [string]$ResponseJson,
        [string]$OutputPath,
        [string]$MetadataPath,
        [string]$Format,
        [int]$RequestedCount
    )

    try {
        $response = $ResponseJson | ConvertFrom-Json
    } catch {
        Write-ImageCurlError "响应不是合法的 JSON：$($_.Exception.Message)"
    }

    $data = @($response.data)
    if ($data.Count -eq 0) {
        Write-ImageCurlError '响应 JSON 中缺少 data[0]。'
    }

    $targetCount = if ($RequestedCount -gt 1) { $RequestedCount } else { $data.Count }
    $targets = [string[]]@(Get-OutputTargets -OutputPath $OutputPath -Format $Format -Count $targetCount)
    $savedFiles = @()

    for ($index = 0; $index -lt $data.Count; $index++) {
        $item = $data[$index]
        $b64 = $item.b64_json
        if (-not $b64) {
            Write-ImageCurlError "响应 JSON 中缺少 data[$index].b64_json。"
        }
        try {
            $bytes = [Convert]::FromBase64String($b64)
        } catch {
            Write-ImageCurlError "data[$index] 中的 base64 图片数据无效：$($_.Exception.Message)"
        }
        $target = $targets[$index]
        $targetDir = Split-Path -Parent $target
        if ($targetDir -and -not (Test-Path -LiteralPath $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }
        [System.IO.File]::WriteAllBytes($target, $bytes)
        $savedFiles += [pscustomobject]@{
            path           = (Normalize-PathForJson $target)
            bytes          = $bytes.Length
            revised_prompt = $item.revised_prompt
        }
    }

    if ($MetadataPath) {
        $sanitized = $ResponseJson | ConvertFrom-Json
        foreach ($item in $sanitized.data) {
            if ($null -ne $item.PSObject.Properties['b64_json']) {
                $item.b64_json = '<omitted>'
            }
        }
        $sanitized | Add-Member -NotePropertyName saved_files -NotePropertyValue @($savedFiles | ForEach-Object { $_.path }) -Force
        $sanitized | Add-Member -NotePropertyName requested_count -NotePropertyValue $RequestedCount -Force
        $metaDir = Split-Path -Parent $MetadataPath
        if ($metaDir -and -not (Test-Path -LiteralPath $metaDir)) {
            New-Item -ItemType Directory -Path $metaDir -Force | Out-Null
        }
        ConvertTo-ImageCurlJson -InputObject $sanitized -Depth 20 | Set-Content -LiteralPath $MetadataPath -Encoding UTF8
    }

    if ($RequestedCount -eq 1 -and $savedFiles.Count -eq 1) {
        return [pscustomobject]@{
            saved_file     = $savedFiles[0].path
            bytes          = $savedFiles[0].bytes
            revised_prompt = $savedFiles[0].revised_prompt
        }
    }

    return [pscustomobject]@{
        saved_files      = $savedFiles
        requested_count  = $RequestedCount
        returned_count   = $savedFiles.Count
    }
}

function Read-BatchJobsJsonl {
    param([string]$Path)

    $parserPy = Join-Path $script:ImageCurlScriptDir 'lib/parse_batch_jsonl.py'
    if (-not (Test-Path -LiteralPath $parserPy)) {
        Write-ImageCurlError "未找到批量任务解析脚本：$parserPy"
    }
    $python = Get-ThreadStatePython
    $raw = & $python.Exe @($python.Prefix + $parserPy, $Path) 2>&1
    if ($LASTEXITCODE -ne 0) {
        $message = ($raw | ForEach-Object { "$_" }) -join "`n"
        Write-ImageCurlError $(if ($message.Trim()) { $message.Trim() } else { '无法解析批量 JSONL 输入。' })
    }
    $json = ($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    return @($json | ConvertFrom-Json)
}

function Test-BatchConcurrency {
    param([string]$Value)
    if ($Value -notmatch '^\d+$' -or [int]$Value -lt 1 -or [int]$Value -gt 25) {
        Write-ImageCurlError '--concurrency 须为 1 至 25 之间的整数。'
    }
}

function Get-FirstNonEmptyValue {
    param([object[]]$Values)
    foreach ($value in $Values) {
        if ($null -eq $value) { continue }
        $text = "$value".Trim()
        if ($text) { return $text }
    }
    return ''
}

function Build-BatchJobDescriptor {
    param(
        [int]$Index,
        [object]$Job,
        [hashtable]$Defaults
    )

    $prompt = Get-FirstNonEmptyValue @($Job.prompt, $Defaults.prompt)
    if (-not $prompt) {
        Write-ImageCurlError "job ${Index}: missing prompt"
    }

    $name = Get-FirstNonEmptyValue @($Job.name, $Defaults.name)
    if (-not $name) {
        $name = '{0:D3}' -f $Index
    }

    $count = Get-FirstNonEmptyValue @($Job.n, $Job.count, $Defaults.count)
    if (-not $count) { $count = '1' }

    return [pscustomobject]@{
        index               = $Index
        prompt              = $prompt
        model               = (Get-FirstNonEmptyValue @($Job.model, $Defaults.model))
        size                = (Get-FirstNonEmptyValue @($Job.size, $Defaults.size))
        quality             = (Get-FirstNonEmptyValue @($Job.quality, $Defaults.quality))
        format              = (Get-FirstNonEmptyValue @($Job.format, $Defaults.format))
        output_compression  = (Get-FirstNonEmptyValue @($Job.output_compression, $Job.compression, $Defaults.output_compression))
        moderation          = (Get-FirstNonEmptyValue @($Job.moderation, $Defaults.moderation))
        background          = (Get-FirstNonEmptyValue @($Job.background, $Defaults.background))
        count               = $count
        name                = $name
        output              = (Get-FirstNonEmptyValue @($Job.output, $Job.out))
        metadata            = (Get-FirstNonEmptyValue @($Job.metadata, $Job.metadata_path))
    }
}

function Invoke-ImageCurlBatchJob {
    param(
        [int]$Index,
        [object]$Descriptor,
        [string]$ResolvedOutputDir,
        [string]$Endpoint,
        [string]$ApiKey,
        [string]$Timeout,
        [bool]$Overwrite,
        [bool]$DryRun
    )

    $format = $Descriptor.format.ToLowerInvariant()
    if ($format -eq 'jpg') { $format = 'jpeg' }
    if ($format -notin @('png', 'jpeg', 'webp')) {
        throw '--format 须为 png、jpeg、jpg 或 webp。'
    }
    if ($Descriptor.count -notmatch '^\d+$' -or [int]$Descriptor.count -lt 1 -or [int]$Descriptor.count -gt 10) {
        throw '--count/--n 须为 1 至 10 之间的整数。'
    }

    $requestedSize = $Descriptor.size
    $resolvedSize = Resolve-ImageSize -Spec $requestedSize
    $size = $resolvedSize.ApiSize.ToLowerInvariant()
    Test-ImageSize -Size $size

    $prompt = Add-PromptSizeConstraint -Prompt $Descriptor.prompt -RawSpec $requestedSize -ApiSize $size

    if ($Descriptor.output) {
        $output = Resolve-OutputPath -Output $Descriptor.output -OutputDir '' -Name '' -Format $format
    } else {
        $output = Resolve-OutputPath -Output '' -OutputDir $ResolvedOutputDir -Name $Descriptor.name -Format $format
    }
    $output = Resolve-FullPath $output
    $outputParent = Split-Path -Parent $output
    if ($outputParent -and -not (Test-Path -LiteralPath $outputParent)) {
        New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
    }

    $count = [int]$Descriptor.count
    $targets = [string[]]@(Get-OutputTargets -OutputPath $output -Format $format -Count $count)
    Assert-OutputTargetsAvailable -Targets $targets -Overwrite $Overwrite

    $metadata = ''
    if ($Descriptor.metadata) {
        $metadata = Resolve-FullPath $Descriptor.metadata
        $metaDir = Split-Path -Parent $metadata
        if ($metaDir -and -not (Test-Path -LiteralPath $metaDir)) {
            New-Item -ItemType Directory -Path $metaDir -Force | Out-Null
        }
    }

    $payload = [ordered]@{
        model         = $Descriptor.model
        prompt        = $prompt
        size          = $size
        quality       = $Descriptor.quality
        output_format = $format
        moderation    = $Descriptor.moderation
        n             = $count
    }
    if ("$($Descriptor.background)".Trim()) { $payload.background = "$($Descriptor.background)".Trim() }
    if ($Descriptor.output_compression) { $payload.output_compression = [int]$Descriptor.output_compression }

    if ($DryRun) {
        $preview = [ordered]@{
            job           = $Index
            endpoint      = $Endpoint
            authorization = 'Bearer ***'
            payload       = [pscustomobject]$payload
            output        = $output
            count         = $count
            metadata      = if ($metadata) { $metadata } else { $null }
        }
        if ($resolvedSize.SizeNote) {
            $preview['size_note'] = $resolvedSize.SizeNote
        }
        return [pscustomobject]@{
            Success = $true
            Preview = [pscustomobject]$preview
            Result  = $null
            Error   = $null
        }
    }

    $body = ($payload | ConvertTo-Json -Depth 10 -Compress)
    $tempFile = [System.IO.Path]::GetTempFileName()
    $bodyFile = [System.IO.Path]::GetTempFileName()
    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($bodyFile, $body, $utf8NoBom)
        $curlArgs = @(
            '-sS', '--fail-with-body', '-X', 'POST', $Endpoint,
            '-H', "Authorization: Bearer $ApiKey",
            '-H', 'Content-Type: application/json; charset=utf-8',
            '-H', 'Cache-Control: no-store, no-cache, max-age=0',
            '-H', 'Pragma: no-cache',
            '--max-time', $Timeout,
            '--data-binary', "@$bodyFile",
            '-o', $tempFile
        )
        & curl.exe @curlArgs
        if ($LASTEXITCODE -ne 0) {
            $errorBody = if (Test-Path -LiteralPath $tempFile) { Get-Content -LiteralPath $tempFile -Raw } else { '' }
            throw "curl 请求失败（退出码 $LASTEXITCODE）。$errorBody"
        }
        $responseJson = Get-Content -LiteralPath $tempFile -Raw -Encoding UTF8
        $result = Save-ImageCurlResponse -ResponseJson $responseJson -OutputPath $output -MetadataPath $metadata -Format $format -RequestedCount $count
        return [pscustomobject]@{
            Success = $true
            Preview = $null
            Result  = $result
            Error   = $null
        }
    } finally {
        foreach ($file in @($tempFile, $bodyFile)) {
            if ($file -and (Test-Path -LiteralPath $file)) {
                Remove-Item -LiteralPath $file -Force
            }
        }
    }
}

function Parse-ImageCurlBatchArgs {
    param([string[]]$ArgList)

    $result = [ordered]@{
        input               = ''
        output_dir          = ''
        concurrency         = '4'
        model               = 'gpt-image-2'
        size                = '1024x1024'
        quality             = 'auto'
        format              = 'png'
        output_compression  = ''
        moderation          = 'auto'
        background          = ''
        count               = '1'
        metadata            = ''
        base_url            = ''
        api_key             = ''
        timeout             = '300'
        overwrite           = $false
        dry_run             = $false
        help                = $false
    }

    $i = 0
    while ($i -lt $ArgList.Count) {
        $arg = $ArgList[$i]
        switch ($arg) {
            '--input' { $result.input = $ArgList[++$i]; $i++; continue }
            '--output-dir' { $result.output_dir = $ArgList[++$i]; $i++; continue }
            '--concurrency' { $result.concurrency = $ArgList[++$i]; $i++; continue }
            '--model' { $result.model = $ArgList[++$i]; $i++; continue }
            '--size' { $result.size = $ArgList[++$i]; $i++; continue }
            '--quality' { $result.quality = $ArgList[++$i]; $i++; continue }
            { $_ -in '--format', '--output-format' } { $result.format = $ArgList[++$i]; $i++; continue }
            '--output-compression' { $result.output_compression = $ArgList[++$i]; $i++; continue }
            '--moderation' { $result.moderation = $ArgList[++$i]; $i++; continue }
            '--background' { $result.background = $ArgList[++$i]; $i++; continue }
            { $_ -in '--count', '--n' } { $result.count = $ArgList[++$i]; $i++; continue }
            { $_ -in '--metadata', '--metadata-path' } { $result.metadata = $ArgList[++$i]; $i++; continue }
            '--base-url' { $result.base_url = $ArgList[++$i]; $i++; continue }
            '--api-key' { $result.api_key = $ArgList[++$i]; $i++; continue }
            '--timeout' { $result.timeout = $ArgList[++$i]; $i++; continue }
            '--prompt' { Write-ImageCurlError 'generate-batch 不支持 --prompt；请使用 --input JSONL 文件。' }
            '--prompt-file' { $i += 2; continue }
            '--output' { Write-ImageCurlError 'generate-batch 不支持 --output；请使用 --output-dir 与 job 级 name/out。' }
            '--name' { Write-ImageCurlError 'generate-batch 不支持全局 --name；请在 JSONL 每行 job 中设置 name。' }
            '--overwrite' { $result.overwrite = $true; $i++; continue }
            '--dry-run' { $result.dry_run = $true; $i++; continue }
            { $_ -in '-h', '--help' } { $result.help = $true; $i++; continue }
            default { Write-ImageCurlError "未知选项：$arg" }
        }
    }

    return [pscustomobject]$result
}

function Parse-ImageCurlArgs {
    param([string[]]$ArgList)

    $result = [ordered]@{
        model               = 'gpt-image-2'
        prompt              = ''
        prompt_file         = ''
        output              = ''
        output_dir          = ''
        name                = ''
        size                = '1024x1024'
        quality             = 'auto'
        format              = 'png'
        output_compression  = ''
        moderation          = 'auto'
        background          = ''
        count               = '1'
        metadata            = ''
        base_url            = ''
        api_key             = ''
        timeout             = '300'
        overwrite           = $false
        dry_run             = $false
        images              = New-Object System.Collections.Generic.List[string]
        image_sets          = New-Object System.Collections.Generic.List[string]
        mask                = ''
        input_fidelity      = ''
        help                = $false
    }

    $i = 0
    while ($i -lt $ArgList.Count) {
        $arg = $ArgList[$i]
        switch ($arg) {
            '--model' { $result.model = $ArgList[++$i]; $i++; continue }
            '--prompt' { $result.prompt = $ArgList[++$i]; $i++; continue }
            '--prompt-file' { $result.prompt_file = $ArgList[++$i]; $i++; continue }
            '--output' { $result.output = $ArgList[++$i]; $i++; continue }
            '--output-dir' { $result.output_dir = $ArgList[++$i]; $i++; continue }
            '--name' { $result.name = $ArgList[++$i]; $i++; continue }
            '--size' { $result.size = $ArgList[++$i]; $i++; continue }
            '--quality' { $result.quality = $ArgList[++$i]; $i++; continue }
            { $_ -in '--format', '--output-format' } { $result.format = $ArgList[++$i]; $i++; continue }
            '--output-compression' { $result.output_compression = $ArgList[++$i]; $i++; continue }
            '--moderation' { $result.moderation = $ArgList[++$i]; $i++; continue }
            '--background' { $result.background = $ArgList[++$i]; $i++; continue }
            { $_ -in '--count', '--n' } { $result.count = $ArgList[++$i]; $i++; continue }
            { $_ -in '--metadata', '--metadata-path' } { $result.metadata = $ArgList[++$i]; $i++; continue }
            '--base-url' { $result.base_url = $ArgList[++$i]; $i++; continue }
            '--api-key' { $result.api_key = $ArgList[++$i]; $i++; continue }
            '--timeout' { $result.timeout = $ArgList[++$i]; $i++; continue }
            '--image' { $result.images.Add($ArgList[++$i]); $i++; continue }
            '--image-set' { $result.image_sets.Add($ArgList[++$i]); $i++; continue }
            '--mask' { $result.mask = $ArgList[++$i]; $i++; continue }
            '--input-fidelity' { $result.input_fidelity = $ArgList[++$i]; $i++; continue }
            '--overwrite' { $result.overwrite = $true; $i++; continue }
            '--dry-run' { $result.dry_run = $true; $i++; continue }
            { $_ -in '-h', '--help' } { $result.help = $true; $i++; continue }
            default { Write-ImageCurlError "未知选项：$arg" }
        }
    }

    return [pscustomobject]$result
}

function Resolve-FullPath {
    param([string]$Path)
    if (-not $Path) { return '' }
    return [System.IO.Path]::GetFullPath($Path)
}

function Get-CurlFilePath {
    param([string]$Path)
    return (Normalize-PathForJson (Resolve-FullPath $Path))
}

function Normalize-PathForJson {
    param([string]$Path)
    if (-not $Path) { return $Path }
    return $Path.Replace('\', '/')
}

function Get-ThreadStatePython {
    # Resolve interpreter by presence only; Invoke-ThreadState surfaces runtime failures.
    foreach ($candidate in @(
            @{ Exe = 'python'; Prefix = @() },
            @{ Exe = 'python3'; Prefix = @() },
            @{ Exe = 'py'; Prefix = @('-3') }
        )) {
        if (Get-Command $candidate.Exe -ErrorAction SilentlyContinue) {
            return @{ Exe = $candidate.Exe; Prefix = $candidate.Prefix }
        }
    }
    Write-ImageCurlError '未找到 Python 3，无法处理线程占位符/状态。请安装 Python 3 并确保 python、python3 或 py -3 可用。'
}

function Invoke-ThreadState {
    param(
        [string[]]$Arguments,
        [string]$StdinJson = ''
    )

    $threadStatePy = Join-Path $script:ImageCurlScriptDir 'lib/thread_state.py'
    if (-not (Test-Path -LiteralPath $threadStatePy)) {
        Write-ImageCurlError "未找到线程状态脚本：$threadStatePy"
    }

    $python = Get-ThreadStatePython
    $requestFile = $null
    try {
        $cmdArgs = @($python.Prefix + $threadStatePy) + $Arguments
        if ($StdinJson) {
            $utf8NoBom = New-Object System.Text.UTF8Encoding $false
            $requestFile = [System.IO.Path]::GetTempFileName()
            [System.IO.File]::WriteAllText($requestFile, $StdinJson, $utf8NoBom)
            $cmdArgs += @('--request-file', $requestFile)
        }

        $output = & $python.Exe @cmdArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            $stderr = ($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join "`n"
            $stdout = ($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
            $message = if ($stderr.Trim()) { $stderr.Trim() } elseif ($stdout.Trim()) { $stdout.Trim() } else { '' }
            if ($message) {
                Write-ImageCurlError $message
            }
            Write-ImageCurlError "thread_state.py 执行失败（退出码 $LASTEXITCODE）。"
        }
        return (($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n")
    } finally {
        if ($requestFile -and (Test-Path -LiteralPath $requestFile)) {
            Remove-Item -LiteralPath $requestFile -Force
        }
    }
}

function ConvertFrom-ThreadStatePathJson {
    param([string]$Json)

    if (-not $Json -or -not $Json.Trim()) { return @() }
    $python = Get-ThreadStatePython
    $jsonFile = [System.IO.Path]::GetTempFileName()
    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($jsonFile, $Json, $utf8NoBom)
        $parserPy = Join-Path $script:ImageCurlScriptDir 'lib/parse_path_json.py'
        if (-not (Test-Path -LiteralPath $parserPy)) {
            Write-ImageCurlError "未找到路径解析脚本：$parserPy"
        }
        $raw = & $python.Exe @($python.Prefix + $parserPy, $jsonFile)
        if ($LASTEXITCODE -ne 0) {
            Write-ImageCurlError '无法解析 thread_state resolve 输出 JSON。'
        }
        $list = New-Object System.Collections.Generic.List[string]
        if ($raw -is [System.Array]) {
            foreach ($line in $raw) {
                $trimmed = "$line".Trim()
                if ($trimmed) { [void]$list.Add($trimmed) }
            }
        } else {
            foreach ($line in ("$raw" -split "`r?`n")) {
                $trimmed = $line.Trim()
                if ($trimmed) { [void]$list.Add($trimmed) }
            }
        }
        return $list.ToArray()
    } finally {
        if (Test-Path -LiteralPath $jsonFile) {
            Remove-Item -LiteralPath $jsonFile -Force
        }
    }
}

function Resolve-ImageRefs {
    param(
        [string]$ThreadId,
        [string[]]$ImageSets = @(),
        [string[]]$Images = @()
    )

    # Always use request JSON file: PowerShell strips '#' when passing args to native python.exe.
    $payload = [ordered]@{
        thread_id  = $ThreadId
        image_sets = @($ImageSets | Where-Object { $_ })
        images     = @($Images | Where-Object { $_ })
    }
    $stdinJson = ($payload | ConvertTo-Json -Compress -Depth 5)
    $json = Invoke-ThreadState -Arguments @('resolve') -StdinJson $stdinJson
    return ConvertFrom-ThreadStatePathJson -Json $json
}

function Save-ThreadState {
    param(
        [string]$ThreadId,
        [string[]]$ActiveInput = @(),
        [string[]]$LastOutput = @()
    )

    if ($ActiveInput.Count -eq 0 -and $LastOutput.Count -eq 0) {
        return
    }

    # Always use request JSON file: PowerShell strips '#' when passing args to native python.exe.
    $payload = [ordered]@{
        thread_id    = $ThreadId
        active_input = @([string[]]@($ActiveInput | Where-Object { $_ }))
        last_output  = @([string[]]@($LastOutput | Where-Object { $_ }))
    }
    $stdinJson = ($payload | ConvertTo-Json -Compress -Depth 5)
    Invoke-ThreadState -Arguments @('save') -StdinJson $stdinJson | Out-Null
}

function Get-SavedPathsFromResult {
    param([object]$Result)

    if ($null -eq $Result) { return @() }
    if ($Result.PSObject.Properties['saved_files']) {
        return @($Result.saved_files | ForEach-Object {
            if ($_ -is [string]) { $_ } else { $_.path }
        })
    }
    if ($Result.PSObject.Properties['saved_file']) {
        return @($Result.saved_file)
    }
    return @()
}

function ConvertTo-ImageCurlJson {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true, Position = 0)]
        [object]$InputObject,
        [int]$Depth = 10,
        [switch]$Compress
    )

    process {
        if ($null -eq $InputObject) { return }
        $normalized = Normalize-ImageCurlObject -Object $InputObject
        if ($Compress) {
            $normalized | ConvertTo-Json -Depth $Depth -Compress
        } else {
            $normalized | ConvertTo-Json -Depth $Depth
        }
    }
}

function Normalize-ImageCurlObject {
    param([object]$Object)

    if ($null -eq $Object) { return $null }
    if ($Object -is [string]) {
        if ($Object -match '^[A-Za-z]:[\\/]' -or $Object -match '^\\\\') {
            return (Normalize-PathForJson $Object)
        }
        return $Object
    }
    if ($Object -is [bool] -or $Object -is [int] -or $Object -is [long] -or $Object -is [double]) {
        return $Object
    }
    if ($Object -is [System.Collections.IEnumerable] -and -not ($Object -is [string])) {
        return @($Object | ForEach-Object { Normalize-ImageCurlObject -Object $_ })
    }

    $clone = [ordered]@{}
    foreach ($prop in $Object.PSObject.Properties) {
        $clone[$prop.Name] = Normalize-ImageCurlObject -Object $prop.Value
    }
    return [pscustomobject]$clone
}