<?php
declare(strict_types=1);

/**
 * 需求：
 * 1) 產出 data/polygons/<provider>.txt
 * 2) 格式統一：[{label,wkt}]
 * 3) 全部轉 EPSG:3826
 * 4) 目前以 .grd 明碼計算 bbox（速度優先）
 */

$baseDir = __DIR__;
$rawRoot = $baseDir . DIRECTORY_SEPARATOR . 'data' . DIRECTORY_SEPARATOR . 'raw';
$workRoot = $baseDir . DIRECTORY_SEPARATOR . 'data' . DIRECTORY_SEPARATOR . 'work';
$polygonRoot = $baseDir . DIRECTORY_SEPARATOR . 'data' . DIRECTORY_SEPARATOR . 'polygons';
$summaryOutput = $baseDir . DIRECTORY_SEPARATOR . 'all_gdr_boxes.json';
$onlyProviders = [];

foreach ($argv as $arg) {
    if (str_starts_with($arg, '--only=')) {
        $onlyProviders = array_values(array_filter(array_map('trim', explode(',', substr($arg, 7)))));
    }
}

$configPath = $baseDir . DIRECTORY_SEPARATOR . 'config' . DIRECTORY_SEPARATOR . 'counties.json';
if (!is_file($configPath)) {
    fwrite(STDERR, "ERROR: 找不到 counties 設定檔：{$configPath}\n");
    exit(1);
}

if (!is_dir($polygonRoot) && !mkdir($polygonRoot, 0777, true) && !is_dir($polygonRoot)) {
    fwrite(STDERR, "ERROR: 建立輸出目錄失敗：{$polygonRoot}\n");
    exit(1);
}

$counties = json_decode((string) file_get_contents($configPath), true);
if (!is_array($counties)) {
    fwrite(STDERR, "ERROR: counties.json 格式錯誤\n");
    exit(1);
}

setlocale(LC_ALL, 'C');

function shouldRunProvider(string $providerId, array $onlyProviders): bool
{
    return empty($onlyProviders) || in_array($providerId, $onlyProviders, true);
}

function runCommand(string $command): string
{
    $descriptor = [['pipe', 'r'], ['pipe', 'w'], ['pipe', 'w']];
    $process = proc_open($command, $descriptor, $pipes);
    if (!is_resource($process)) {
        throw new RuntimeException("無法啟動指令：$command");
    }
    fclose($pipes[0]);
    $stdout = stream_get_contents($pipes[1]);
    $stderr = stream_get_contents($pipes[2]);
    fclose($pipes[1]);
    fclose($pipes[2]);

    $code = proc_close($process);
    if ($code !== 0) {
        throw new RuntimeException(trim((string) ($stderr ?: $stdout)));
    }
    return trim((string) $stdout);
}

function normalizeSrs(string $srs): string
{
    $upper = strtoupper(trim($srs));
    if (str_starts_with($upper, 'EPSG:')) {
        return $upper;
    }
    if ($upper === '3826' || $upper === '3825' || $upper === '4326') {
        return 'EPSG:' . $upper;
    }
    return $upper;
}

function transformPointsTo3826(array $points, string $sourceSrs): array
{
    $sourceSrs = normalizeSrs($sourceSrs);
    if ($sourceSrs === 'EPSG:3826') {
        return $points;
    }

    $input = '';
    foreach ($points as $pt) {
        $input .= sprintf("%.10f %.10f\n", (float) $pt[0], (float) $pt[1]);
    }

    $command = 'gdaltransform -s_srs ' . escapeshellarg($sourceSrs) . ' -t_srs EPSG:3826';
    $descriptor = [['pipe', 'r'], ['pipe', 'w'], ['pipe', 'w']];
    $process = proc_open($command, $descriptor, $pipes);
    if (!is_resource($process)) {
        throw new RuntimeException("無法啟動 gdaltransform：$command");
    }

    fwrite($pipes[0], $input);
    fclose($pipes[0]);
    $stdout = trim((string) stream_get_contents($pipes[1]));
    $stderr = trim((string) stream_get_contents($pipes[2]));
    fclose($pipes[1]);
    fclose($pipes[2]);
    $code = proc_close($process);
    if ($code !== 0 || $stdout === '') {
        throw new RuntimeException("gdaltransform 失敗 [$sourceSrs -> EPSG:3826]：$stderr");
    }

    $lines = preg_split('/\r?\n/', $stdout);
    if (!is_array($lines) || count($lines) < count($points)) {
        throw new RuntimeException("gdaltransform 回傳點數不足：$stdout");
    }

    $out = [];
    for ($i = 0; $i < count($points); $i++) {
        $parts = preg_split('/\s+/', trim((string) $lines[$i]));
        if (!is_array($parts) || count($parts) < 2) {
            throw new RuntimeException("gdaltransform 輸出格式異常：{$lines[$i]}");
        }
        $out[] = [(float) $parts[0], (float) $parts[1]];
    }
    return $out;
}

function wktFromPoints(array $points): string
{
    $ring = [];
    foreach ($points as $pt) {
        $ring[] = number_format((float) $pt[0], 4, '.', '') . ' ' . number_format((float) $pt[1], 4, '.', '');
    }
    if ($ring[0] !== end($ring)) {
        $ring[] = $ring[0];
    }
    return 'POLYGON((' . implode(', ', $ring) . '))';
}

function wktFromBbox(float $minX, float $minY, float $maxX, float $maxY, string $sourceSrs): string
{
    $points = [
        [$minX, $maxY],
        [$minX, $minY],
        [$maxX, $minY],
        [$maxX, $maxY],
    ];
    $points3826 = transformPointsTo3826($points, $sourceSrs);
    return wktFromPoints($points3826);
}

function bboxFromGrdStream($stream): ?array
{
    $minX = null;
    $minY = null;
    $maxX = null;
    $maxY = null;

    while (($line = fgets($stream)) !== false) {
        $line = trim($line);
        if ($line === '') {
            continue;
        }
        $parts = preg_split('/\s+/', $line);
        if (!is_array($parts) || count($parts) < 2) {
            continue;
        }
        if (!is_numeric($parts[0]) || !is_numeric($parts[1])) {
            continue;
        }

        $x = (float) $parts[0];
        $y = (float) $parts[1];

        $minX = ($minX === null || $x < $minX) ? $x : $minX;
        $maxX = ($maxX === null || $x > $maxX) ? $x : $maxX;
        $minY = ($minY === null || $y < $minY) ? $y : $minY;
        $maxY = ($maxY === null || $y > $maxY) ? $y : $maxY;
    }

    if ($minX === null || $minY === null || $maxX === null || $maxY === null) {
        return null;
    }
    return [$minX, $minY, $maxX, $maxY];
}

function bboxFromGrdFile(string $path): ?array
{
    $fp = @fopen($path, 'rb');
    if (!is_resource($fp)) {
        return null;
    }
    $bbox = bboxFromGrdStream($fp);
    fclose($fp);
    return $bbox;
}

function bboxFromZipGrd(string $zipPath, string $entryName): ?array
{
    $zip = new ZipArchive();
    if ($zip->open($zipPath) !== true) {
        return null;
    }
    $stream = $zip->getStream($entryName);
    if (!is_resource($stream)) {
        $zip->close();
        return null;
    }
    $bbox = bboxFromGrdStream($stream);
    fclose($stream);
    $zip->close();
    return $bbox;
}

function readCornersByGdalinfo(string $rasterPath): array
{
    $json = runCommand('gdalinfo -json ' . escapeshellarg($rasterPath));
    $info = json_decode($json, true);
    if (!is_array($info) || !isset($info['cornerCoordinates'])) {
        throw new RuntimeException("gdalinfo 缺少 cornerCoordinates：$rasterPath");
    }

    $corner = $info['cornerCoordinates'];
    $keys = ['upperLeft', 'lowerLeft', 'lowerRight', 'upperRight'];
    $points = [];
    foreach ($keys as $key) {
        if (!isset($corner[$key][0], $corner[$key][1])) {
            throw new RuntimeException("cornerCoordinates 缺欄位：$rasterPath");
        }
        $points[] = [(float) $corner[$key][0], (float) $corner[$key][1]];
    }
    return $points;
}

function collectExtractGrdFiles(string $extractDir): array
{
    if (!is_dir($extractDir)) {
        return [];
    }
    $files = [];
    $it = new RecursiveIteratorIterator(
        new RecursiveDirectoryIterator($extractDir, FilesystemIterator::SKIP_DOTS | FilesystemIterator::FOLLOW_SYMLINKS)
    );
    foreach ($it as $file) {
        if (!$file->isFile()) {
            continue;
        }
        if (strtolower($file->getExtension()) !== 'grd') {
            continue;
        }
        $files[] = $file->getRealPath() ?: $file->getPathname();
    }
    sort($files, SORT_STRING | SORT_FLAG_CASE);
    return $files;
}

function collectZipGrdEntries(string $zipPath): array
{
    if (!is_file($zipPath) || !class_exists('ZipArchive')) {
        return [];
    }
    $zip = new ZipArchive();
    if ($zip->open($zipPath) !== true) {
        return [];
    }
    $entries = [];
    for ($i = 0; $i < $zip->numFiles; $i++) {
        $name = (string) $zip->getNameIndex($i);
        if ($name === '' || str_ends_with($name, '/')) {
            continue;
        }
        if (strtolower(pathinfo($name, PATHINFO_EXTENSION)) === 'grd') {
            $entries[] = $name;
        }
    }
    sort($entries, SORT_STRING | SORT_FLAG_CASE);
    $zip->close();
    return $entries;
}

function writeProviderFile(string $polygonRoot, string $providerId, array $items): void
{
    usort($items, static fn($a, $b) => strcasecmp($a['label'], $b['label']));
    $outPath = $polygonRoot . DIRECTORY_SEPARATOR . $providerId . '.txt';
    file_put_contents($outPath, json_encode($items, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));
}

function mergeMissingItemsByLabel(array $primaryItems, array $fallbackItems): array
{
    $seen = [];
    foreach ($primaryItems as $item) {
        if (isset($item['label'])) {
            $seen[strtolower((string) $item['label'])] = true;
        }
    }

    foreach ($fallbackItems as $item) {
        $label = strtolower((string) ($item['label'] ?? ''));
        if ($label === '' || isset($seen[$label])) {
            continue;
        }
        $primaryItems[] = $item;
        $seen[$label] = true;
    }
    return $primaryItems;
}

function buildItemsFromCountyGrd(string $countyId, string $sourceSrs, string $rawRoot, ?string $rawDirName = null, ?string $zipName = null): array
{
    $items = [];
    $rawDirName = $rawDirName ?? $countyId;
    $zipName = $zipName ?? ($countyId . '-20mdem-2025.zip');
    $extractDir = $rawRoot . DIRECTORY_SEPARATOR . $rawDirName . DIRECTORY_SEPARATOR . 'extract';
    $files = collectExtractGrdFiles($extractDir);

    if (!empty($files)) {
        foreach ($files as $filePath) {
            $bbox = bboxFromGrdFile($filePath);
            if ($bbox === null) {
                continue;
            }
            [$minX, $minY, $maxX, $maxY] = $bbox;
            $items[] = [
                'label' => basename(str_replace('\\', '/', $filePath)),
                'wkt' => wktFromBbox($minX, $minY, $maxX, $maxY, $sourceSrs),
            ];
        }
        return $items;
    }

    // 沒 extract 時才掃 zip（仍走文字解析，避免 gdalinfo 逐檔）
    $zipPath = $rawRoot . DIRECTORY_SEPARATOR . $rawDirName . DIRECTORY_SEPARATOR . $zipName;
    $entries = collectZipGrdEntries($zipPath);
    foreach ($entries as $entry) {
        $bbox = bboxFromZipGrd($zipPath, $entry);
        if ($bbox === null) {
            continue;
        }
        [$minX, $minY, $maxX, $maxY] = $bbox;
        $items[] = [
            'label' => basename(str_replace('\\', '/', $entry)),
            'wkt' => wktFromBbox($minX, $minY, $maxX, $maxY, $sourceSrs),
        ];
    }
    return $items;
}

function buildRawBboxRecordsFromCountyGrd(string $rawRoot, string $rawDirName, string $zipName): array
{
    $records = [];
    $extractDir = $rawRoot . DIRECTORY_SEPARATOR . $rawDirName . DIRECTORY_SEPARATOR . 'extract';
    $files = collectExtractGrdFiles($extractDir);

    if (!empty($files)) {
        foreach ($files as $filePath) {
            $bbox = bboxFromGrdFile($filePath);
            if ($bbox === null) {
                continue;
            }
            $records[] = [
                'label' => basename(str_replace('\\', '/', $filePath)),
                'bbox' => $bbox,
            ];
        }
        return $records;
    }

    $zipPath = $rawRoot . DIRECTORY_SEPARATOR . $rawDirName . DIRECTORY_SEPARATOR . $zipName;
    $entries = collectZipGrdEntries($zipPath);
    foreach ($entries as $entry) {
        $bbox = bboxFromZipGrd($zipPath, $entry);
        if ($bbox === null) {
            continue;
        }
        $records[] = [
            'label' => basename(str_replace('\\', '/', $entry)),
            'bbox' => $bbox,
        ];
    }
    return $records;
}

function bboxFromPointList(array $points): array
{
    $xs = [];
    $ys = [];
    foreach ($points as $pt) {
        $xs[] = (float) $pt[0];
        $ys[] = (float) $pt[1];
    }
    return [min($xs), min($ys), max($xs), max($ys)];
}

function bboxFromRecords(array $records): array
{
    $minX = null;
    $minY = null;
    $maxX = null;
    $maxY = null;
    foreach ($records as $record) {
        $bbox = $record['bbox'];
        $minX = ($minX === null || $bbox[0] < $minX) ? $bbox[0] : $minX;
        $minY = ($minY === null || $bbox[1] < $minY) ? $bbox[1] : $minY;
        $maxX = ($maxX === null || $bbox[2] > $maxX) ? $bbox[2] : $maxX;
        $maxY = ($maxY === null || $bbox[3] > $maxY) ? $bbox[3] : $maxY;
    }
    if ($minX === null || $minY === null || $maxX === null || $maxY === null) {
        throw new RuntimeException("沒有可用 bbox");
    }
    return [$minX, $minY, $maxX, $maxY];
}

function buildPenghuUnifiedItems(string $rawRoot): array
{
    $unifiedTif = $rawRoot . DIRECTORY_SEPARATOR . 'penghu_unified' . DIRECTORY_SEPARATOR . 'extract' . DIRECTORY_SEPARATOR . 'DEM_Penghu_V2025.tif';
    $item = buildUnifiedItem('DEM_Penghu_V2025.tif', $unifiedTif, 'EPSG:3825');
    if ($item === null) {
        return [];
    }
    return [$item];
}

function buildPenghuRawDiagnosticItems(string $rawRoot): array
{
    // 澎湖 2025 分幅 zip 目前疑似錯包；以 3826 顯示可看出實際落在本島山區。
    return buildItemsFromCountyGrd('penghu', 'EPSG:3826', $rawRoot, 'penghu', 'penghu-20mdem-2025.zip');
}

function buildUnifiedItem(string $label, string $rasterPath, string $sourceSrs): ?array
{
    if (!is_file($rasterPath)) {
        return null;
    }
    $corners = readCornersByGdalinfo($rasterPath);
    $transformed = transformPointsTo3826($corners, $sourceSrs);
    return ['label' => $label, 'wkt' => wktFromPoints($transformed)];
}

$allItems = [];
$okCount = 0;
$failCount = 0;

foreach ($counties as $county) {
    if (!isset($county['id'])) {
        continue;
    }
    $countyId = (string) $county['id'];
    if (!shouldRunProvider($countyId, $onlyProviders)) {
        continue;
    }
    $sourceSrs = normalizeSrs((string) ($county['sourceSrs'] ?? 'EPSG:3826'));
    fwrite(STDOUT, "處理 {$countyId} ...\n");

    try {
        if ($countyId === 'penghu') {
            $items = buildPenghuUnifiedItems($rawRoot);
            fwrite(STDOUT, "  澎湖分幅 .grd 疑似錯包，正式 polygon 改用官方不分幅 GeoTIFF bbox\n");
        } else {
            $items = buildItemsFromCountyGrd($countyId, $sourceSrs, $rawRoot);
        }
        if ($countyId === 'miaoli') {
            $miaoliMoiZip = $rawRoot . DIRECTORY_SEPARATOR . 'miaoli_moi' . DIRECTORY_SEPARATOR . 'miaoli-dem-moi.zip';
            if (is_file($miaoliMoiZip)) {
                $fallbackItems = buildItemsFromCountyGrd('miaoli_moi', 'EPSG:3826', $rawRoot, 'miaoli_moi', 'miaoli-dem-moi.zip');
                $beforeCount = count($items);
                $items = mergeMissingItemsByLabel($items, $fallbackItems);
                fwrite(STDOUT, "  苗栗使用內政部 DEM 補 " . (count($items) - $beforeCount) . " 筆缺格\n");
            }
        }
        writeProviderFile($polygonRoot, $countyId, $items);
        $allItems = array_merge($allItems, $items);
        $okCount += count($items);
        fwrite(STDOUT, "  完成 {$countyId}: " . count($items) . " 筆\n");
    } catch (Throwable $ex) {
        $failCount++;
        fwrite(STDERR, "WARN [{$countyId}] {$ex->getMessage()}\n");
    }
}

// taiwan: 官方不分幅主島
$taiwanRaster = $workRoot . DIRECTORY_SEPARATOR . 'taiwan_unified' . DIRECTORY_SEPARATOR . 'taiwan_unified-4326.tif';
$taiwanItems = [];
if (shouldRunProvider('taiwan', $onlyProviders)) {
    try {
        $item = buildUnifiedItem('taiwan_unified-4326.tif', $taiwanRaster, 'EPSG:4326');
        if ($item !== null) {
            $taiwanItems[] = $item;
            $allItems[] = $item;
            $okCount++;
        }
    } catch (Throwable $ex) {
        $failCount++;
        fwrite(STDERR, "WARN [taiwan] {$ex->getMessage()}\n");
    }
    writeProviderFile($polygonRoot, 'taiwan', $taiwanItems);
}

// all_taiwan: 先吃 output/all_taiwan/build-manifest.json bbox（最快且穩定）
$allTaiwanItems = [];
if (shouldRunProvider('all_taiwan', $onlyProviders)) {
    try {
        $manifestPath = $baseDir . DIRECTORY_SEPARATOR . 'output' . DIRECTORY_SEPARATOR . 'all_taiwan' . DIRECTORY_SEPARATOR . 'build-manifest.json';
        if (is_file($manifestPath)) {
            $manifest = json_decode((string) file_get_contents($manifestPath), true);
            if (is_array($manifest) && isset($manifest['bbox'][0], $manifest['bbox'][1], $manifest['bbox'][2], $manifest['bbox'][3])) {
                $bbox = $manifest['bbox'];
                $allTaiwanItems[] = [
                    'label' => 'all_taiwan',
                    'wkt' => wktFromBbox((float) $bbox[0], (float) $bbox[1], (float) $bbox[2], (float) $bbox[3], 'EPSG:4326'),
                ];
            }
        }

        if (empty($allTaiwanItems)) {
            $allTaiwanRaster = $workRoot . DIRECTORY_SEPARATOR . 'all_taiwan' . DIRECTORY_SEPARATOR . 'all_taiwan.vrt';
            $item = buildUnifiedItem('all_taiwan.vrt', $allTaiwanRaster, 'EPSG:4326');
            if ($item !== null) {
                $allTaiwanItems[] = $item;
            }
        }

        foreach ($allTaiwanItems as $it) {
            $allItems[] = $it;
            $okCount++;
        }
    } catch (Throwable $ex) {
        $failCount++;
        fwrite(STDERR, "WARN [all_taiwan] {$ex->getMessage()}\n");
    }
    writeProviderFile($polygonRoot, 'all_taiwan', $allTaiwanItems);
}

// 額外比較來源：2024 苗栗，用來確認 2025 官方空窗是否可由舊版補齊
$miaoli2024Zip = $rawRoot . DIRECTORY_SEPARATOR . 'miaoli_2024' . DIRECTORY_SEPARATOR . 'miaoli-20mdem-2024.zip';
if (is_file($miaoli2024Zip) && shouldRunProvider('miaoli_2024', $onlyProviders)) {
    try {
        fwrite(STDOUT, "處理 miaoli_2024 ...\n");
        $items = buildItemsFromCountyGrd('miaoli_2024', 'EPSG:3826', $rawRoot, 'miaoli_2024', 'miaoli-20mdem-2024.zip');
        writeProviderFile($polygonRoot, 'miaoli_2024', $items);
        $allItems = array_merge($allItems, $items);
        $okCount += count($items);
        fwrite(STDOUT, "  完成 miaoli_2024: " . count($items) . " 筆\n");
    } catch (Throwable $ex) {
        $failCount++;
        fwrite(STDERR, "WARN [miaoli_2024] {$ex->getMessage()}\n");
    }
}

// 額外比較來源：data.gov.tw/dataset/35430 的內政部舊版苗栗 DEM
$miaoliMoiZip = $rawRoot . DIRECTORY_SEPARATOR . 'miaoli_moi' . DIRECTORY_SEPARATOR . 'miaoli-dem-moi.zip';
if (is_file($miaoliMoiZip) && shouldRunProvider('miaoli_moi', $onlyProviders)) {
    try {
        fwrite(STDOUT, "處理 miaoli_moi ...\n");
        $items = buildItemsFromCountyGrd('miaoli_moi', 'EPSG:3826', $rawRoot, 'miaoli_moi', 'miaoli-dem-moi.zip');
        writeProviderFile($polygonRoot, 'miaoli_moi', $items);
        $allItems = array_merge($allItems, $items);
        $okCount += count($items);
        fwrite(STDOUT, "  完成 miaoli_moi: " . count($items) . " 筆\n");
    } catch (Throwable $ex) {
        $failCount++;
        fwrite(STDERR, "WARN [miaoli_moi] {$ex->getMessage()}\n");
    }
}

// 額外比較來源：data.gov.tw/dataset/35430 的內政部舊版澎湖 DEM
$penghuMoiZip = $rawRoot . DIRECTORY_SEPARATOR . 'penghu_moi' . DIRECTORY_SEPARATOR . 'penghu-dem-moi.zip';
if (is_file($penghuMoiZip) && shouldRunProvider('penghu_moi', $onlyProviders)) {
    try {
        fwrite(STDOUT, "處理 penghu_moi ...\n");
        $items = buildItemsFromCountyGrd('penghu_moi', 'EPSG:3825', $rawRoot, 'penghu_moi', 'penghu-dem-moi.zip');
        writeProviderFile($polygonRoot, 'penghu_moi', $items);
        $allItems = array_merge($allItems, $items);
        $okCount += count($items);
        fwrite(STDOUT, "  完成 penghu_moi: " . count($items) . " 筆\n");
    } catch (Throwable $ex) {
        $failCount++;
        fwrite(STDERR, "WARN [penghu_moi] {$ex->getMessage()}\n");
    }
}

// 額外診斷來源：澎湖 2025 分幅 zip 疑似為南投山區資料子集，保留原始落點方便比對
if (shouldRunProvider('penghu_grd_raw', $onlyProviders)) {
    try {
        fwrite(STDOUT, "處理 penghu_grd_raw ...\n");
        $items = buildPenghuRawDiagnosticItems($rawRoot);
        writeProviderFile($polygonRoot, 'penghu_grd_raw', $items);
        $okCount += count($items);
        fwrite(STDOUT, "  完成 penghu_grd_raw: " . count($items) . " 筆\n");
    } catch (Throwable $ex) {
        $failCount++;
        fwrite(STDERR, "WARN [penghu_grd_raw] {$ex->getMessage()}\n");
    }
}

if (empty($onlyProviders)) {
    usort($allItems, static fn($a, $b) => strcasecmp($a['label'], $b['label']));
    file_put_contents($summaryOutput, json_encode($allItems, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));
}

fwrite(STDOUT, "完成：{$okCount} 筆 bbox；警告：{$failCount}\n");
fwrite(STDOUT, "輸出資料夾：{$polygonRoot}\n");
if (empty($onlyProviders)) {
    fwrite(STDOUT, "彙總檔：{$summaryOutput}\n");
}
