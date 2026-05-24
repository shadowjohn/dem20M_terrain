#requires -Version 7.0
[CmdletBinding()]
param(
    [string[]] $County,

    [switch] $All,
    [switch] $AllWithTaiwan,
    [switch] $FromGrd,
    [switch] $ValidateOnly,
    [switch] $SkipDownload,
    [switch] $SkipDockerPull,
    [switch] $SkipUnifiedTaiwanSource,
    [switch] $UseMoiForCounty,
    [switch] $ForceRebuild,
    [switch] $SkipFillNoData,

    [string] $DockerImage = "ghcr.io/tum-gis/ctb-quantized-mesh:latest",
    [int] $CommandTimeoutSec = 7200,
    [int] $PollIntervalMs = 100,
    [int] $NormalizeProgressEvery = 100,
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
$TaiwanProviderId = "all_taiwan"
$MainTaiwanProviderId = "taiwan"
$FromGrdTaiwanProviderId = "taiwan_from_grd"
$FromGrdAllTaiwanProviderId = "all_taiwan_from_grd"
$UnifiedTaiwanSourceId = "taiwan_unified"
$UnifiedTaiwanSourceConfig = [pscustomobject]@{
    id = $UnifiedTaiwanSourceId
    providerId = ""
    name = "不分幅_全台20MDEM(2025)"
    zipName = "taiwan_unified-20mdem-2025.zip"
    url = "https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/528530be-0710-431e-954e-2f2f5e98b0c5/不分幅_全台20MDEM(2025).zip"
    sourceSrs = "EPSG:3826"
    targetSrs = "EPSG:4326"
    outputDir = "output/$UnifiedTaiwanSourceId"
    expectedBytes = 268985841
    sourceNoData = "-32767"
    buildKind = "all_taiwan_unified_source"
}
$UnifiedOffshoreSourceConfigs = @(
    [pscustomobject]@{
        id = "penghu_unified"
        providerId = "penghu"
        name = "不分幅_澎湖20MDEM(2025)"
        zipName = "penghu_unified-20mdem-2025.zip"
        url = "https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/47910269-7315-4cd2-9101-7cdf524b47f5/不分幅_澎湖20MDEM(2025).zip"
        sourceSrs = "EPSG:3825"
        targetSrs = "EPSG:4326"
        outputDir = "output/penghu"
        expectedBytes = 1268059
        sourceNoData = "-32767"
        buildKind = "county_offshore_unified"
    },
    [pscustomobject]@{
        id = "kinmen_unified"
        providerId = "kinmen"
        name = "不分幅_金門20MDEM(2025)"
        zipName = "kinmen_unified-20mdem-2025.zip"
        url = "https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/0e018335-80f1-4489-990c-ecf2bef1a9b6/不分幅_金門20MDEM(2025).zip"
        sourceSrs = "EPSG:3825"
        targetSrs = "EPSG:4326"
        outputDir = "output/kinmen"
        expectedBytes = 1647039
        sourceNoData = "-32767"
        buildKind = "county_offshore_unified"
    }
)
$UnifiedTaiwanExcludedCountyIds = @($UnifiedOffshoreSourceConfigs | ForEach-Object { $_.providerId })
$CountyGapFillSourceConfigs = @(
    [pscustomobject]@{
        id = "miaoli_moi"
        providerId = "miaoli"
        name = "苗栗縣內政部DEM補洞來源"
        zipName = "miaoli-dem-moi.zip"
        url = "https://www.tgos.tw/MDE/VirtualDir_TC/Product/700a0fca-1778-4da9-a8f0-b1d164f80923/分幅_苗栗縣DEM.zip"
        sourceSrs = "EPSG:3826"
        targetSrs = "EPSG:4326"
        outputDir = "output/miaoli"
        expectedBytes = 25052979
        buildKind = "county_gap_fill_source"
    },
    [pscustomobject]@{
        id = "hsinchu_county_moi"
        providerId = "hsinchu_county"
        name = "新竹縣內政部DEM補洞來源"
        zipName = "hsinchu_county-dem-moi.zip"
        url = "https://www.tgos.tw/MDE/VirtualDir_TC/Product/ed20601a-24dd-48f9-a4c0-1659aaccda28/分幅_新竹縣DEM.zip"
        sourceSrs = "EPSG:3826"
        targetSrs = "EPSG:4326"
        outputDir = "output/hsinchu_county"
        expectedBytes = 20692559
        buildKind = "county_gap_fill_source"
    }
)

function Format-InvariantNumber {
    param([Parameter(Mandatory)][double] $Value)
    return $Value.ToString("0.########", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-ManifestPathText {
    param([Parameter(Mandatory)][string] $Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $rootPath = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd("\")
    if ($fullPath.StartsWith($rootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return (($fullPath.Substring($rootPath.Length).TrimStart("\") -replace "\\", "/"))
    }
    return ([System.IO.Path]::GetFileName($Path))
}

function Get-SourceRawId {
    param([Parameter(Mandatory)] $SourceConfig)

    if ($SourceConfig.PSObject.Properties.Name -contains "rawId" -and $SourceConfig.rawId) {
        return [string]$SourceConfig.rawId
    }
    return [string]$SourceConfig.id
}

function Get-MoiFullSourceModeText {
    param([string[]] $CountyNames = @())

    $names = @($CountyNames | Where-Object { $_ } | Sort-Object -Unique)
    if ($names.Count -lt 1) {
        return "內政部完整DEM補洞"
    }
    return "內政部完整DEM補洞($($names -join '、'))"
}

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
    $pollMs = [Math]::Max(50, $PollIntervalMs)

    # 大量短 GDAL 指令時，固定 sleep 會直接變成瓶頸；我改用短輪詢保留 heartbeat。
    while (-not $process.WaitForExit($pollMs)) {
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
    $process.WaitForExit()

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
    if ($gzTotal -gt 0) {
        Write-Log "[8/8] terrain.gz 解壓開始：$gzTotal files"
    }
    foreach ($gz in $gzFiles) {
        $gzIndex++
        $target = $gz.FullName -replace "\.gz$", ""
        if (($gzIndex -eq 1) -or ($gzIndex -eq $gzTotal) -or (($gzIndex % $NormalizeProgressEvery) -eq 0)) {
            Write-Log ("[8/8] terrain.gz 解壓進度 {0}/{1}" -f $gzIndex, $gzTotal)
        }
        Expand-GZipFile -SourcePath $gz.FullName -TargetPath $target
        Remove-Item -LiteralPath $gz.FullName -Force
    }

    $terrainFiles = Get-ChildItem -LiteralPath $OutputPath -Recurse -File -Filter "*.terrain" -ErrorAction SilentlyContinue
    $terrainTotal = @($terrainFiles).Count
    $terrainIndex = 0
    $normalizedCount = 0
    if ($terrainTotal -gt 0) {
        Write-Log "[8/8] gzip 內容檢查開始：$terrainTotal files"
    }
    foreach ($terrain in $terrainFiles) {
        $terrainIndex++
        if (($terrainIndex -eq 1) -or ($terrainIndex -eq $terrainTotal) -or (($terrainIndex % $NormalizeProgressEvery) -eq 0)) {
            Write-Log ("[8/8] gzip 內容正規化進度 {0}/{1}" -f $terrainIndex, $terrainTotal)
        }
        if (Test-GZipFile -Path $terrain.FullName) {
            $tmp = "$($terrain.FullName).tmp"
            Expand-GZipFile -SourcePath $terrain.FullName -TargetPath $tmp
            Move-Item -LiteralPath $tmp -Destination $terrain.FullName -Force
            $normalizedCount++
        }
    }
    Write-Log "[8/8] gzip 內容正規化完成：$normalizedCount files"
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

function Get-CountyRasterPath {
    param([Parameter(Mandatory)] $CountyConfig)
    return (Join-Path $RepoRoot "data/work/$($CountyConfig.id)/$($CountyConfig.id)-4326.tif")
}

function Normalize-CountyIds {
    param([string[]] $CountyIds)

    return @(
        $CountyIds |
            ForEach-Object { $_ -split "," } |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    )
}

function Get-OffshoreUnifiedSourceConfig {
    param([Parameter(Mandatory)][string] $CountyId)
    return @($UnifiedOffshoreSourceConfigs | Where-Object { $_.providerId -eq $CountyId } | Select-Object -First 1)[0]
}

function Get-CountyGapFillSourceConfig {
    param([Parameter(Mandatory)][string] $CountyId)
    return @($CountyGapFillSourceConfigs | Where-Object { $_.providerId -eq $CountyId } | Select-Object -First 1)[0]
}

function New-ProviderConfigFromSource {
    param(
        [Parameter(Mandatory)] $CountyConfig,
        [Parameter(Mandatory)] $SourceConfig
    )

    return [pscustomobject]@{
        id = $CountyConfig.id
        name = $CountyConfig.name
        zipName = $SourceConfig.zipName
        url = $SourceConfig.url
        sourceSrs = $SourceConfig.sourceSrs
        targetSrs = $CountyConfig.targetSrs
        outputDir = $CountyConfig.outputDir
        expectedBytes = $SourceConfig.expectedBytes
    }
}

function Get-DockerReadableRasterPath {
    param([Parameter(Mandatory)][string] $RasterPath)

    if ([System.IO.Path]::GetExtension($RasterPath) -ne ".vrt") {
        return $RasterPath
    }

    $dockerVrtPath = Join-Path (Split-Path -Parent $RasterPath) "$([System.IO.Path]::GetFileNameWithoutExtension($RasterPath))-docker.vrt"
    $text = Get-Content -LiteralPath $RasterPath -Raw
    $text = $text.Replace($RepoRoot, "/data").Replace("\", "/")
    $text | Set-Content -LiteralPath $dockerVrtPath -Encoding utf8
    return $dockerVrtPath
}

function Get-ProviderOutputDir {
    param([Parameter(Mandatory)][string] $ProviderId)
    return "output/$ProviderId"
}

function Get-TmpOutputPath {
    param([Parameter(Mandatory)][string] $OutputPath)
    return "$OutputPath.tmp-$RunStamp"
}

function Get-TerrainStats {
    param([Parameter(Mandatory)][string] $OutputPath)

    $terrainFiles = @(Get-ChildItem -LiteralPath $OutputPath -Recurse -File -Filter "*.terrain" -ErrorAction SilentlyContinue)
    $zoomLevels = @(
        $terrainFiles |
            ForEach-Object {
                if ($_.Directory -and $_.Directory.Parent -and $_.Directory.Parent.Name -match "^\d+$") {
                    [int]$_.Directory.Parent.Name
                }
            } |
            Sort-Object -Unique
    )

    return [pscustomobject]@{
        TerrainTileCount = $terrainFiles.Count
        ZoomLevels = $zoomLevels
    }
}

function Test-ExistingTerrainOutput {
    param(
        [Parameter(Mandatory)][string] $OutputPath,
        [int] $MinimumTileCount = 1,
        [string] $BuildKind = ""
    )

    $layerJson = Join-Path $OutputPath "layer.json"
    if (-not (Test-Path -LiteralPath $layerJson)) {
        return $false
    }

    $stats = Get-TerrainStats -OutputPath $OutputPath
    if ($stats.TerrainTileCount -lt $MinimumTileCount) {
        return $false
    }

    if (-not $BuildKind) {
        return $true
    }

    $manifestPath = Join-Path $OutputPath "build-manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        # 舊版縣市 provider 沒有 manifest，我只允許原本 county 流程沿用。
        return ($BuildKind -eq "county")
    }

    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        return ($manifest.buildKind -eq $BuildKind)
    } catch {
        return $false
    }
}

function Get-RasterMetadata {
    param([Parameter(Mandatory)][string] $RasterPath)

    $gdalInfo = Get-RequiredCommand -Name "gdalinfo"
    $jsonText = (& $gdalInfo "-json" $RasterPath 2>&1) -join "`n"
    $info = $jsonText | ConvertFrom-Json -AsHashtable
    $corners = $info["cornerCoordinates"]
    if (-not $corners) {
        throw "gdalinfo 沒有回傳 cornerCoordinates：$RasterPath"
    }

    $points = @($corners["upperLeft"], $corners["lowerLeft"], $corners["lowerRight"], $corners["upperRight"])
    $xs = @($points | ForEach-Object { [double]$_[0] })
    $ys = @($points | ForEach-Object { [double]$_[1] })
    $minX = [Math]::Round([double](($xs | Measure-Object -Minimum).Minimum), 8)
    $maxX = [Math]::Round([double](($xs | Measure-Object -Maximum).Maximum), 8)
    $minY = [Math]::Round([double](($ys | Measure-Object -Minimum).Minimum), 8)
    $maxY = [Math]::Round([double](($ys | Measure-Object -Maximum).Maximum), 8)

    return [pscustomobject]@{
        Path = $RasterPath
        Driver = $info["driverShortName"]
        Size = @($info["size"])
        BBox = @($minX, $minY, $maxX, $maxY)
        PixelSize = @([double]$info["geoTransform"][1], [Math]::Abs([double]$info["geoTransform"][5]))
    }
}

function Build-CompositeRaster {
    param(
        [Parameter(Mandatory)][string] $ProviderName,
        [Parameter(Mandatory)] $SourceRasters,
        [Parameter(Mandatory)][string] $ReferenceRaster,
        [Parameter(Mandatory)][string] $TargetRaster
    )

    $metadata = Get-RasterMetadata -RasterPath $ReferenceRaster
    $bbox = @($metadata.BBox | ForEach-Object { Format-InvariantNumber -Value ([double]$_) })
    $pixelSize = @($metadata.PixelSize | ForEach-Object { Format-InvariantNumber -Value ([double]$_) })
    $gdalWarp = Get-RequiredCommand -Name "gdalwarp"
    $sourcePaths = @($SourceRasters | ForEach-Object { $_.FullName })

    # gdalbuildvrt 不能可靠處理多個上層來源彼此的 NoData 透明覆蓋；用 gdalwarp 先燒成實體 composite。
    $warpArgs = @(
        "-overwrite",
        "-t_srs", "EPSG:4326",
        "-te_srs", "EPSG:4326",
        "-te", $bbox[0], $bbox[1], $bbox[2], $bbox[3],
        "-tr", $pixelSize[0], $pixelSize[1],
        "-r", "bilinear",
        "-srcnodata", "-32768",
        "-dstnodata", "-32768",
        "-multi",
        "-wo", "NUM_THREADS=ALL_CPUS",
        "-co", "TILED=YES",
        "-co", "COMPRESS=LZW"
    ) + $sourcePaths + @($TargetRaster)

    Invoke-ExternalCommand -FilePath $gdalWarp -ArgumentList $warpArgs -ProgressMessage "[6/8] $ProviderName gdalwarp 建立 NoData 透明 composite GeoTIFF"
    return $TargetRaster
}

function Update-LayerJsonBounds {
    param(
        [Parameter(Mandatory)][string] $OutputPath,
        [Parameter(Mandatory)] $RasterMetadata
    )

    $layerJsonPath = Join-Path $OutputPath "layer.json"
    $layer = Get-Content -LiteralPath $layerJsonPath -Raw | ConvertFrom-Json
    $bounds = @($RasterMetadata.BBox)
    if ($layer.PSObject.Properties.Name -contains "bounds") {
        $layer.bounds = $bounds
    } else {
        $layer | Add-Member -MemberType NoteProperty -Name "bounds" -Value $bounds
    }
    $layer | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $layerJsonPath -Encoding utf8
    Write-Log "[8/8] layer.json bounds 已更新：$($bounds -join ', ')"
}

function Write-BuildManifest {
    param(
        [Parameter(Mandatory)] $CountyConfig,
        [Parameter(Mandatory)][string] $OutputPath,
        [Parameter(Mandatory)] $RasterMetadata,
        [string] $BuildKind = "county"
    )

    $stats = Get-TerrainStats -OutputPath $OutputPath
    $manifestPath = Join-Path $OutputPath "build-manifest.json"
    $manifest = [ordered]@{
        "providerId" = $CountyConfig.id
        "name" = $CountyConfig.name
        "buildKind" = $BuildKind
        "builtAt" = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssK")
        "outputDir" = $CountyConfig.outputDir
        "sourceUrl" = $CountyConfig.url
        "sourceSrs" = $CountyConfig.sourceSrs
        "targetSrs" = $CountyConfig.targetSrs
        "rasterPath" = (Get-ManifestPathText -Path $RasterMetadata.Path)
        "rasterDriver" = $RasterMetadata.Driver
        "rasterSize" = $RasterMetadata.Size
        "bbox" = $RasterMetadata.BBox
        "terrainTileCount" = $stats.TerrainTileCount
        "zoomLevels" = $stats.ZoomLevels
        "dockerImage" = $DockerImage
        "ctbCommand" = $CtbCommandText
        "fillDistancePixels" = if ($SkipFillNoData) { 0 } else { $FillDistancePixels }
    }

    $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding utf8
    Write-Log "[8/8] build manifest 已寫入：$manifestPath"
}

function Publish-TerrainOutput {
    param(
        [Parameter(Mandatory)][string] $TmpOutputPath,
        [Parameter(Mandatory)][string] $OutputPath
    )

    if (Test-Path -LiteralPath $OutputPath) {
        Remove-Item -LiteralPath $OutputPath -Recurse -Force
    }
    Move-Item -LiteralPath $tmpOutputPath -Destination $outputPath
    Write-Log "[8/8] terrain output 已發布：$OutputPath"
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

    $dockerRasterPath = Get-DockerReadableRasterPath -RasterPath $RasterPath
    $repoForDocker = ($RepoRoot -replace "\\", "/")
    $rasterForDocker = "/data/" + (($dockerRasterPath.Substring($RepoRoot.Length).TrimStart("\") -replace "\\", "/"))
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

function Build-TerrainProvider {
    param(
        [Parameter(Mandatory)] $ProviderConfig,
        [Parameter(Mandatory)][string] $RasterPath,
        [string] $BuildKind = "county"
    )

    $outputPath = Join-Path $RepoRoot $ProviderConfig.outputDir
    $rasterMetadata = Get-RasterMetadata -RasterPath $RasterPath

    if ((Test-ExistingTerrainOutput -OutputPath $outputPath -BuildKind $BuildKind) -and -not $ForceRebuild) {
        Write-Log "$($ProviderConfig.name) terrain output 已存在，跳過 CTB：$outputPath"
        Update-LayerJsonBounds -OutputPath $outputPath -RasterMetadata $rasterMetadata
        Write-BuildManifest -CountyConfig $ProviderConfig -OutputPath $outputPath -RasterMetadata $rasterMetadata -BuildKind $BuildKind
        Test-TerrainOutput -CountyConfig $ProviderConfig -OutputPath $outputPath
        Write-Log "$($ProviderConfig.name) terrain output 已存在，跳過重建"
        return
    }

    $tmpOutputPath = Get-TmpOutputPath -OutputPath $outputPath
    if (Test-Path -LiteralPath $tmpOutputPath) {
        Remove-Item -LiteralPath $tmpOutputPath -Recurse -Force
    }
    New-Directory -Path $tmpOutputPath

    try {
        Invoke-Ctb -CountyConfig $ProviderConfig -RasterPath $RasterPath -OutputPath $tmpOutputPath
        Write-Log "[8/8] $($ProviderConfig.name) 正規化 terrain 檔案"
        Normalize-TerrainTiles -OutputPath $tmpOutputPath
        Update-LayerJsonBounds -OutputPath $tmpOutputPath -RasterMetadata $rasterMetadata
        Test-TerrainOutput -CountyConfig $ProviderConfig -OutputPath $tmpOutputPath
        Write-BuildManifest -CountyConfig $ProviderConfig -OutputPath $tmpOutputPath -RasterMetadata $rasterMetadata -BuildKind $BuildKind
        Publish-TerrainOutput -TmpOutputPath $tmpOutputPath -OutputPath $outputPath
    } catch {
        if (Test-Path -LiteralPath $tmpOutputPath) {
            Remove-Item -LiteralPath $tmpOutputPath -Recurse -Force
        }
        throw
    }
}

function Invoke-UnifiedGeoTiffSourceBuild {
    param([Parameter(Mandatory)] $SourceConfig)

    Write-Log "[1/8] $($SourceConfig.name) 檢查 TGOS 來源"
    $remoteInfo = Get-RemoteFileInfo -CountyConfig $SourceConfig
    Write-Log "$($SourceConfig.name) TGOS HEAD：status=$($remoteInfo.StatusCode), bytes=$($remoteInfo.Bytes), modified=$($remoteInfo.LastModified)"

    if ($ValidateOnly) {
        return "__validate_$($SourceConfig.id)__"
    }

    $rawId = Get-SourceRawId -SourceConfig $SourceConfig
    $rawPath = Join-Path $RepoRoot "data/raw/$rawId"
    $workPath = Join-Path $RepoRoot "data/work/$($SourceConfig.id)"
    $zipPath = Join-Path $rawPath $SourceConfig.zipName
    $extractPath = Join-Path $rawPath "extract"
    $targetTif = Join-Path $workPath "$($SourceConfig.id)-4326.tif"

    New-Directory -Path $rawPath
    New-Directory -Path $workPath

    if (-not $SkipDownload) {
        $needsDownload = $true
        if (Test-Path -LiteralPath $zipPath) {
            $localSize = (Get-Item -LiteralPath $zipPath).Length
            $needsDownload = ($remoteInfo.Bytes -gt 0 -and $localSize -ne $remoteInfo.Bytes)
            if (-not $needsDownload) {
                Write-Log "$($SourceConfig.name) zip 已存在且大小相符：$zipPath"
            }
        }
        if ($needsDownload) {
            Write-Log "[2/8] 下載 $($SourceConfig.name) zip"
            Save-FileWithRetry -Url $SourceConfig.url -TargetPath $zipPath
        }
    } else {
        Write-Log "[2/8] 略過 $($SourceConfig.name) 下載"
    }

    if (-not (Test-Path -LiteralPath $zipPath)) {
        throw "找不到 $($SourceConfig.name) 來源 zip，請先下載或取消 -SkipDownload：$zipPath"
    }

    if ((Test-Path -LiteralPath $extractPath) -and $ForceRebuild) {
        Remove-Item -LiteralPath $extractPath -Recurse -Force
    }
    if (-not (Test-Path -LiteralPath $extractPath)) {
        New-Directory -Path $extractPath
        Write-Log "[3/8] 解壓縮 $($SourceConfig.name) zip：$zipPath"
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force
    } else {
        Write-Log "[3/8] $($SourceConfig.name) 解壓目錄已存在，略過解壓"
    }

    $sourceTifs = @(Get-ChildItem -LiteralPath $extractPath -Recurse -File -Filter "*.tif" | Sort-Object Length -Descending)
    if ($sourceTifs.Count -lt 1) {
        throw "$($SourceConfig.name) 來源包內找不到 GeoTIFF：$extractPath"
    }

    $sourceNoData = if ($SourceConfig.PSObject.Properties.Name -contains "sourceNoData") { [string]$SourceConfig.sourceNoData } else { "-32767" }
    $gdalWarp = Get-RequiredCommand -Name "gdalwarp"
    $warpedTifs = @()
    foreach ($sourceTif in $sourceTifs) {
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($sourceTif.Name)
        $partTargetTif = if ($sourceTifs.Count -eq 1) {
            $targetTif
        } else {
            Join-Path $workPath "$baseName-4326.tif"
        }

        if ((Test-Path -LiteralPath $partTargetTif) -and -not $ForceRebuild) {
            Write-Log "[6/8] $($SourceConfig.name) EPSG:4326 TIFF 已存在，跳過重投影：$partTargetTif"
            $warpedTifs += (Get-Item -LiteralPath $partTargetTif)
            continue
        }
        if ((Test-Path -LiteralPath $partTargetTif) -and $ForceRebuild) {
            Remove-Item -LiteralPath $partTargetTif -Force
        }

        $warpArgs = @(
            "-overwrite",
            "-t_srs", $SourceConfig.targetSrs,
            "-r", "bilinear",
            "-srcnodata", $sourceNoData,
            "-dstnodata", "-32768",
            "-multi",
            "-wo", "NUM_THREADS=ALL_CPUS",
            "-co", "TILED=YES",
            "-co", "COMPRESS=LZW"
        )
        if ($SourceConfig.sourceSrs) {
            $warpArgs = @("-overwrite", "-s_srs", $SourceConfig.sourceSrs) + $warpArgs[1..($warpArgs.Count - 1)]
        }
        $warpArgs += @($sourceTif.FullName, $partTargetTif)

        Invoke-ExternalCommand -FilePath $gdalWarp -ArgumentList $warpArgs -ProgressMessage "[6/8] $($SourceConfig.name) $($sourceTif.Name) gdalwarp EPSG:4326"
        $warpedTifs += (Get-Item -LiteralPath $partTargetTif)
    }

    if ($warpedTifs.Count -gt 1) {
        $allSourceList = Join-Path $workPath "$($SourceConfig.id)-all-sources.txt"
        $allSourceVrt = Join-Path $workPath "$($SourceConfig.id)-all-4326.vrt"
        $warpedTifs.FullName | Set-Content -LiteralPath $allSourceList -Encoding utf8
        $gdalBuildVrt = Get-RequiredCommand -Name "gdalbuildvrt"
        Invoke-ExternalCommand -FilePath $gdalBuildVrt -ArgumentList @(
            "-overwrite",
            "-a_srs", $SourceConfig.targetSrs,
            "-input_file_list", $allSourceList,
            $allSourceVrt
        ) -ProgressMessage "[5/8] $($SourceConfig.name) gdalbuildvrt 建立多 GeoTIFF VRT"
        return $allSourceVrt
    }

    return $targetTif
}

function Ensure-ZipExtracted {
    param(
        [Parameter(Mandatory)][string] $ZipPath,
        [Parameter(Mandatory)][string] $ExtractPath,
        [Parameter(Mandatory)][string] $Name
    )

    if ((Test-Path -LiteralPath $ExtractPath) -and $ForceRebuild) {
        Remove-Item -LiteralPath $ExtractPath -Recurse -Force
    }
    if (-not (Test-Path -LiteralPath $ExtractPath)) {
        New-Directory -Path $ExtractPath
        Write-Log "[3/8] $Name 解壓縮來源 zip：$ZipPath"
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $ExtractPath -Force
    } else {
        Write-Log "[3/8] $Name 解壓目錄已存在，略過解壓"
    }
}

function Ensure-CountyGapFillZip {
    param([Parameter(Mandatory)] $SourceConfig)

    $rawId = Get-SourceRawId -SourceConfig $SourceConfig
    $rawPath = Join-Path $RepoRoot "data/raw/$rawId"
    $zipPath = Join-Path $rawPath $SourceConfig.zipName
    New-Directory -Path $rawPath

    if (-not $SkipDownload) {
        $needsDownload = $true
        if (Test-Path -LiteralPath $zipPath) {
            $localSize = (Get-Item -LiteralPath $zipPath).Length
            $needsDownload = ($SourceConfig.expectedBytes -gt 0 -and $localSize -ne $SourceConfig.expectedBytes)
            if (-not $needsDownload) {
                Write-Log "$($SourceConfig.name) zip 已存在且大小相符：$zipPath"
            }
        }
        if ($needsDownload) {
            Write-Log "[2/8] 下載 $($SourceConfig.name) zip"
            Save-FileWithRetry -Url $SourceConfig.url -TargetPath $zipPath
        } else {
            Write-Log "[2/8] $($SourceConfig.name) 來源 zip 已可用"
        }
    } else {
        Write-Log "[2/8] $($SourceConfig.name) 略過下載"
    }

    if (-not (Test-Path -LiteralPath $zipPath)) {
        throw "找不到 $($SourceConfig.name) 來源 zip，請先下載或取消 -SkipDownload：$zipPath"
    }
    return $zipPath
}

function Get-MissingGapFillSourceFiles {
    param(
        [Parameter(Mandatory)][object[]] $PrimarySourceFiles,
        [Parameter(Mandatory)][object[]] $FallbackSourceFiles
    )

    $primaryNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($source in $PrimarySourceFiles) {
        [void]$primaryNames.Add($source.Name)
    }

    return @($FallbackSourceFiles | Where-Object { -not $primaryNames.Contains($_.Name) })
}

function Invoke-CountyGapFillSourceBuild {
    param(
        [Parameter(Mandatory)] $CountyConfig,
        [Parameter(Mandatory)] $SourceConfig
    )

    Write-Log "[1/8] $($CountyConfig.name) 檢查 $($SourceConfig.name)"
    if ($ValidateOnly) {
        Write-Log "[1/8] $($CountyConfig.name) validate-only：正式產製時會用 $($SourceConfig.name) 補官方缺格"
        return ""
    }

    $primaryExtractPath = Join-Path $RepoRoot "data/raw/$($CountyConfig.id)/extract"
    $primaryZipPath = Join-Path $RepoRoot "data/raw/$($CountyConfig.id)/$($CountyConfig.zipName)"
    if (-not (Test-Path -LiteralPath $primaryExtractPath)) {
        if (-not (Test-Path -LiteralPath $primaryZipPath)) {
            throw "缺少 $($CountyConfig.name) 官方來源 zip，無法比對補洞缺格：$primaryZipPath"
        }
        Ensure-ZipExtracted -ZipPath $primaryZipPath -ExtractPath $primaryExtractPath -Name $CountyConfig.name
    }

    $primarySourceFiles = Get-SourceFiles -RawPath $primaryExtractPath
    if ($primarySourceFiles.Count -lt 1) {
        throw "$($CountyConfig.name) 官方來源沒有可比對的 DEM 檔：$primaryExtractPath"
    }

    $rawPath = Join-Path $RepoRoot "data/raw/$($SourceConfig.id)"
    $workPath = Join-Path $RepoRoot "data/work/$($SourceConfig.id)"
    $zipPath = Ensure-CountyGapFillZip -SourceConfig $SourceConfig
    $extractPath = Join-Path $rawPath "extract"
    New-Directory -Path $workPath
    Ensure-ZipExtracted -ZipPath $zipPath -ExtractPath $extractPath -Name $SourceConfig.name

    $fallbackSourceFiles = Get-SourceFiles -RawPath $extractPath
    $missingSourceFiles = Get-MissingGapFillSourceFiles -PrimarySourceFiles $primarySourceFiles -FallbackSourceFiles $fallbackSourceFiles
    Write-Log "$($CountyConfig.name) 內政部補洞來源找到 $($missingSourceFiles.Count) 個官方缺格"

    if ($missingSourceFiles.Count -lt 1) {
        return ""
    }

    $sourceVrt = Build-SourceVrt -CountyConfig $SourceConfig -SourceFiles $missingSourceFiles -WorkPath $workPath
    $epsg4326Raster = Build-Epsg4326Raster -CountyConfig $SourceConfig -SourceRaster $sourceVrt -WorkPath $workPath
    return $epsg4326Raster
}

function Invoke-CountyMoiFullRasterBuild {
    param([Parameter(Mandatory)] $CountyConfig)

    $gapFillSourceConfig = Get-CountyGapFillSourceConfig -CountyId $CountyConfig.id
    if (-not $gapFillSourceConfig) {
        throw "$($CountyConfig.name) 尚未設定內政部 DEM 來源，不能使用 -UseMoiForCounty"
    }

    $sourceConfig = New-CountyMoiFullSourceConfig -CountyConfig $CountyConfig -SourceConfig $gapFillSourceConfig
    $workPath = Join-Path $RepoRoot "data/work/$($sourceConfig.id)"
    $targetTif = Join-Path $workPath "$($sourceConfig.id)-4326.tif"
    if ((Test-Path -LiteralPath $targetTif) -and -not $ForceRebuild) {
        Write-Log "[6/8] $($sourceConfig.name) EPSG:4326 TIFF 已存在，直接作為完整補源：$targetTif"
        return [pscustomobject]@{
            SourceConfig = $sourceConfig
            RasterPath = $targetTif
        }
    }

    Write-Log "[1/8] $($CountyConfig.name) 建立內政部 DEM 完整補源"
    if ($ValidateOnly) {
        Write-Log "[1/8] $($CountyConfig.name) validate-only：正式產製會建立 $targetTif"
        return [pscustomobject]@{
            SourceConfig = $sourceConfig
            RasterPath = ""
        }
    }

    $rawId = Get-SourceRawId -SourceConfig $sourceConfig
    $rawPath = Join-Path $RepoRoot "data/raw/$rawId"
    $zipPath = Ensure-CountyGapFillZip -SourceConfig $sourceConfig
    $extractPath = Join-Path $rawPath "extract"
    New-Directory -Path $workPath
    Ensure-ZipExtracted -ZipPath $zipPath -ExtractPath $extractPath -Name $sourceConfig.name

    $sourceFiles = Get-SourceFiles -RawPath $extractPath
    if ($sourceFiles.Count -lt 1) {
        throw "$($sourceConfig.name) 來源包內找不到 DEM 檔：$extractPath"
    }
    Write-Log "$($CountyConfig.name) 內政部完整來源找到 $($sourceFiles.Count) 個 DEM 檔"

    $sourceVrt = Build-SourceVrt -CountyConfig $sourceConfig -SourceFiles $sourceFiles -WorkPath $workPath
    $epsg4326Raster = Build-Epsg4326Raster -CountyConfig $sourceConfig -SourceRaster $sourceVrt -WorkPath $workPath
    return [pscustomobject]@{
        SourceConfig = $sourceConfig
        RasterPath = $epsg4326Raster
    }
}

function New-CountyMoiFullSourceConfig {
    param(
        [Parameter(Mandatory)] $CountyConfig,
        [Parameter(Mandatory)] $SourceConfig
    )

    return [pscustomobject]@{
        id = "$($CountyConfig.id)_moi_full"
        rawId = (Get-SourceRawId -SourceConfig $SourceConfig)
        providerId = $CountyConfig.id
        name = "$($CountyConfig.name)內政部DEM完整來源"
        zipName = $SourceConfig.zipName
        url = $SourceConfig.url
        sourceSrs = $SourceConfig.sourceSrs
        targetSrs = $CountyConfig.targetSrs
        outputDir = "output/$($CountyConfig.id)_moi"
        expectedBytes = $SourceConfig.expectedBytes
        buildKind = "county_moi_full"
    }
}

function New-CountyMoiProviderConfig {
    param(
        [Parameter(Mandatory)] $CountyConfig,
        [Parameter(Mandatory)] $SourceConfig
    )

    return [pscustomobject]@{
        id = "$($CountyConfig.id)_moi"
        name = "$($CountyConfig.name)(內政部DEM)"
        zipName = $SourceConfig.zipName
        url = $SourceConfig.url
        sourceSrs = $SourceConfig.sourceSrs
        targetSrs = $CountyConfig.targetSrs
        outputDir = $SourceConfig.outputDir
        expectedBytes = $SourceConfig.expectedBytes
    }
}

function Invoke-CountyMoiProviderBuild {
    param([Parameter(Mandatory)] $CountyConfig)

    $moiRasterInfo = Invoke-CountyMoiFullRasterBuild -CountyConfig $CountyConfig
    $sourceConfig = $moiRasterInfo.SourceConfig
    $providerConfig = New-CountyMoiProviderConfig -CountyConfig $CountyConfig -SourceConfig $sourceConfig

    Write-Log "[1/8] $($CountyConfig.name) 改用內政部 DEM 完整來源重轉"
    if ($ValidateOnly) {
        Write-Log "[1/8] $($CountyConfig.name) validate-only：正式產製會輸出到 $($providerConfig.outputDir)"
        return
    }

    Build-TerrainProvider -ProviderConfig $providerConfig -RasterPath $moiRasterInfo.RasterPath -BuildKind $sourceConfig.buildKind
    Add-HistoryEntry -CountyConfig $providerConfig -Status "SUCCESS" -Message "terrain 產製完成；完整使用內政部 DEM 重轉，供 2025+補洞版比對" -RemoteInfo $null
}

function Build-CountyGapFilledRaster {
    param(
        [Parameter(Mandatory)] $CountyConfig,
        [Parameter(Mandatory)][string] $PrimaryRaster
    )

    $fallbackRasters = @()
    $usesSplitGapFill = $false
    $usesMoiGapFill = $false

    $gapFillSourceConfig = Get-CountyGapFillSourceConfig -CountyId $CountyConfig.id
    if ($gapFillSourceConfig) {
        $gapFillRaster = Invoke-CountyGapFillSourceBuild -CountyConfig $CountyConfig -SourceConfig $gapFillSourceConfig
        if ($gapFillRaster -and (Test-Path -LiteralPath $gapFillRaster)) {
            $fallbackRasters += (Get-Item -LiteralPath $gapFillRaster)
            $usesMoiGapFill = $true
        } else {
            Write-Log "[6/8] $($CountyConfig.name) 沒有可用內政部補洞 raster"
        }
    }

    $splitRaster = Get-CountyRasterPath -CountyConfig $CountyConfig
    if ((Test-Path -LiteralPath $splitRaster) -and ([System.IO.Path]::GetFullPath($splitRaster) -ne [System.IO.Path]::GetFullPath($PrimaryRaster))) {
        $fallbackRasters += (Get-Item -LiteralPath $splitRaster)
        $usesSplitGapFill = $true
    } else {
        Write-Log "[6/8] $($CountyConfig.name) 沒有可用 2025 分幅補洞 raster"
    }

    if ($fallbackRasters.Count -lt 1) {
        Write-Log "[6/8] $($CountyConfig.name) 沒有可用補洞 raster，沿用不分幅來源"
        return [pscustomobject]@{
            RasterPath = $PrimaryRaster
            BuildKind = "county_unified_clip"
            Message = "terrain 產製完成；縣市 provider 由官方不分幅全臺來源裁 bbox，來源 NoData 不內插補洞"
        }
    }

    $workPath = Join-Path $RepoRoot "data/work/$($CountyConfig.id)"
    New-Directory -Path $workPath
    $targetSuffix = if ($usesMoiGapFill) { "split-moi-gapfill" } else { "split-gapfill" }
    $targetTif = Join-Path $workPath "$($CountyConfig.id)-$targetSuffix-4326.tif"
    if ((Test-Path -LiteralPath $targetTif) -and -not $ForceRebuild) {
        Write-Log "[6/8] $($CountyConfig.name) 補洞 TIFF 已存在，跳過合併：$targetTif"
        return [pscustomobject]@{
            RasterPath = $targetTif
            BuildKind = if ($usesMoiGapFill) { "county_unified_clip_split_moi_gapfill" } else { "county_unified_clip_split_gapfill" }
            Message = if ($usesMoiGapFill) {
                "terrain 產製完成；不分幅全臺裁 bbox，2025 分幅補不分幅缺值，內政部 DEM 補確認缺格"
            } else {
                "terrain 產製完成；不分幅全臺裁 bbox，2025 分幅補不分幅缺值"
            }
        }
    }
    if ((Test-Path -LiteralPath $targetTif) -and $ForceRebuild) {
        Remove-Item -LiteralPath $targetTif -Force
    }

    $metadata = Get-RasterMetadata -RasterPath $PrimaryRaster
    $bbox = @($metadata.BBox | ForEach-Object { Format-InvariantNumber -Value ([double]$_) })
    $gdalWarp = Get-RequiredCommand -Name "gdalwarp"

    # 疊圖順序由下而上：內政部補缺格、2025 分幅、不分幅全臺；上層有效值優先，只有 NoData 才往下吃。
    $sourceRasterArgs = @($fallbackRasters | ForEach-Object { $_.FullName })
    $warpArgs = @(
        "-overwrite",
        "-t_srs", $CountyConfig.targetSrs,
        "-te_srs", $CountyConfig.targetSrs,
        "-te", $bbox[0], $bbox[1], $bbox[2], $bbox[3],
        "-r", "bilinear",
        "-srcnodata", "-32768",
        "-dstnodata", "-32768",
        "-multi",
        "-wo", "NUM_THREADS=ALL_CPUS",
        "-co", "TILED=YES",
        "-co", "COMPRESS=LZW"
    ) + $sourceRasterArgs + @(
        $PrimaryRaster,
        $targetTif
    )
    Invoke-ExternalCommand -FilePath $gdalWarp -ArgumentList $warpArgs -ProgressMessage "[6/8] $($CountyConfig.name) 合併不分幅、2025 分幅與必要補洞來源"

    return [pscustomobject]@{
        RasterPath = $targetTif
        BuildKind = if ($usesMoiGapFill) { "county_unified_clip_split_moi_gapfill" } else { "county_unified_clip_split_gapfill" }
        Message = if ($usesMoiGapFill) {
            "terrain 產製完成；不分幅全臺裁 bbox，2025 分幅補不分幅缺值，內政部 DEM 補確認缺格"
        } else {
            "terrain 產製完成；不分幅全臺裁 bbox，2025 分幅補不分幅缺值"
        }
    }
}

function Invoke-CountyBuild {
    param(
        [Parameter(Mandatory)] $CountyConfig,
        [bool] $BuildTerrainProvider = $true
    )

    $offshoreSourceConfig = Get-OffshoreUnifiedSourceConfig -CountyId $CountyConfig.id
    if ($offshoreSourceConfig) {
        $offshoreRaster = Invoke-UnifiedGeoTiffSourceBuild -SourceConfig $offshoreSourceConfig
        if ($ValidateOnly) {
            return
        }

        $providerConfig = New-ProviderConfigFromSource -CountyConfig $CountyConfig -SourceConfig $offshoreSourceConfig
        if ($BuildTerrainProvider) {
            Build-TerrainProvider -ProviderConfig $providerConfig -RasterPath $offshoreRaster -BuildKind $offshoreSourceConfig.buildKind
            Add-HistoryEntry -CountyConfig $providerConfig -Status "SUCCESS" -Message "terrain 產製完成；使用官方不分幅離島 GeoTIFF，sourceSrs=$($offshoreSourceConfig.sourceSrs)" -RemoteInfo $null
        } else {
            Write-Log "[7/8] $($CountyConfig.name) 不分幅離島 EPSG:4326 GeoTIFF 已備妥，等待全臺含外島 VRT"
        }

        return $offshoreRaster
    }

    Write-Log "[1/8] $($CountyConfig.name) 檢查 TGOS 來源"
    $remoteInfo = Get-RemoteFileInfo -CountyConfig $CountyConfig
    Write-Log "$($CountyConfig.name) TGOS HEAD：status=$($remoteInfo.StatusCode), bytes=$($remoteInfo.Bytes), modified=$($remoteInfo.LastModified)"

    if ($ValidateOnly) {
        return
    }

    $rawPath = Join-Path $RepoRoot "data/raw/$($CountyConfig.id)"
    $workPath = Join-Path $RepoRoot "data/work/$($CountyConfig.id)"
    $zipPath = Join-Path $rawPath $CountyConfig.zipName
    $extractPath = Join-Path $rawPath "extract"

    New-Directory -Path $rawPath
    New-Directory -Path $workPath

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

    if ($BuildTerrainProvider) {
        Build-TerrainProvider -ProviderConfig $CountyConfig -RasterPath $epsg4326Raster -BuildKind "county"
        Add-HistoryEntry -CountyConfig $CountyConfig -Status "SUCCESS" -Message "terrain 產製完成" -RemoteInfo $remoteInfo
    } else {
        Write-Log "[7/8] $($CountyConfig.name) EPSG:4326 GeoTIFF 已備妥，等待全臺 mosaic 裁切縣市 provider"
    }

    return $epsg4326Raster
}

function Invoke-UnifiedTaiwanSourceBuild {
    return (Invoke-UnifiedGeoTiffSourceBuild -SourceConfig $UnifiedTaiwanSourceConfig)
}

function Invoke-TaiwanMainBuild {
    param(
        [Parameter(Mandatory)] $CountyConfigs,
        [string] $UnifiedTaiwanRaster = ""
    )

    $providerOutputDir = "output/$MainTaiwanProviderId"
    $providerConfig = [pscustomobject]@{
        id = $MainTaiwanProviderId
        name = "全臺主島"
        zipName = ""
        url = if ($UnifiedTaiwanRaster) { "taiwan-unified-mainland-vrt" } else { "19-county-mainland-epsg4326-vrt" }
        sourceSrs = "EPSG:4326"
        targetSrs = "EPSG:4326"
        outputDir = $providerOutputDir
        expectedBytes = 0
    }
    $buildKind = if ($UnifiedTaiwanRaster) { "taiwan_unified" } else { "taiwan_19_county" }
    $sourceMode = if ($UnifiedTaiwanRaster) { "不分幅全臺主島" } else { "19 個主島縣市 EPSG:4326 GeoTIFF" }

    Write-Log "[1/8] 全臺主島 檢查 $sourceMode"
    if ($ValidateOnly) {
        Write-Log "[1/8] 全臺主島 validate-only：正式產製時會建立 taiwan"
        return
    }

    $workPath = Join-Path $RepoRoot "data/work/$MainTaiwanProviderId"
    New-Directory -Path $workPath
    $sourceRasters = @()
    $usesMoiFullGapFill = $false

    if ($UnifiedTaiwanRaster) {
        if (-not (Test-Path -LiteralPath $UnifiedTaiwanRaster)) {
            throw "缺少不分幅全臺 EPSG:4326 GeoTIFF：$UnifiedTaiwanRaster"
        }

        $usesSplitGapFill = $false
        $usesMoiGapFill = $false
        $moiFullRasters = @()
        $moiFullCountyNames = [System.Collections.Generic.List[string]]::new()
        foreach ($county in $CountyConfigs) {
            if ($UnifiedTaiwanExcludedCountyIds -contains $county.id) {
                continue
            }

            $gapFillSourceConfig = Get-CountyGapFillSourceConfig -CountyId $county.id
            if ($UseMoiForCounty -and $gapFillSourceConfig) {
                $moiFullRasterInfo = Invoke-CountyMoiFullRasterBuild -CountyConfig $county
                if ($moiFullRasterInfo.RasterPath -and (Test-Path -LiteralPath $moiFullRasterInfo.RasterPath)) {
                    $moiFullRasters += (Get-Item -LiteralPath $moiFullRasterInfo.RasterPath)
                    $usesMoiFullGapFill = $true
                    $moiFullCountyNames.Add($county.name)
                }
            } elseif ($gapFillSourceConfig) {
                $gapFillRaster = Invoke-CountyGapFillSourceBuild -CountyConfig $county -SourceConfig $gapFillSourceConfig
                if ($gapFillRaster -and (Test-Path -LiteralPath $gapFillRaster)) {
                    $sourceRasters += (Get-Item -LiteralPath $gapFillRaster)
                    $usesMoiGapFill = $true
                }
            }

            $countyRaster = Get-CountyRasterPath -CountyConfig $county
            if (-not (Test-Path -LiteralPath $countyRaster)) {
                throw "缺少 $($county.name) 2025 分幅 EPSG:4326 GeoTIFF，無法補全臺主島缺值：$countyRaster"
            }
            $sourceRasters += (Get-Item -LiteralPath $countyRaster)
            $usesSplitGapFill = $true
        }

        if ($usesSplitGapFill) {
            $sourceMode = "$sourceMode + 2025縣市分幅缺值補洞"
            $buildKind = "taiwan_unified_split_gapfill"
        }
        if ($usesMoiGapFill) {
            $sourceMode = "$sourceMode + 內政部確認缺格補洞"
            $buildKind = "taiwan_unified_split_moi_gapfill"
        }
        if ($usesMoiFullGapFill) {
            $sourceMode = "$sourceMode + $(Get-MoiFullSourceModeText -CountyNames $moiFullCountyNames.ToArray())"
            $buildKind = "taiwan_unified_split_moi_full_gapfill"
        }
        $sourceRasters += (Get-Item -LiteralPath $UnifiedTaiwanRaster)
        # gdalbuildvrt 以後列來源為優先，MOI full 必須最後加入，才能壓過 2025 不分幅的異常有效值。
        $sourceRasters += $moiFullRasters
    } else {
        foreach ($county in $CountyConfigs) {
            if ($UnifiedTaiwanExcludedCountyIds -contains $county.id) {
                continue
            }
            $countyRaster = Get-CountyRasterPath -CountyConfig $county
            if (-not (Test-Path -LiteralPath $countyRaster)) {
                throw "缺少主島縣市 EPSG:4326 GeoTIFF，請先跑縣市產製：$countyRaster"
            }
            $sourceRasters += (Get-Item -LiteralPath $countyRaster)
        }
    }

    if ($sourceRasters.Count -lt 1) {
        throw "全臺主島沒有可用來源 raster"
    }

    $sourceList = Join-Path $workPath "$MainTaiwanProviderId-sources.txt"
    $taiwanVrt = Join-Path $workPath "$MainTaiwanProviderId.vrt"
    $sourceRasters.FullName | Set-Content -LiteralPath $sourceList -Encoding utf8
    $gdalBuildVrt = Get-RequiredCommand -Name "gdalbuildvrt"
    Invoke-ExternalCommand -FilePath $gdalBuildVrt -ArgumentList @(
        "-overwrite",
        "-a_srs", "EPSG:4326",
        "-input_file_list", $sourceList,
        $taiwanVrt
    ) -ProgressMessage "[5/8] 全臺主島 gdalbuildvrt 建立全臺主島 VRT"

    $terrainRaster = $taiwanVrt
    if ($usesMoiFullGapFill) {
        $terrainRaster = Build-CompositeRaster -ProviderName "全臺主島" -SourceRasters $sourceRasters -ReferenceRaster $taiwanVrt -TargetRaster (Join-Path $workPath "$MainTaiwanProviderId-moi-full-composite-4326.tif")
    }

    Build-TerrainProvider -ProviderConfig $providerConfig -RasterPath $terrainRaster -BuildKind $buildKind
    Add-HistoryEntry -CountyConfig $providerConfig -Status "SUCCESS" -Message "全臺主島 terrain 產製完成；來源模式：$sourceMode" -RemoteInfo $null

    return $terrainRaster
}

function Invoke-AllTaiwanBuild {
    param(
        [Parameter(Mandatory)] $CountyConfigs,
        [string] $UnifiedTaiwanRaster = "",
        [hashtable] $UnifiedOffshoreRasterByCounty = @{}
    )

    $providerOutputDir = "output/all_taiwan"
    $providerConfig = [pscustomobject]@{
        id = $TaiwanProviderId
        name = "全臺含外島"
        zipName = ""
        url = if ($UnifiedTaiwanRaster) { "taiwan-unified-mainland-plus-offshore-vrt" } else { "21-county-epsg4326-vrt" }
        sourceSrs = "EPSG:4326"
        targetSrs = "EPSG:4326"
        outputDir = $providerOutputDir
        expectedBytes = 0
    }
    $buildKind = if ($UnifiedTaiwanRaster) { "all_taiwan_unified" } else { "all_taiwan" }

    $sourceMode = if ($UnifiedTaiwanRaster) { "不分幅全臺主島 + 不分幅離島" } else { "21 個縣市 EPSG:4326 GeoTIFF" }
    Write-Log "[1/8] 全臺含外島 檢查 $sourceMode"
    if ($ValidateOnly) {
        Write-Log "[1/8] 全臺含外島 validate-only：正式產製時會從 $sourceMode 建立 all_taiwan"
        return
    }

    $workPath = Join-Path $RepoRoot "data/work/$TaiwanProviderId"
    New-Directory -Path $workPath
    $sourceRasters = @()
    $usesMoiFullGapFill = $false
    if ($UnifiedTaiwanRaster) {
        if (-not (Test-Path -LiteralPath $UnifiedTaiwanRaster)) {
            throw "缺少不分幅全臺 EPSG:4326 GeoTIFF：$UnifiedTaiwanRaster"
        }
        $usesSplitGapFill = $false
        $usesMoiGapFill = $false
        $moiFullRasters = @()
        $moiFullCountyNames = [System.Collections.Generic.List[string]]::new()
        foreach ($county in $CountyConfigs) {
            if ($UnifiedTaiwanExcludedCountyIds -contains $county.id) {
                continue
            }
            $gapFillSourceConfig = Get-CountyGapFillSourceConfig -CountyId $county.id
            if ($UseMoiForCounty -and $gapFillSourceConfig) {
                $moiFullRasterInfo = Invoke-CountyMoiFullRasterBuild -CountyConfig $county
                if ($moiFullRasterInfo.RasterPath -and (Test-Path -LiteralPath $moiFullRasterInfo.RasterPath)) {
                    $moiFullRasters += (Get-Item -LiteralPath $moiFullRasterInfo.RasterPath)
                    $usesMoiFullGapFill = $true
                    $moiFullCountyNames.Add($county.name)
                }
            } elseif (-not $gapFillSourceConfig) {
                $gapFillRaster = ""
            } else {
                $gapFillRaster = Invoke-CountyGapFillSourceBuild -CountyConfig $county -SourceConfig $gapFillSourceConfig
                if ($gapFillRaster -and (Test-Path -LiteralPath $gapFillRaster)) {
                    $sourceRasters += (Get-Item -LiteralPath $gapFillRaster)
                    $usesMoiGapFill = $true
                }
            }

            $countyRaster = Get-CountyRasterPath -CountyConfig $county
            if (-not (Test-Path -LiteralPath $countyRaster)) {
                throw "缺少 $($county.name) 2025 分幅 EPSG:4326 GeoTIFF，無法補不分幅缺值：$countyRaster"
            }
            $sourceRasters += (Get-Item -LiteralPath $countyRaster)
            $usesSplitGapFill = $true
        }
        if ($usesSplitGapFill) {
            $sourceMode = "$sourceMode + 2025縣市分幅缺值補洞"
            $buildKind = "all_taiwan_unified_split_gapfill"
        }
        if ($usesMoiGapFill) {
            $sourceMode = "$sourceMode + 內政部確認缺格補洞"
            $buildKind = "all_taiwan_unified_split_moi_gapfill"
        }
        if ($usesMoiFullGapFill) {
            $sourceMode = "$sourceMode + $(Get-MoiFullSourceModeText -CountyNames $moiFullCountyNames.ToArray())"
            $buildKind = "all_taiwan_unified_split_moi_full_gapfill"
        }
        $sourceRasters += (Get-Item -LiteralPath $UnifiedTaiwanRaster)
    }

    foreach ($county in $CountyConfigs) {
        if ($UnifiedTaiwanRaster -and ($UnifiedTaiwanExcludedCountyIds -notcontains $county.id)) {
            continue
        }
        if ($UnifiedOffshoreRasterByCounty.ContainsKey($county.id)) {
            $sourceRasters += (Get-Item -LiteralPath $UnifiedOffshoreRasterByCounty[$county.id])
            continue
        }
        $countyRaster = Get-CountyRasterPath -CountyConfig $county
        if (-not (Test-Path -LiteralPath $countyRaster)) {
            throw "缺少縣市 EPSG:4326 GeoTIFF，請先跑縣市產製：$countyRaster"
        }
        $sourceRasters += (Get-Item -LiteralPath $countyRaster)
    }

    if ($UnifiedTaiwanRaster) {
        foreach ($offshoreSourceConfig in $UnifiedOffshoreSourceConfigs) {
            if (-not $UnifiedOffshoreRasterByCounty.ContainsKey($offshoreSourceConfig.providerId)) {
                continue
            }
            $offshoreRaster = [string]$UnifiedOffshoreRasterByCounty[$offshoreSourceConfig.providerId]
            $alreadyAdded = @($sourceRasters | Where-Object { $_.FullName -eq (Get-Item -LiteralPath $offshoreRaster).FullName }).Count -gt 0
            if (-not $alreadyAdded) {
                $sourceRasters += (Get-Item -LiteralPath $offshoreRaster)
            }
        }
        # gdalbuildvrt 以後列來源為優先，MOI full 必須最後加入，才能壓過 2025 不分幅的異常有效值。
        $sourceRasters += $moiFullRasters
    }

    if (-not $UnifiedTaiwanRaster -and $sourceRasters.Count -ne 21) {
        throw "全臺含外島需要 21 個縣市 EPSG:4326 GeoTIFF，目前只有 $($sourceRasters.Count) 個"
    }

    $sourceList = Join-Path $workPath "$TaiwanProviderId-sources.txt"
    $taiwanVrt = Join-Path $workPath "$TaiwanProviderId.vrt"
    $sourceRasters.FullName | Set-Content -LiteralPath $sourceList -Encoding utf8
    $gdalBuildVrt = Get-RequiredCommand -Name "gdalbuildvrt"
    Invoke-ExternalCommand -FilePath $gdalBuildVrt -ArgumentList @(
        "-overwrite",
        "-a_srs", "EPSG:4326",
        "-input_file_list", $sourceList,
        $taiwanVrt
    ) -ProgressMessage "[5/8] 全臺含外島 gdalbuildvrt 建立全臺 VRT"

    $terrainRaster = $taiwanVrt
    if ($usesMoiFullGapFill) {
        $terrainRaster = Build-CompositeRaster -ProviderName "全臺含外島" -SourceRasters $sourceRasters -ReferenceRaster $taiwanVrt -TargetRaster (Join-Path $workPath "$TaiwanProviderId-moi-full-composite-4326.tif")
    }

    Build-TerrainProvider -ProviderConfig $providerConfig -RasterPath $terrainRaster -BuildKind $buildKind
    Add-HistoryEntry -CountyConfig $providerConfig -Status "SUCCESS" -Message "全臺含外島 terrain 產製完成；來源模式：$sourceMode" -RemoteInfo $null

    return $terrainRaster
}

function Invoke-FromGrdTaiwanBuild {
    param(
        [Parameter(Mandatory)] $CountyConfigs,
        [bool] $IncludeOffshore = $false,
        [hashtable] $UnifiedOffshoreRasterByCounty = @{}
    )

    $providerId = if ($IncludeOffshore) { $FromGrdAllTaiwanProviderId } else { $FromGrdTaiwanProviderId }
    $providerName = if ($IncludeOffshore) { "全臺含外島(from GRD)" } else { "臺灣本島(from GRD)" }
    $sourceMode = if ($IncludeOffshore) {
        "2025縣市分幅GRD + 2025不分幅離島"
    } else {
        "2025縣市分幅GRD"
    }
    $buildKind = if ($IncludeOffshore) { "all_taiwan_from_grd_moi_full" } else { "taiwan_from_grd_moi_full" }
    $providerConfig = [pscustomobject]@{
        id = $providerId
        name = $providerName
        zipName = ""
        url = if ($IncludeOffshore) { "2025-county-grd-plus-offshore-vrt" } else { "2025-mainland-county-grd-vrt" }
        sourceSrs = "EPSG:4326"
        targetSrs = "EPSG:4326"
        outputDir = "output/$providerId"
        expectedBytes = 0
    }

    Write-Log "[1/8] $providerName 檢查 $sourceMode"
    if ($ValidateOnly) {
        Write-Log "[1/8] $providerName validate-only：正式產製時會建立 $providerId"
        return
    }

    $workPath = Join-Path $RepoRoot "data/work/$providerId"
    New-Directory -Path $workPath
    $sourceRasters = @()
    $mainlandCount = 0
    $offshoreCount = 0
    $usesMoiFull = $false
    $moiFullCountyNames = [System.Collections.Generic.List[string]]::new()

    foreach ($county in $CountyConfigs) {
        if ($UnifiedTaiwanExcludedCountyIds -contains $county.id) {
            continue
        }

        $gapFillSourceConfig = Get-CountyGapFillSourceConfig -CountyId $county.id
        if ($gapFillSourceConfig) {
            $moiFullRasterInfo = Invoke-CountyMoiFullRasterBuild -CountyConfig $county
            if (-not ($moiFullRasterInfo.RasterPath -and (Test-Path -LiteralPath $moiFullRasterInfo.RasterPath))) {
                throw "缺少 $($county.name) MOI 完整 EPSG:4326 GeoTIFF，無法建立 $providerId"
            }
            $sourceRasters += (Get-Item -LiteralPath $moiFullRasterInfo.RasterPath)
            $usesMoiFull = $true
            $moiFullCountyNames.Add($county.name)
        } else {
            $countyRaster = Get-CountyRasterPath -CountyConfig $county
            if (-not (Test-Path -LiteralPath $countyRaster)) {
                throw "缺少 $($county.name) 2025 分幅 EPSG:4326 GeoTIFF，無法建立 $providerId：$countyRaster"
            }
            $sourceRasters += (Get-Item -LiteralPath $countyRaster)
        }
        $mainlandCount++
    }

    if ($IncludeOffshore) {
        foreach ($offshoreSourceConfig in $UnifiedOffshoreSourceConfigs) {
            if (-not $UnifiedOffshoreRasterByCounty.ContainsKey($offshoreSourceConfig.providerId)) {
                throw "缺少 $($offshoreSourceConfig.name) EPSG:4326 GeoTIFF，無法建立 $providerId"
            }
            $sourceRasters += (Get-Item -LiteralPath $UnifiedOffshoreRasterByCounty[$offshoreSourceConfig.providerId])
            $offshoreCount++
        }
    }

    if ($mainlandCount -lt 1) {
        throw "$providerName 沒有可用本島來源 raster"
    }
    if ($IncludeOffshore -and $offshoreCount -lt $UnifiedOffshoreSourceConfigs.Count) {
        throw "$providerName 離島來源不足：$offshoreCount/$($UnifiedOffshoreSourceConfigs.Count)"
    }

    if ($usesMoiFull) {
        $sourceMode = "$sourceMode + $(Get-MoiFullSourceModeText -CountyNames $moiFullCountyNames.ToArray())"
    }

    $sourceList = Join-Path $workPath "$providerId-sources.txt"
    $taiwanVrt = Join-Path $workPath "$providerId.vrt"
    $sourceRasters.FullName | Set-Content -LiteralPath $sourceList -Encoding utf8
    $gdalBuildVrt = Get-RequiredCommand -Name "gdalbuildvrt"
    Invoke-ExternalCommand -FilePath $gdalBuildVrt -ArgumentList @(
        "-overwrite",
        "-a_srs", "EPSG:4326",
        "-input_file_list", $sourceList,
        $taiwanVrt
    ) -ProgressMessage "[5/8] $providerName gdalbuildvrt 建立 from_grd VRT"

    Build-TerrainProvider -ProviderConfig $providerConfig -RasterPath $taiwanVrt -BuildKind $buildKind
    Add-HistoryEntry -CountyConfig $providerConfig -Status "SUCCESS" -Message "$providerName terrain 產製完成；來源模式：$sourceMode" -RemoteInfo $null

    return $taiwanVrt
}

function Build-CountyMosaicRaster {
    param(
        [Parameter(Mandatory)] $CountyConfig,
        [Parameter(Mandatory)][string] $TaiwanRaster
    )

    $workPath = Join-Path $RepoRoot "data/work/$($CountyConfig.id)"
    New-Directory -Path $workPath

    $countyRaster = Join-Path $workPath "$($CountyConfig.id)-4326.tif"
    if (-not (Test-Path -LiteralPath $countyRaster)) {
        throw "缺少縣市 EPSG:4326 GeoTIFF，無法裁切 mosaic provider：$countyRaster"
    }

    $targetTif = Join-Path $workPath "$($CountyConfig.id)-mosaic-4326.tif"
    if ((Test-Path -LiteralPath $targetTif) -and -not $ForceRebuild) {
        Write-Log "[6/8] $($CountyConfig.name) mosaic EPSG:4326 TIFF 已存在，跳過裁切：$targetTif"
        return $targetTif
    }
    if ((Test-Path -LiteralPath $targetTif) -and $ForceRebuild) {
        Remove-Item -LiteralPath $targetTif -Force
    }

    $metadata = Get-RasterMetadata -RasterPath $countyRaster
    $bbox = @($metadata.BBox | ForEach-Object { Format-InvariantNumber -Value ([double]$_) })
    $gdalWarp = Get-RequiredCommand -Name "gdalwarp"

    # 縣市分幅本身是不規則覆蓋，直接做 provider 會在縣市邊界形成 NoData 牆。
    # 我改從全臺 mosaic 依原縣市 bbox 裁切，保留縣市端點並讓畫面內有鄰縣地形可銜接。
    Invoke-ExternalCommand -FilePath $gdalWarp -ArgumentList @(
        "-overwrite",
        "-t_srs", $CountyConfig.targetSrs,
        "-te_srs", $CountyConfig.targetSrs,
        "-te", $bbox[0], $bbox[1], $bbox[2], $bbox[3],
        "-r", "bilinear",
        "-srcnodata", "-32768",
        "-dstnodata", "-32768",
        "-multi",
        "-wo", "NUM_THREADS=ALL_CPUS",
        "-co", "TILED=YES",
        "-co", "COMPRESS=LZW",
        $TaiwanRaster,
        $targetTif
    ) -ProgressMessage "[6/8] $($CountyConfig.name) 從全臺 mosaic 裁切縣市 bbox"

    return $targetTif
}

function Build-CountyUnifiedRaster {
    param(
        [Parameter(Mandatory)] $CountyConfig,
        [Parameter(Mandatory)][string] $UnifiedTaiwanRaster
    )

    $workPath = Join-Path $RepoRoot "data/work/$($CountyConfig.id)"
    New-Directory -Path $workPath

    $countyRaster = Get-CountyRasterPath -CountyConfig $CountyConfig
    if (-not (Test-Path -LiteralPath $countyRaster)) {
        throw "缺少縣市 EPSG:4326 GeoTIFF，無法裁切不分幅全臺 provider：$countyRaster"
    }

    $targetTif = Join-Path $workPath "$($CountyConfig.id)-unified-4326.tif"
    if ((Test-Path -LiteralPath $targetTif) -and -not $ForceRebuild) {
        Write-Log "[6/8] $($CountyConfig.name) 不分幅全臺裁切 TIFF 已存在，跳過裁切：$targetTif"
        return $targetTif
    }
    if ((Test-Path -LiteralPath $targetTif) -and $ForceRebuild) {
        Remove-Item -LiteralPath $targetTif -Force
    }

    $metadata = Get-RasterMetadata -RasterPath $countyRaster
    $bbox = @($metadata.BBox | ForEach-Object { Format-InvariantNumber -Value ([double]$_) })
    $gdalWarp = Get-RequiredCommand -Name "gdalwarp"

    # 官方不分幅全臺 TIF 比縣市分幅更適合當主島底圖來源；來源 NoData 仍保留，不在這裡硬補。
    Invoke-ExternalCommand -FilePath $gdalWarp -ArgumentList @(
        "-overwrite",
        "-t_srs", $CountyConfig.targetSrs,
        "-te_srs", $CountyConfig.targetSrs,
        "-te", $bbox[0], $bbox[1], $bbox[2], $bbox[3],
        "-r", "bilinear",
        "-srcnodata", "-32768",
        "-dstnodata", "-32768",
        "-multi",
        "-wo", "NUM_THREADS=ALL_CPUS",
        "-co", "TILED=YES",
        "-co", "COMPRESS=LZW",
        $UnifiedTaiwanRaster,
        $targetTif
    ) -ProgressMessage "[6/8] $($CountyConfig.name) 從不分幅全臺裁切縣市 bbox"

    return $targetTif
}

function Invoke-CountyMosaicProviderBuild {
    param(
        [Parameter(Mandatory)] $CountyConfigs,
        [Parameter(Mandatory)][string] $TaiwanRaster,
        [hashtable] $UnifiedOffshoreRasterByCounty = @{}
    )

    foreach ($county in $CountyConfigs) {
        if ($UnifiedOffshoreRasterByCounty.ContainsKey($county.id)) {
            $offshoreSourceConfig = Get-OffshoreUnifiedSourceConfig -CountyId $county.id
            $providerConfig = New-ProviderConfigFromSource -CountyConfig $county -SourceConfig $offshoreSourceConfig
            Build-TerrainProvider -ProviderConfig $providerConfig -RasterPath $UnifiedOffshoreRasterByCounty[$county.id] -BuildKind $offshoreSourceConfig.buildKind
            Add-HistoryEntry -CountyConfig $providerConfig -Status "SUCCESS" -Message "離島 terrain 產製完成；使用官方不分幅離島 GeoTIFF，sourceSrs=$($offshoreSourceConfig.sourceSrs)" -RemoteInfo $null
            continue
        }
        if ($UnifiedTaiwanExcludedCountyIds -contains $county.id) {
            throw "$($county.name) 正式 terrain 禁止使用 2025 分幅錯包來源，必須使用官方不分幅離島 GeoTIFF。"
        }

        $mosaicRaster = Build-CountyMosaicRaster -CountyConfig $county -TaiwanRaster $TaiwanRaster
        Build-TerrainProvider -ProviderConfig $county -RasterPath $mosaicRaster -BuildKind "county_mosaic_clip"
        Add-HistoryEntry -CountyConfig $county -Status "SUCCESS" -Message "terrain 產製完成；縣市 provider 由全臺 mosaic 裁 bbox，避免縣市邊界 NoData 牆" -RemoteInfo $null
    }
}

function Invoke-CountyUnifiedProviderBuild {
    param(
        [Parameter(Mandatory)] $CountyConfigs,
        [Parameter(Mandatory)][string] $UnifiedTaiwanRaster,
        [hashtable] $UnifiedOffshoreRasterByCounty = @{}
    )

    foreach ($county in $CountyConfigs) {
        if ($UnifiedOffshoreRasterByCounty.ContainsKey($county.id)) {
            $offshoreSourceConfig = Get-OffshoreUnifiedSourceConfig -CountyId $county.id
            $providerConfig = New-ProviderConfigFromSource -CountyConfig $county -SourceConfig $offshoreSourceConfig
            Build-TerrainProvider -ProviderConfig $providerConfig -RasterPath $UnifiedOffshoreRasterByCounty[$county.id] -BuildKind $offshoreSourceConfig.buildKind
            Add-HistoryEntry -CountyConfig $providerConfig -Status "SUCCESS" -Message "離島 terrain 產製完成；使用官方不分幅離島 GeoTIFF，sourceSrs=$($offshoreSourceConfig.sourceSrs)" -RemoteInfo $null
            continue
        }

        if ($UnifiedTaiwanExcludedCountyIds -contains $county.id) {
            throw "$($county.name) 正式 terrain 禁止使用 2025 分幅錯包來源，必須使用官方不分幅離島 GeoTIFF。"
        }

        $unifiedRaster = Build-CountyUnifiedRaster -CountyConfig $county -UnifiedTaiwanRaster $UnifiedTaiwanRaster
        $providerRasterInfo = Build-CountyGapFilledRaster -CountyConfig $county -PrimaryRaster $unifiedRaster
        Build-TerrainProvider -ProviderConfig $county -RasterPath $providerRasterInfo.RasterPath -BuildKind $providerRasterInfo.BuildKind
        Add-HistoryEntry -CountyConfig $county -Status "SUCCESS" -Message $providerRasterInfo.Message -RemoteInfo $null
    }
}

function Main {
    New-Directory -Path $LogDir
    Write-Log "開始 terrain pipeline，CTB=$DockerImage，ctb=$CtbCommandText"

    $counties = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $requestedCountyIds = Normalize-CountyIds -CountyIds $County
    $hasRequestedCountyIds = ($requestedCountyIds -and $requestedCountyIds.Count -gt 0)
    $knownCountyIds = @($counties | ForEach-Object { $_.id })
    if ($hasRequestedCountyIds) {
        $unknownCountyIds = @($requestedCountyIds | Where-Object { $knownCountyIds -notcontains $_ })
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

    if ($FromGrd -and -not $AllWithTaiwan) {
        throw "-FromGrd 需要搭配 -AllWithTaiwan，會建立 taiwan_from_grd 與 all_taiwan_from_grd"
    }
    if ($FromGrd -and $hasRequestedCountyIds) {
        Write-Log "-FromGrd 固定建立完整 taiwan_from_grd/all_taiwan_from_grd，忽略 -County 篩選並掃描全部縣市來源"
    }

    $selected = if ($FromGrd -or $All -or -not $hasRequestedCountyIds) {
        @($counties)
    } else {
        @($counties | Where-Object { $requestedCountyIds -contains $_.id })
    }

    if ($UseMoiForCounty) {
        if (-not $hasRequestedCountyIds) {
            throw "-UseMoiForCounty 需要搭配 -County 指定縣市，避免不小心整批重轉"
        }

        if (-not $AllWithTaiwan) {
            foreach ($item in $selected) {
                try {
                    Invoke-CountyMoiProviderBuild -CountyConfig $item
                } catch {
                    if (-not $ValidateOnly) {
                        $providerConfig = [pscustomobject]@{
                            id = "$($item.id)_moi"
                            name = "$($item.name)(內政部DEM)"
                            url = ""
                            sourceSrs = $item.sourceSrs
                            targetSrs = $item.targetSrs
                            outputDir = "output/$($item.id)_moi"
                            expectedBytes = 0
                        }
                        Add-HistoryEntry -CountyConfig $providerConfig -Status "FAILED" -Message $_.Exception.Message -RemoteInfo $null
                    }
                    throw
                }
            }

            Write-Log "terrain pipeline 結束"
            return
        }
    }

    $useSubsetForAllWithTaiwan = ($AllWithTaiwan -and $hasRequestedCountyIds -and -not $All -and -not $FromGrd)
    $taiwanSourceCounties = if ($useSubsetForAllWithTaiwan) {
        Write-Log "AllWithTaiwan 指定縣市模式：只重建 $($selected.id -join ', ')；全臺仍使用不分幅主島、必要縣市補洞與不分幅離島來源"
        $selected
    } else {
        $counties
    }

    foreach ($item in $selected) {
        try {
            Invoke-CountyBuild -CountyConfig $item -BuildTerrainProvider:(-not $AllWithTaiwan)
        } catch {
            if (-not $ValidateOnly) {
                Add-HistoryEntry -CountyConfig $item -Status "FAILED" -Message $_.Exception.Message -RemoteInfo $null
            }
            throw
        }
    }

    if ($AllWithTaiwan) {
        try {
            $unifiedTaiwanRaster = $null
            $unifiedOffshoreRasterByCounty = @{}
            if ($FromGrd) {
                Write-Log "已指定 -FromGrd：略過不分幅全臺主島，改用 2025 縣市 GRD 建立 from_grd provider"
            } elseif (-not $SkipUnifiedTaiwanSource) {
                $unifiedTaiwanRaster = Invoke-UnifiedTaiwanSourceBuild
            } else {
                Write-Log "已指定 -SkipUnifiedTaiwanSource，只略過不分幅全臺主島；澎湖、金門仍強制使用不分幅離島來源"
            }
            foreach ($offshoreSourceConfig in $UnifiedOffshoreSourceConfigs) {
                $offshoreRaster = Invoke-UnifiedGeoTiffSourceBuild -SourceConfig $offshoreSourceConfig
                if (-not $ValidateOnly) {
                    $unifiedOffshoreRasterByCounty[$offshoreSourceConfig.providerId] = $offshoreRaster
                }
            }

            if ($FromGrd) {
                $mainTaiwanRaster = Invoke-FromGrdTaiwanBuild -CountyConfigs $counties -IncludeOffshore:$false
                $taiwanRaster = Invoke-FromGrdTaiwanBuild -CountyConfigs $counties -IncludeOffshore:$true -UnifiedOffshoreRasterByCounty $unifiedOffshoreRasterByCounty
                if (-not $ValidateOnly) {
                    Write-Log "[7/8] 已指定 -FromGrd：只重建 taiwan_from_grd/all_taiwan_from_grd，略過既有 taiwan/all_taiwan 與縣市 provider 重建"
                }
            } else {
                $mainTaiwanRaster = Invoke-TaiwanMainBuild -CountyConfigs $taiwanSourceCounties -UnifiedTaiwanRaster $unifiedTaiwanRaster
                $taiwanRaster = Invoke-AllTaiwanBuild -CountyConfigs $taiwanSourceCounties -UnifiedTaiwanRaster $unifiedTaiwanRaster -UnifiedOffshoreRasterByCounty $unifiedOffshoreRasterByCounty
                if (-not $ValidateOnly) {
                    if ($UseMoiForCounty) {
                        Write-Log "[7/8] 已指定 -UseMoiForCounty + -AllWithTaiwan：只重建 taiwan/all_taiwan，略過縣市 provider 重建"
                    } elseif ($unifiedTaiwanRaster) {
                        Invoke-CountyUnifiedProviderBuild -CountyConfigs $selected -UnifiedTaiwanRaster $unifiedTaiwanRaster -UnifiedOffshoreRasterByCounty $unifiedOffshoreRasterByCounty
                    } else {
                        Invoke-CountyMosaicProviderBuild -CountyConfigs $selected -TaiwanRaster $mainTaiwanRaster -UnifiedOffshoreRasterByCounty $unifiedOffshoreRasterByCounty
                    }
                }
            }
        } catch {
            if (-not $ValidateOnly) {
                $failedProviderId = if ($FromGrd) { $FromGrdAllTaiwanProviderId } else { $TaiwanProviderId }
                $failedProviderName = if ($FromGrd) { "全臺含外島(from GRD)" } else { "全臺含外島" }
                $providerConfig = [pscustomobject]@{
                    id = $failedProviderId
                    name = $failedProviderName
                    url = "21-county-epsg4326-vrt"
                    sourceSrs = "EPSG:4326"
                    targetSrs = "EPSG:4326"
                    outputDir = (Get-ProviderOutputDir -ProviderId $failedProviderId)
                    expectedBytes = 0
                }
                Add-HistoryEntry -CountyConfig $providerConfig -Status "FAILED" -Message $_.Exception.Message -RemoteInfo $null
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
