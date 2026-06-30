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

function Parse-ImageCurlArgs {
    param([string[]]$ArgList)

    $result = [ordered]@{
        model               = 'gpt-image-2'
        prompt              = ''
        prompt_file         = ''
        output              = ''
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