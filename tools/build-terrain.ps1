#requires -Version 7.0
[CmdletBinding()]
param(
    [string[]] $County,

    [switch] $All,
    [switch] $ValidateOnly,
    [switch] $SkipDownload,
    [switch] $SkipDockerPull,
    [switch] $ForceRebuild,
    [switch] $SkipFillNoData,

    [string] $DockerImage = "ghcr.io/tum-gis/ctb-quantized-mesh:latest",
    [int] $CommandTimeoutSec = 7200,
    [int] $DownloadRetry = 3,
    [int] $FillDistancePixels = 5
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
    Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8
    Write-Host $line
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
        [int] $TimeoutSec = $CommandTimeoutSec,
        [string] $ProgressMessage = "",
        [int] $HeartbeatSec = 30
    )

    if ($ProgressMessage) {
        Write-Log "$ProgressMessage 開始"
    }
    Write-Log ("[CMD] {0} {1}" -f $FilePath, ($ArgumentList -join " "))

    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()
    $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -NoNewWindow -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $lastHeartbeatSec = 0

    while (-not $process.HasExited) {
        Start-Sleep -Seconds 5
        if ($ProgressMessage -and $HeartbeatSec -gt 0 -and $timer.Elapsed.TotalSeconds -ge ($lastHeartbeatSec + $HeartbeatSec)) {
            $lastHeartbeatSec = [int]$timer.Elapsed.TotalSeconds
            Write-Log ("{0} 指令執行中 {1:n0} 秒..." -f $ProgressMessage, $timer.Elapsed.TotalSeconds)
        }
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
    if ($ProgressMessage) {
        Write-Log ("{0} 完成，耗時 {1:n0} 秒" -f $ProgressMessage, $timer.Elapsed.TotalSeconds)
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

function Assert-DockerDaemon {
    $docker = Get-RequiredCommand -Name "docker"
    try {
        Write-Log "Docker daemon 檢查：docker version"
        Invoke-ExternalCommand -FilePath $docker -ArgumentList @("version") -TimeoutSec 30 -ProgressMessage "Docker daemon 檢查" -HeartbeatSec 0
    } catch {
        throw "Docker Desktop daemon 尚未啟動，請先啟動 Docker Desktop，等 engine running 後重跑。原始錯誤：$($_.Exception.Message)"
    }
}

function Get-GdalPythonCommand {
    $gdalInfo = Get-RequiredCommand -Name "gdalinfo"
    $gdalDir = Split-Path -Parent $gdalInfo
    $ms4wRoot = Split-Path -Parent $gdalDir
    $ms4wPython = Join-Path (Join-Path $ms4wRoot "python") "python.exe"

    if (Test-Path -LiteralPath $ms4wPython) {
        return $ms4wPython
    }

    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        return $python.Source
    }

    throw "找不到可執行的 Python，無法執行 GDAL FillNodata"
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
    $gzTotal = @($gzFiles).Count
    $gzIndex = 0
    foreach ($gz in $gzFiles) {
        $gzIndex++
        $target = $gz.FullName -replace "\.gz$", ""
        Write-Log ("[8/8] terrain.gz 解壓 [{0}/{1}] {2}" -f $gzIndex, $gzTotal, $gz.FullName)
        Expand-GZipFile -SourcePath $gz.FullName -TargetPath $target
        Remove-Item -LiteralPath $gz.FullName -Force
    }

    $terrainFiles = Get-ChildItem -LiteralPath $OutputPath -Recurse -File -Filter "*.terrain" -ErrorAction SilentlyContinue
    $terrainTotal = @($terrainFiles).Count
    $terrainIndex = 0
    foreach ($terrain in $terrainFiles) {
        $terrainIndex++
        if (Test-GZipFile -Path $terrain.FullName) {
            $tmp = "$($terrain.FullName).tmp"
            Write-Log ("[8/8] gzip 內容正規化 [{0}/{1}] {2}" -f $terrainIndex, $terrainTotal, $terrain.FullName)
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

function Get-MinPositiveStep {
    param(
        [Parameter(Mandatory)][int[]] $Values,
        [int] $DefaultStep = 20
    )

    $sortedValues = @($Values | Sort-Object -Unique)
    $step = $null
    for ($i = 1; $i -lt $sortedValues.Count; $i++) {
        $diff = $sortedValues[$i] - $sortedValues[$i - 1]
        if ($diff -gt 0 -and ($null -eq $step -or $diff -lt $step)) {
            $step = $diff
        }
    }

    if ($null -eq $step) {
        return $DefaultStep
    }
    return $step
}

function Convert-SparseXyzToCompleteXyz {
    param(
        [Parameter(Mandatory)][string] $SourcePath,
        [Parameter(Mandatory)][string] $TargetPath,
        [string] $NodataValue = "-32768"
    )

    $points = [System.Collections.Generic.Dictionary[string, string]]::new()
    $xValues = [System.Collections.Generic.HashSet[int]]::new()
    $yValues = [System.Collections.Generic.HashSet[int]]::new()

    foreach ($line in Get-Content -LiteralPath $SourcePath) {
        $trimmed = $line.Trim()
        if (-not $trimmed) {
            continue
        }

        $parts = $trimmed -split "\s+"
        if ($parts.Count -lt 3) {
            continue
        }

        $x = [int]$parts[0]
        $y = [int]$parts[1]
        $z = $parts[2]
        $points["$x,$y"] = $z
        [void]$xValues.Add($x)
        [void]$yValues.Add($y)
    }

    if ($points.Count -lt 1) {
        throw "稀疏 XYZ 沒有可用點：$SourcePath"
    }

    $minX = [int](($xValues | Measure-Object -Minimum).Minimum)
    $maxX = [int](($xValues | Measure-Object -Maximum).Maximum)
    $minY = [int](($yValues | Measure-Object -Minimum).Minimum)
    $maxY = [int](($yValues | Measure-Object -Maximum).Maximum)
    $stepX = Get-MinPositiveStep -Values @($xValues)
    $stepY = Get-MinPositiveStep -Values @($yValues)

    New-Directory -Path (Split-Path -Parent $TargetPath)
    Write-Log "補齊稀疏 XYZ：$SourcePath => $TargetPath"

    $writer = [System.IO.StreamWriter]::new($TargetPath, $false, [System.Text.UTF8Encoding]::new($false))
    try {
        for ($y = $minY; $y -le $maxY; $y += $stepY) {
            for ($x = $minX; $x -le $maxX; $x += $stepX) {
                $key = "$x,$y"
                $z = if ($points.ContainsKey($key)) { $points[$key] } else { $NodataValue }
                $writer.WriteLine("$x $y $z")
            }
        }
    } finally {
        $writer.Dispose()
    }
}

function Test-PositiveNsResolution {
    param([Parameter(Mandatory)] $SourceFile)

    $gdalInfo = Get-RequiredCommand -Name "gdalinfo"
    $infoText = (& $gdalInfo $SourceFile.FullName 2>&1) -join "`n"
    $pixelSizeMatch = [regex]::Match($infoText, "Pixel Size = \(\s*(?<x>[-0-9.]+)\s*,\s*(?<y>[-0-9.]+)\s*\)")
    if (-not $pixelSizeMatch.Success) {
        return $false
    }

    $pixelSizeY = [double]::Parse($pixelSizeMatch.Groups["y"].Value, [System.Globalization.CultureInfo]::InvariantCulture)
    return ($pixelSizeY -gt 0)
}

function Build-SourceVrt {
    param(
        [Parameter(Mandatory)] $CountyConfig,
        [Parameter(Mandatory)][object[]] $SourceFiles,
        [Parameter(Mandatory)][string] $WorkPath
    )

    $gdalBuildVrt = Get-RequiredCommand -Name "gdalbuildvrt"
    $gdalWarp = Get-RequiredCommand -Name "gdalwarp"
    $sourceList = Join-Path $WorkPath "$($CountyConfig.id)-sources.txt"
    $sourceVrt = Join-Path $WorkPath "$($CountyConfig.id)-source.vrt"

    $SourceFiles.FullName | Set-Content -LiteralPath $sourceList -Encoding utf8

    $firstSource = @($SourceFiles | Select-Object -First 1)[0]
    if (Test-PositiveNsResolution -SourceFile $firstSource) {
        Write-Log "[5/8] $($CountyConfig.name) 偵測到 positive NS resolution，跳過直接 VRT，改用 gdalwarp 逐檔轉 northup GeoTIFF"
    } else {
        try {
            Invoke-ExternalCommand -FilePath $gdalBuildVrt -ArgumentList @("-overwrite", "-a_srs", $CountyConfig.sourceSrs, "-input_file_list", $sourceList, $sourceVrt) -ProgressMessage "[5/8] $($CountyConfig.name) gdalbuildvrt 直接建立來源 VRT"
            return $sourceVrt
        } catch {
            Write-Log "[5/8] $($CountyConfig.name) 直接建立 VRT 失敗，可能是 positive NS resolution，改用 gdalwarp 逐檔轉 northup GeoTIFF：$($_.Exception.Message)"
        }
    }

    $rasterizedPath = Join-Path $WorkPath "northup"
    New-Directory -Path $rasterizedPath
    $converted = @()
    $sourceTotal = @($SourceFiles).Count
    $sourceIndex = 0

    foreach ($source in $SourceFiles) {
        $sourceIndex++
        $progressText = "[5/8] gdalwarp [{0}/{1}] {2}" -f $sourceIndex, $sourceTotal, $source.Name
        $target = Join-Path $rasterizedPath "$($source.BaseName).tif"
        if ((Test-Path -LiteralPath $target) -and -not $ForceRebuild) {
            Write-Log "$progressText GeoTIFF 已存在，跳過轉檔：$target"
            $converted += Get-Item -LiteralPath $target
            continue
        }
        if ((Test-Path -LiteralPath $target) -and $ForceRebuild) {
            Remove-Item -LiteralPath $target -Force
        }
        Write-Log $progressText
        try {
            Invoke-ExternalCommand -FilePath $gdalWarp -ArgumentList @(
                "-overwrite",
                "-s_srs", $CountyConfig.sourceSrs,
                "-t_srs", $CountyConfig.sourceSrs,
                "-r", "near",
                "-srcnodata", "-32768", "-dstnodata", "-32768",
                "-of", "GTiff",
                "-co", "TILED=YES",
                "-co", "COMPRESS=LZW",
                $source.FullName,
                $target
            )
        } catch {
            if (Test-Path -LiteralPath $target) {
                Remove-Item -LiteralPath $target -Force
            }
            $completeXyz = Join-Path $rasterizedPath "$($source.BaseName)-complete.xyz"
            Write-Log "$progressText 直接轉檔失敗，補齊稀疏 XYZ 後重試：$($_.Exception.Message)"
            Convert-SparseXyzToCompleteXyz -SourcePath $source.FullName -TargetPath $completeXyz
            Invoke-ExternalCommand -FilePath $gdalWarp -ArgumentList @(
                "-overwrite",
                "-s_srs", $CountyConfig.sourceSrs,
                "-t_srs", $CountyConfig.sourceSrs,
                "-r", "near",
                "-srcnodata", "-32768", "-dstnodata", "-32768",
                "-of", "GTiff",
                "-co", "TILED=YES",
                "-co", "COMPRESS=LZW",
                $completeXyz,
                $target
            )
        }
        $converted += Get-Item -LiteralPath $target
    }

    $convertedList = Join-Path $WorkPath "$($CountyConfig.id)-converted-sources.txt"
    $converted.FullName | Set-Content -LiteralPath $convertedList -Encoding utf8
    Invoke-ExternalCommand -FilePath $gdalBuildVrt -ArgumentList @("-overwrite", "-a_srs", $CountyConfig.sourceSrs, "-input_file_list", $convertedList, $sourceVrt) -ProgressMessage "[5/8] $($CountyConfig.name) gdalbuildvrt 建立轉檔後 VRT"
    return $sourceVrt
}

function Invoke-FillNoData {
    param(
        [Parameter(Mandatory)] $CountyConfig,
        [Parameter(Mandatory)][string] $SourceRaster,
        [Parameter(Mandatory)][string] $WorkPath
    )

    if ($SkipFillNoData -or $FillDistancePixels -le 0) {
        Write-Log "[6/8] $($CountyConfig.name) 跳過 NoData 補洞"
        return $SourceRaster
    }

    $filledRaster = Join-Path $WorkPath "$($CountyConfig.id)-filled.tif"
    if ((Test-Path -LiteralPath $filledRaster) -and -not $ForceRebuild) {
        Write-Log "[6/8] $($CountyConfig.name) 補洞 TIFF 已存在，跳過補洞：$filledRaster"
        return $filledRaster
    }
    if ((Test-Path -LiteralPath $filledRaster) -and $ForceRebuild) {
        Remove-Item -LiteralPath $filledRaster -Force
    }

    $python = Get-GdalPythonCommand
    $fillScript = Join-Path $RepoRoot "tools/fill-nodata.py"
    if (-not (Test-Path -LiteralPath $fillScript)) {
        throw "找不到 NoData 補洞腳本：$fillScript"
    }

    Invoke-ExternalCommand -FilePath $python -ArgumentList @(
        $fillScript,
        "--source", $SourceRaster,
        "--target", $filledRaster,
        "--max-distance", ([string]$FillDistancePixels),
        "--nodata", "-32768"
    ) -ProgressMessage "[6/8] $($CountyConfig.name) 補齊小範圍 NoData"

    return $filledRaster
}

function Build-Epsg4326Raster {
    param(
        [Parameter(Mandatory)] $CountyConfig,
        [Parameter(Mandatory)][string] $SourceRaster,
        [Parameter(Mandatory)][string] $WorkPath
    )

    $gdalWarp = Get-RequiredCommand -Name "gdalwarp"
    $targetTif = Join-Path $WorkPath "$($CountyConfig.id)-4326.tif"
    if ((Test-Path -LiteralPath $targetTif) -and -not $ForceRebuild) {
        Write-Log "[6/8] $($CountyConfig.name) EPSG:4326 TIFF 已存在，跳過重投影：$targetTif"
        return $targetTif
    }
    Invoke-ExternalCommand -FilePath $gdalWarp -ArgumentList @(
        "-overwrite",
        "-t_srs", $CountyConfig.targetSrs,
        "-r", "bilinear",
        "-srcnodata", "-32768",
        "-dstnodata", "-32768",
        "-multi",
        "-wo", "NUM_THREADS=ALL_CPUS",
        "-co", "TILED=YES",
        "-co", "COMPRESS=LZW",
        $SourceRaster,
        $targetTif
    ) -ProgressMessage "[6/8] $($CountyConfig.name) gdalwarp EPSG:4326"
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
        Invoke-ExternalCommand -FilePath $docker -ArgumentList @("pull", $DockerImage) -TimeoutSec 1800 -ProgressMessage "[7/8] Docker pull $DockerImage"
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
    ) -ProgressMessage "[7/8] $($CountyConfig.name) ctb-tile mesh"

    Invoke-ExternalCommand -FilePath $docker -ArgumentList @(
        "run", "--rm",
        "-v", "${repoForDocker}:/data",
        $DockerImage,
        "ctb-tile", "-f", "Mesh", "-p", "geodetic", "-C", "-l",
        "-o", $outputForDocker,
        $rasterForDocker
    ) -ProgressMessage "[7/8] $($CountyConfig.name) ctb-tile layer.json"
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

    Write-Log "[1/8] $($CountyConfig.name) 檢查 TGOS 來源"
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
            Write-Log "[2/8] $($CountyConfig.name) 下載來源 zip"
            Save-FileWithRetry -Url $CountyConfig.url -TargetPath $zipPath
        } else {
            Write-Log "[2/8] $($CountyConfig.name) 來源 zip 已可用"
        }
    } else {
        Write-Log "[2/8] $($CountyConfig.name) 略過下載"
    }

    if (-not (Test-Path -LiteralPath $zipPath)) {
        throw "找不到來源 zip，請先下載或取消 -SkipDownload：$zipPath"
    }

    if ((Test-Path -LiteralPath $extractPath) -and $ForceRebuild) {
        Remove-Item -LiteralPath $extractPath -Recurse -Force
    }
    if (-not (Test-Path -LiteralPath $extractPath)) {
        New-Directory -Path $extractPath
        Write-Log "[3/8] $($CountyConfig.name) 解壓縮來源 zip：$zipPath"
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force
    } else {
        Write-Log "[3/8] $($CountyConfig.name) 解壓目錄已存在，略過解壓"
    }

    Write-Log "[4/8] $($CountyConfig.name) 掃描 DEM 來源檔"
    $sourceFiles = Get-SourceFiles -RawPath $extractPath
    if ($sourceFiles.Count -lt 1) {
        throw "解壓後找不到 DEM raster / grid 檔：$extractPath"
    }
    Write-Log "[4/8] $($CountyConfig.name) 找到 $($sourceFiles.Count) 個 DEM 來源檔"

    $sourceVrt = Build-SourceVrt -CountyConfig $CountyConfig -SourceFiles $sourceFiles -WorkPath $workPath
    $sourceForWarp = Invoke-FillNoData -CountyConfig $CountyConfig -SourceRaster $sourceVrt -WorkPath $workPath
    $epsg4326Raster = Build-Epsg4326Raster -CountyConfig $CountyConfig -SourceRaster $sourceForWarp -WorkPath $workPath

    if ($ForceRebuild -and (Test-Path -LiteralPath $outputPath)) {
        Remove-Item -LiteralPath $outputPath -Recurse -Force
        New-Directory -Path $outputPath
    }

    Invoke-Ctb -CountyConfig $CountyConfig -RasterPath $epsg4326Raster -OutputPath $outputPath
    Write-Log "[8/8] $($CountyConfig.name) 正規化 terrain 檔案"
    Normalize-TerrainTiles -OutputPath $outputPath
    Test-TerrainOutput -CountyConfig $CountyConfig -OutputPath $outputPath
    Add-HistoryEntry -CountyConfig $CountyConfig -Status "SUCCESS" -Message "terrain 產製完成" -RemoteInfo $remoteInfo
}

function Main {
    New-Directory -Path $LogDir
    Write-Log "開始 terrain pipeline，CTB=$DockerImage，ctb=$CtbCommandText"

    $counties = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $knownCountyIds = @($counties | ForEach-Object { $_.id })
    if ($County -and $County.Count -gt 0) {
        $unknownCountyIds = @($County | Where-Object { $knownCountyIds -notcontains $_ })
        if ($unknownCountyIds.Count -gt 0) {
            throw "未知縣市 id：$($unknownCountyIds -join ', ')；可用：$($knownCountyIds -join ', ')"
        }
    }

    $required = @("gdalinfo", "gdalbuildvrt", "gdalwarp")
    foreach ($tool in $required) {
        $path = Get-RequiredCommand -Name $tool
        Write-Log "工具確認：$tool => $path"
    }

    if (-not $SkipFillNoData -and $FillDistancePixels -gt 0) {
        $gdalPython = Get-GdalPythonCommand
        Write-Log "工具確認：GDAL Python => $gdalPython"
    }

    $dockerText = Get-DockerVersionText
    Write-Log "Docker 檢查：$dockerText"
    $dockerMissing = ($dockerText -eq "docker unavailable")

    if (-not $ValidateOnly) {
        Assert-DockerDaemon
    }

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
