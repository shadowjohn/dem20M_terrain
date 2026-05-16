#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet("taichung", "taoyuan", "newtaipei")]
    [string[]] $County,

    [switch] $All,
    [switch] $ValidateOnly,
    [switch] $SkipDownload,
    [switch] $SkipDockerPull,
    [switch] $ForceRebuild,

    [string] $DockerImage = "ghcr.io/tum-gis/ctb-quantized-mesh:latest",
    [int] $CommandTimeoutSec = 7200,
    [int] $DownloadRetry = 3
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "Continue"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ConfigPath = Join-Path $RepoRoot "config/counties.json"
$HistoryPath = Join-Path $RepoRoot "history.md"
$LogDir = Join-Path $RepoRoot "logs"
$RunStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$LogPath = Join-Path $LogDir "build-$RunStamp.log"
$CtbCommandText = "ctb-tile -f Mesh -p geodetic -C"

function New-Directory {
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-Log {
    param([Parameter(Mandatory)][string] $Message)
    New-Directory -Path $LogDir
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    $line | Tee-Object -FilePath $LogPath -Append
}

function Get-RequiredCommand {
    param([Parameter(Mandatory)][string] $Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "找不到必要工具：$Name"
    }
    return $cmd.Source
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][string[]] $ArgumentList,
        [int] $TimeoutSec = $CommandTimeoutSec
    )

    Write-Log ("[CMD] {0} {1}" -f $FilePath, ($ArgumentList -join " "))

    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()
    $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -NoNewWindow -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $timer = [System.Diagnostics.Stopwatch]::StartNew()

    while (-not $process.HasExited) {
        Start-Sleep -Seconds 5
        if ($TimeoutSec -gt 0 -and $timer.Elapsed.TotalSeconds -gt $TimeoutSec) {
            try {
                $process.Kill()
            } catch {
                Write-Log "timeout 後停止程序時發生例外：$($_.Exception.Message)"
            }
            throw "指令逾時：$FilePath"
        }
    }

    $stdout = Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue
    $stderr = Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue

    if ($stdout) {
        Write-Log $stdout.TrimEnd()
    }
    if ($stderr) {
        Write-Log $stderr.TrimEnd()
    }
    if ($process.ExitCode -ne 0) {
        throw "指令執行失敗，exit code=$($process.ExitCode)：$FilePath"
    }
}

function Get-RemoteFileInfo {
    param([Parameter(Mandatory)] $CountyConfig)
    $response = Invoke-WebRequest -Uri $CountyConfig.url -Method Head -TimeoutSec 30
    return [pscustomobject]@{
        StatusCode = $response.StatusCode
        Bytes = [int64](($response.Headers."Content-Length" | Select-Object -First 1))
        ContentType = (($response.Headers."Content-Type" | Select-Object -First 1))
        LastModified = (($response.Headers."Last-Modified" | Select-Object -First 1))
    }
}

function Save-FileWithRetry {
    param(
        [Parameter(Mandatory)][string] $Url,
        [Parameter(Mandatory)][string] $TargetPath,
        [int] $Retry = $DownloadRetry
    )

    for ($attempt = 1; $attempt -le $Retry; $attempt++) {
        try {
            Write-Log "下載來源資料 [$attempt/$Retry]：$Url"
            Invoke-WebRequest -Uri $Url -OutFile $TargetPath -TimeoutSec 1800
            return
        } catch {
            Write-Log "下載失敗 [$attempt/$Retry]：$($_.Exception.Message)"
            if ($attempt -eq $Retry) {
                throw
            }
            Start-Sleep -Seconds ([Math]::Min(30, 3 * $attempt))
        }
    }
}

function Get-GdalVersionText {
    $gdalInfo = Get-RequiredCommand -Name "gdalinfo"
    try {
        return ((& $gdalInfo --version) -join " ").Trim()
    } catch {
        return "gdalinfo version unavailable"
    }
}

function Get-DockerVersionText {
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $docker) {
        return "docker unavailable"
    }
    try {
        return ((& $docker.Source --version) -join " ").Trim()
    } catch {
        return "docker version unavailable"
    }
}

function Add-HistoryEntry {
    param(
        [Parameter(Mandatory)] $CountyConfig,
        [Parameter(Mandatory)][string] $Status,
        [Parameter(Mandatory)][string] $Message,
        [object] $RemoteInfo
    )

    if (-not (Test-Path -LiteralPath $HistoryPath)) {
        "# dem20M_terrain History`n" | Set-Content -LiteralPath $HistoryPath -Encoding utf8
    }

    $bytes = if ($RemoteInfo -and $RemoteInfo.Bytes) { $RemoteInfo.Bytes } else { $CountyConfig.expectedBytes }
    $content = @(
        ""
        "## $(Get-Date -Format "yyyy-MM-dd HH:mm:ss") - $($CountyConfig.name) $Status"
        ""
        "- 來源：$($CountyConfig.url)"
        "- 來源大小：$bytes bytes"
        "- GDAL：$(Get-GdalVersionText)"
        "- Docker：$(Get-DockerVersionText)"
        "- CTB image：$DockerImage"
        "- 輸出：$($CountyConfig.outputDir)"
        "- 結果：$Message"
    )
    Add-Content -LiteralPath $HistoryPath -Value $content -Encoding utf8
}

function Test-GZipFile {
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        if ($stream.Length -lt 2) {
            return $false
        }
        $b1 = $stream.ReadByte()
        $b2 = $stream.ReadByte()
        return ($b1 -eq 0x1f -and $b2 -eq 0x8b)
    } finally {
        $stream.Dispose()
    }
}

function Expand-GZipFile {
    param(
        [Parameter(Mandatory)][string] $SourcePath,
        [Parameter(Mandatory)][string] $TargetPath
    )

    $source = [System.IO.File]::OpenRead($SourcePath)
    try {
        $gzip = [System.IO.Compression.GZipStream]::new($source, [System.IO.Compression.CompressionMode]::Decompress)
        try {
            $target = [System.IO.File]::Create($TargetPath)
            try {
                $gzip.CopyTo($target)
            } finally {
                $target.Dispose()
            }
        } finally {
            $gzip.Dispose()
        }
    } finally {
        $source.Dispose()
    }
}

function Normalize-TerrainTiles {
    param([Parameter(Mandatory)][string] $OutputPath)

    $gzFiles = Get-ChildItem -LiteralPath $OutputPath -Recurse -File -Filter "*.terrain.gz" -ErrorAction SilentlyContinue
    foreach ($gz in $gzFiles) {
        $target = $gz.FullName -replace "\.gz$", ""
        Write-Log "解壓 terrain.gz：$($gz.FullName)"
        Expand-GZipFile -SourcePath $gz.FullName -TargetPath $target
        Remove-Item -LiteralPath $gz.FullName -Force
    }

    $terrainFiles = Get-ChildItem -LiteralPath $OutputPath -Recurse -File -Filter "*.terrain" -ErrorAction SilentlyContinue
    foreach ($terrain in $terrainFiles) {
        if (Test-GZipFile -Path $terrain.FullName) {
            $tmp = "$($terrain.FullName).tmp"
            Write-Log "將 gzip 內容正規化成未壓縮 .terrain：$($terrain.FullName)"
            Expand-GZipFile -SourcePath $terrain.FullName -TargetPath $tmp
            Move-Item -LiteralPath $tmp -Destination $terrain.FullName -Force
        }
    }
}

function Get-SourceFiles {
    param([Parameter(Mandatory)][string] $RawPath)
    $patterns = @("*.tif", "*.tiff", "*.vrt", "*.img", "*.asc", "*.grd", "*.gdr")
    $files = foreach ($pattern in $patterns) {
        Get-ChildItem -LiteralPath $RawPath -Recurse -File -Filter $pattern -ErrorAction SilentlyContinue
    }
    return @($files | Sort-Object FullName -Unique)
}

function Build-SourceVrt {
    param(
        [Parameter(Mandatory)] $CountyConfig,
        [Parameter(Mandatory)][object[]] $SourceFiles,
        [Parameter(Mandatory)][string] $WorkPath
    )

    $gdalBuildVrt = Get-RequiredCommand -Name "gdalbuildvrt"
    $gdalTranslate = Get-RequiredCommand -Name "gdal_translate"
    $sourceList = Join-Path $WorkPath "$($CountyConfig.id)-sources.txt"
    $sourceVrt = Join-Path $WorkPath "$($CountyConfig.id)-source.vrt"

    $SourceFiles.FullName | Set-Content -LiteralPath $sourceList -Encoding utf8

    try {
        Invoke-ExternalCommand -FilePath $gdalBuildVrt -ArgumentList @("-overwrite", "-a_srs", $CountyConfig.sourceSrs, "-input_file_list", $sourceList, $sourceVrt)
        return $sourceVrt
    } catch {
        Write-Log "直接建立 VRT 失敗，改用 gdal_translate 逐檔轉 GeoTIFF：$($_.Exception.Message)"
    }

    $rasterizedPath = Join-Path $WorkPath "rasterized"
    New-Directory -Path $rasterizedPath
    $converted = @()

    foreach ($source in $SourceFiles) {
        $target = Join-Path $rasterizedPath "$($source.BaseName).tif"
        Invoke-ExternalCommand -FilePath $gdalTranslate -ArgumentList @("-of", "GTiff", "-a_srs", $CountyConfig.sourceSrs, $source.FullName, $target)
        $converted += Get-Item -LiteralPath $target
    }

    $convertedList = Join-Path $WorkPath "$($CountyConfig.id)-converted-sources.txt"
    $converted.FullName | Set-Content -LiteralPath $convertedList -Encoding utf8
    Invoke-ExternalCommand -FilePath $gdalBuildVrt -ArgumentList @("-overwrite", "-a_srs", $CountyConfig.sourceSrs, "-input_file_list", $convertedList, $sourceVrt)
    return $sourceVrt
}

function Build-Epsg4326Raster {
    param(
        [Parameter(Mandatory)] $CountyConfig,
        [Parameter(Mandatory)][string] $SourceVrt,
        [Parameter(Mandatory)][string] $WorkPath
    )

    $gdalWarp = Get-RequiredCommand -Name "gdalwarp"
    $targetTif = Join-Path $WorkPath "$($CountyConfig.id)-4326.tif"
    Invoke-ExternalCommand -FilePath $gdalWarp -ArgumentList @(
        "-overwrite",
        "-t_srs", $CountyConfig.targetSrs,
        "-r", "bilinear",
        "-multi",
        "-wo", "NUM_THREADS=ALL_CPUS",
        "-co", "TILED=YES",
        "-co", "COMPRESS=LZW",
        $SourceVrt,
        $targetTif
    )
    return $targetTif
}

function Invoke-Ctb {
    param(
        [Parameter(Mandatory)] $CountyConfig,
        [Parameter(Mandatory)][string] $RasterPath,
        [Parameter(Mandatory)][string] $OutputPath
    )

    $docker = Get-RequiredCommand -Name "docker"
    if (-not $SkipDockerPull) {
        Invoke-ExternalCommand -FilePath $docker -ArgumentList @("pull", $DockerImage) -TimeoutSec 1800
    }

    $repoForDocker = ($RepoRoot -replace "\\", "/")
    $rasterForDocker = "/data/" + (($RasterPath.Substring($RepoRoot.Length).TrimStart("\") -replace "\\", "/"))
    $outputForDocker = "/data/" + (($OutputPath.Substring($RepoRoot.Length).TrimStart("\") -replace "\\", "/"))

    Invoke-ExternalCommand -FilePath $docker -ArgumentList @(
        "run", "--rm",
        "-v", "${repoForDocker}:/data",
        $DockerImage,
        "ctb-tile", "-f", "Mesh", "-p", "geodetic", "-C",
        "-o", $outputForDocker,
        $rasterForDocker
    )

    Invoke-ExternalCommand -FilePath $docker -ArgumentList @(
        "run", "--rm",
        "-v", "${repoForDocker}:/data",
        $DockerImage,
        "ctb-tile", "-f", "Mesh", "-p", "geodetic", "-C", "-l",
        "-o", $outputForDocker,
        $rasterForDocker
    )
}

function Test-TerrainOutput {
    param(
        [Parameter(Mandatory)] $CountyConfig,
        [Parameter(Mandatory)][string] $OutputPath
    )

    $layerJson = Join-Path $OutputPath "layer.json"
    if (-not (Test-Path -LiteralPath $layerJson)) {
        throw "缺少 layer.json：$layerJson"
    }

    $terrainCount = @(Get-ChildItem -LiteralPath $OutputPath -Recurse -File -Filter "*.terrain" -ErrorAction SilentlyContinue).Count
    if ($terrainCount -lt 1) {
        throw "沒有產出 .terrain：$OutputPath"
    }

    Write-Log "$($CountyConfig.name) terrain 驗證完成：$terrainCount tiles"
}

function Invoke-CountyBuild {
    param([Parameter(Mandatory)] $CountyConfig)

    $remoteInfo = Get-RemoteFileInfo -CountyConfig $CountyConfig
    Write-Log "$($CountyConfig.name) TGOS HEAD：status=$($remoteInfo.StatusCode), bytes=$($remoteInfo.Bytes), modified=$($remoteInfo.LastModified)"

    if ($ValidateOnly) {
        return
    }

    $rawPath = Join-Path $RepoRoot "data/raw/$($CountyConfig.id)"
    $workPath = Join-Path $RepoRoot "data/work/$($CountyConfig.id)"
    $outputPath = Join-Path $RepoRoot $CountyConfig.outputDir
    $zipPath = Join-Path $rawPath $CountyConfig.zipName
    $extractPath = Join-Path $rawPath "extract"

    New-Directory -Path $rawPath
    New-Directory -Path $workPath
    New-Directory -Path $outputPath

    if (-not $SkipDownload) {
        $needsDownload = $true
        if (Test-Path -LiteralPath $zipPath) {
            $localSize = (Get-Item -LiteralPath $zipPath).Length
            $needsDownload = ($remoteInfo.Bytes -gt 0 -and $localSize -ne $remoteInfo.Bytes)
            if (-not $needsDownload) {
                Write-Log "來源 zip 已存在且大小相符：$zipPath"
            }
        }
        if ($needsDownload) {
            Save-FileWithRetry -Url $CountyConfig.url -TargetPath $zipPath
        }
    }

    if (-not (Test-Path -LiteralPath $zipPath)) {
        throw "找不到來源 zip，請先下載或取消 -SkipDownload：$zipPath"
    }

    if ((Test-Path -LiteralPath $extractPath) -and $ForceRebuild) {
        Remove-Item -LiteralPath $extractPath -Recurse -Force
    }
    if (-not (Test-Path -LiteralPath $extractPath)) {
        New-Directory -Path $extractPath
        Write-Log "解壓縮來源 zip：$zipPath"
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force
    }

    $sourceFiles = Get-SourceFiles -RawPath $extractPath
    if ($sourceFiles.Count -lt 1) {
        throw "解壓後找不到 DEM raster / grid 檔：$extractPath"
    }
    Write-Log "$($CountyConfig.name) 找到 $($sourceFiles.Count) 個 DEM 來源檔"

    $sourceVrt = Build-SourceVrt -CountyConfig $CountyConfig -SourceFiles $sourceFiles -WorkPath $workPath
    $epsg4326Raster = Build-Epsg4326Raster -CountyConfig $CountyConfig -SourceVrt $sourceVrt -WorkPath $workPath

    if ($ForceRebuild -and (Test-Path -LiteralPath $outputPath)) {
        Remove-Item -LiteralPath $outputPath -Recurse -Force
        New-Directory -Path $outputPath
    }

    Invoke-Ctb -CountyConfig $CountyConfig -RasterPath $epsg4326Raster -OutputPath $outputPath
    Normalize-TerrainTiles -OutputPath $outputPath
    Test-TerrainOutput -CountyConfig $CountyConfig -OutputPath $outputPath
    Add-HistoryEntry -CountyConfig $CountyConfig -Status "SUCCESS" -Message "terrain 產製完成" -RemoteInfo $remoteInfo
}

function Main {
    New-Directory -Path $LogDir
    Write-Log "開始 terrain pipeline，CTB=$DockerImage，ctb=$CtbCommandText"

    $required = @("gdalinfo", "gdalbuildvrt", "gdalwarp", "gdal_translate")
    foreach ($tool in $required) {
        $path = Get-RequiredCommand -Name $tool
        Write-Log "工具確認：$tool => $path"
    }

    $dockerText = Get-DockerVersionText
    Write-Log "Docker 檢查：$dockerText"
    $dockerMissing = ($dockerText -eq "docker unavailable")

    if (-not $ValidateOnly) {
        Get-RequiredCommand -Name "docker" | Out-Null
    }

    $counties = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $selected = if ($All -or -not $County -or $County.Count -eq 0) {
        @($counties)
    } else {
        @($counties | Where-Object { $County -contains $_.id })
    }

    foreach ($item in $selected) {
        try {
            Invoke-CountyBuild -CountyConfig $item
        } catch {
            if (-not $ValidateOnly) {
                Add-HistoryEntry -CountyConfig $item -Status "FAILED" -Message $_.Exception.Message -RemoteInfo $null
            }
            throw
        }
    }

    if ($ValidateOnly -and $dockerMissing) {
        throw "TGOS 來源檢查完成，但目前找不到 docker，請先安裝 Docker Desktop 後再跑正式產製。"
    }

    Write-Log "terrain pipeline 結束"
}

Main
