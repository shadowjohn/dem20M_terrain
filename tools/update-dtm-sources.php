<?php
declare(strict_types=1);

/**
 * 從 data.gov.tw / opdadm.moi.gov.tw 的官方 CSV 重新產生 DTM source registry。
 *
 * V2 只把 2025 DTM 納入正式 registry。
 * 2024 與內政部 OLD 來源只留作歷史診斷，不再產生正式補洞來源。
 */

setlocale(LC_ALL, 'C');

$repoRoot = dirname(__DIR__);
$options = parseCliOptions($argv);
$datasetsPath = resolvePath((string) ($options['datasets'] ?? 'config/dtm_source_datasets.json'), $repoRoot);
$outPath = resolvePath((string) ($options['out'] ?? 'config/dtm_sources.json'), $repoRoot);
$csvDir = resolvePath((string) ($options['csv-dir'] ?? 'data/source-catalog'), $repoRoot);
$useCache = isset($options['use-cache']);

if (!is_file($datasetsPath)) {
    fwrite(STDERR, "ERROR: 找不到 dataset registry：{$datasetsPath}\n");
    exit(1);
}

$registry = json_decode((string) file_get_contents($datasetsPath), true);
if (!is_array($registry) || !isset($registry['datasets']) || !is_array($registry['datasets'])) {
    fwrite(STDERR, "ERROR: dataset registry 格式錯誤，必須包含 datasets 陣列\n");
    exit(1);
}

ensureDir($csvDir);

$sources = [];
$datasetSummaries = [];
foreach ($registry['datasets'] as $dataset) {
    if (!is_array($dataset) || array_key_exists('enabled', $dataset) && !$dataset['enabled']) {
        continue;
    }
    $datasetId = (string) ($dataset['id'] ?? '');
    $csvUrl = (string) ($dataset['csvUrl'] ?? '');
    if ($datasetId === '' || $csvUrl === '') {
        throw new RuntimeException('dataset id 與 csvUrl 不可為空');
    }

    $csvPath = $csvDir . DIRECTORY_SEPARATOR . $datasetId . '.csv';
    $csvText = loadCsv($csvUrl, $csvPath, $useCache);
    $rows = parseCsv($csvText);
    $count = 0;
    foreach ($rows as $row) {
        $source = sourceFromCsvRow($dataset, $row);
        if ($source === null) {
            continue;
        }
        $sources[$source['id']] = $source;
        $count++;
    }
    $datasetSummaries[] = [
        'id' => $datasetId,
        'label' => (string) ($dataset['label'] ?? $datasetId),
        'version' => (string) ($dataset['version'] ?? ''),
        'dataGovUrl' => (string) ($dataset['dataGovUrl'] ?? ''),
        'alternateDataGovUrl' => (string) ($dataset['alternateDataGovUrl'] ?? ''),
        'csvUrl' => $csvUrl,
        'csvCache' => relativePath($csvPath, $repoRoot),
        'sourceCount' => $count,
    ];
}

$sources['dtm_global_reserved'] = [
    'id' => 'dtm_global_reserved',
    'name' => 'ASTER / SRTM / COPDEM reserved fallback',
    'version' => 'GLOBAL_RESERVED',
    'priority' => 4,
    'role' => 'reserved',
    'countyId' => 'global',
    'countyName' => '全球 DEM 預留',
    'sourceSrs' => 'EPSG:4326',
    'zipPath' => '',
    'extractPath' => '',
    'url' => '',
    'enabled' => false,
    'downloadEnabled' => false,
    'note' => 'V1 只保留 schema 欄位，不下載、不掃描全球 DEM。',
];

uasort($sources, 'compareSource');

$out = [
    'schemaVersion' => 1,
    'policy' => '2025_ONLY',
    'description' => 'DTM 2025-only source registry；由官方 CSV 產生，正式 terrain 不再混用 2024 或內政部 OLD 補洞。',
    'generatedAt' => gmdate('c'),
    'datasets' => $datasetSummaries,
    'sources' => array_values($sources),
];

ensureDir(dirname($outPath));
writeJson($outPath, $out);

fwrite(STDOUT, "DTM source registry 已更新：sources=" . count($out['sources']) . "\n");
fwrite(STDOUT, "輸出：{$outPath}\n");

function parseCliOptions(array $argv): array
{
    $out = [];
    for ($i = 1; $i < count($argv); $i++) {
        $arg = (string) $argv[$i];
        if (!str_starts_with($arg, '--')) {
            continue;
        }
        $arg = substr($arg, 2);
        if (str_contains($arg, '=')) {
            [$key, $value] = explode('=', $arg, 2);
            $out[$key] = $value;
            continue;
        }
        $next = $argv[$i + 1] ?? null;
        if ($next !== null && !str_starts_with((string) $next, '--')) {
            $out[$arg] = (string) $next;
            $i++;
        } else {
            $out[$arg] = true;
        }
    }
    return $out;
}

function ensureDir(string $path): void
{
    if ($path === '' || is_dir($path)) {
        return;
    }
    if (!mkdir($path, 0777, true) && !is_dir($path)) {
        throw new RuntimeException("建立目錄失敗：{$path}");
    }
}

function resolvePath(string $path, string $repoRoot): string
{
    if ($path === '') {
        return $path;
    }
    if (preg_match('/^[A-Za-z]:[\\\\\\/]/', $path) === 1 || str_starts_with($path, '\\\\') || str_starts_with($path, '/')) {
        return $path;
    }
    return $repoRoot . DIRECTORY_SEPARATOR . str_replace(['/', '\\'], DIRECTORY_SEPARATOR, $path);
}

function relativePath(string $path, string $repoRoot): string
{
    $normalizedPath = str_replace('\\', '/', $path);
    $normalizedRoot = rtrim(str_replace('\\', '/', $repoRoot), '/') . '/';
    if (str_starts_with($normalizedPath, $normalizedRoot)) {
        return substr($normalizedPath, strlen($normalizedRoot));
    }
    return $normalizedPath;
}

function loadCsv(string $url, string $cachePath, bool $useCache): string
{
    if ($useCache && is_file($cachePath)) {
        return (string) file_get_contents($cachePath);
    }

    $context = stream_context_create([
        'http' => [
            'timeout' => 120,
            'header' => "User-Agent: dem20M-terrain-source-sync/1.0\r\n",
        ],
    ]);
    $text = file_get_contents($url, false, $context);
    if ($text === false || trim($text) === '') {
        throw new RuntimeException("下載 CSV 失敗：{$url}");
    }
    file_put_contents($cachePath, $text);
    return $text;
}

function parseCsv(string $text): array
{
    $text = preg_replace('/^\xEF\xBB\xBF/', '', $text) ?? $text;
    $lines = preg_split('/\r\n|\n|\r/', $text) ?: [];
    $headers = null;
    $rows = [];
    foreach ($lines as $line) {
        if (trim($line) === '') {
            continue;
        }
        $cols = str_getcsv($line);
        if ($headers === null) {
            $headers = array_map(static fn($value) => trim((string) $value), $cols);
            continue;
        }
        $row = [];
        foreach ($headers as $idx => $header) {
            $row[$header] = isset($cols[$idx]) ? trim((string) $cols[$idx]) : '';
        }
        $rows[] = $row;
    }
    return $rows;
}

function sourceFromCsvRow(array $dataset, array $row): ?array
{
    $mapName = (string) ($row['圖資名稱'] ?? '');
    $url = (string) ($row['連結網址'] ?? '');
    if ($mapName === '' || $url === '' || !str_ends_with(strtolower($url), '.zip')) {
        return null;
    }
    if (stripos($mapName, 'schema_hdr') !== false) {
        return null;
    }

    $version = (string) ($dataset['version'] ?? '');
    $priority = (int) ($dataset['priority'] ?? 999);
    $defaultRole = (string) ($dataset['defaultRole'] ?? 'fallback');
    $datasetId = (string) ($dataset['id'] ?? '');
    $dataGovUrl = (string) ($dataset['dataGovUrl'] ?? '');

    $isSplit = str_starts_with($mapName, '分幅_');
    $isUnified = str_starts_with($mapName, '不分幅_');
    if (!$isSplit && !$isUnified) {
        return null;
    }

    if ($isSplit) {
        $countyName = extractSplitCountyName($mapName);
        $county = countyInfo($countyName);
        if ($county === null) {
            return null;
        }
        $countyId = $county['id'];
        $role = $defaultRole;
        $sourcePriority = $priority;
        $id = 'dtm_' . strtolower($version) . '_' . $countyId;
        $note = '';
        if ($version === '2025' && in_array($countyId, ['penghu', 'kinmen'], true)) {
            $role = 'diagnostic';
            $sourcePriority = 90;
            $id .= '_split_diagnostic';
            $note = $countyName . ' 2025 分幅保留為診斷來源；正式 coverage/best-source 以不分幅離島來源為準。';
        }
        if ($version === 'OLD') {
            $id = 'dtm_old_' . $countyId;
        }
        [$zipPath, $extractPath] = sourcePaths($version, $countyId, false, $mapName);
        return buildSource($id, $mapName, $version, $sourcePriority, $role, $countyId, $countyName, $county['sourceSrs'], $zipPath, $extractPath, $url, $datasetId, $dataGovUrl, true, true, $note);
    }

    $unified = unifiedInfo($mapName, $version);
    if ($unified === null) {
        return null;
    }

    $role = $unified['role'];
    $sourcePriority = $unified['priority'] ?? $priority;
    $enabled = $unified['enabled'];
    $downloadEnabled = $unified['downloadEnabled'];
    [$zipPath, $extractPath] = sourcePaths($version, $unified['countyId'], true, $mapName);

    return buildSource(
        $unified['id'],
        $mapName,
        $version,
        $sourcePriority,
        $role,
        $unified['countyId'],
        $unified['countyName'],
        $unified['sourceSrs'],
        $zipPath,
        $extractPath,
        $url,
        $datasetId,
        $dataGovUrl,
        $enabled,
        $downloadEnabled,
        $unified['note']
    );
}

function extractSplitCountyName(string $mapName): string
{
    if (preg_match('/^分幅_(.+?)(?:20MDEM|DEM)/u', $mapName, $m) === 1) {
        return $m[1];
    }
    return '';
}

function countyInfo(string $countyName): ?array
{
    $map = [
        '基隆市' => ['id' => 'keelung', 'slug' => 'keelung', 'sourceSrs' => 'EPSG:3826'],
        '臺北市' => ['id' => 'taipei', 'slug' => 'taipei', 'sourceSrs' => 'EPSG:3826'],
        '新北市' => ['id' => 'newtaipei', 'slug' => 'newtaipei', 'sourceSrs' => 'EPSG:3826'],
        '桃園市' => ['id' => 'taoyuan', 'slug' => 'taoyuan', 'sourceSrs' => 'EPSG:3826'],
        '新竹縣' => ['id' => 'hsinchu_county', 'slug' => 'hsinchu_county', 'sourceSrs' => 'EPSG:3826'],
        '新竹市' => ['id' => 'hsinchu_city', 'slug' => 'hsinchu_city', 'sourceSrs' => 'EPSG:3826'],
        '苗栗縣' => ['id' => 'miaoli', 'slug' => 'miaoli', 'sourceSrs' => 'EPSG:3826'],
        '臺中市' => ['id' => 'taichung', 'slug' => 'taichung', 'sourceSrs' => 'EPSG:3826'],
        '彰化縣' => ['id' => 'changhua', 'slug' => 'changhua', 'sourceSrs' => 'EPSG:3826'],
        '南投縣' => ['id' => 'nantou', 'slug' => 'nantou', 'sourceSrs' => 'EPSG:3826'],
        '雲林縣' => ['id' => 'yunlin', 'slug' => 'yunlin', 'sourceSrs' => 'EPSG:3826'],
        '嘉義縣' => ['id' => 'chiayi_county', 'slug' => 'chiayi_county', 'sourceSrs' => 'EPSG:3826'],
        '嘉義市' => ['id' => 'chiayi_city', 'slug' => 'chiayi_city', 'sourceSrs' => 'EPSG:3826'],
        '臺南市' => ['id' => 'tainan', 'slug' => 'tainan', 'sourceSrs' => 'EPSG:3826'],
        '高雄市' => ['id' => 'kaohsiung', 'slug' => 'kaohsiung', 'sourceSrs' => 'EPSG:3826'],
        '屏東縣' => ['id' => 'pingtung', 'slug' => 'pingtung', 'sourceSrs' => 'EPSG:3826'],
        '宜蘭縣' => ['id' => 'yilan', 'slug' => 'yilan', 'sourceSrs' => 'EPSG:3826'],
        '花蓮縣' => ['id' => 'hualien', 'slug' => 'hualien', 'sourceSrs' => 'EPSG:3826'],
        '臺東縣' => ['id' => 'taitung', 'slug' => 'taitung', 'sourceSrs' => 'EPSG:3826'],
        '澎湖縣' => ['id' => 'penghu', 'slug' => 'penghu', 'sourceSrs' => 'EPSG:3825'],
        '金門縣' => ['id' => 'kinmen', 'slug' => 'kinmen', 'sourceSrs' => 'EPSG:3825'],
    ];
    return $map[$countyName] ?? null;
}

function countySlug(string $countyId): string
{
    foreach (['基隆市', '臺北市', '新北市', '桃園市', '新竹縣', '新竹市', '苗栗縣', '臺中市', '彰化縣', '南投縣', '雲林縣', '嘉義縣', '嘉義市', '臺南市', '高雄市', '屏東縣', '宜蘭縣', '花蓮縣', '臺東縣', '澎湖縣', '金門縣'] as $name) {
        $info = countyInfo($name);
        if ($info !== null && $info['id'] === $countyId) {
            return $info['slug'];
        }
    }
    return $countyId;
}

function unifiedInfo(string $mapName, string $version): ?array
{
    if (str_contains($mapName, '金門')) {
        return [
            'id' => 'dtm_' . strtolower($version) . '_kinmen',
            'countyId' => 'kinmen',
            'countyName' => '金門縣',
            'sourceSrs' => 'EPSG:3825',
            'role' => $version === '2025' ? 'primary' : 'fallback',
            'priority' => $version === '2025' ? 1 : 2,
            'enabled' => true,
            'downloadEnabled' => true,
            'note' => '',
        ];
    }
    if (str_contains($mapName, '澎湖') && !str_contains($mapName, '全台及澎湖')) {
        return [
            'id' => 'dtm_' . strtolower($version) . '_penghu',
            'countyId' => 'penghu',
            'countyName' => '澎湖縣',
            'sourceSrs' => 'EPSG:3825',
            'role' => $version === '2025' ? 'primary' : 'fallback',
            'priority' => $version === '2025' ? 1 : 2,
            'enabled' => true,
            'downloadEnabled' => true,
            'note' => '',
        ];
    }
    if (str_contains($mapName, '全台') || str_contains($mapName, '台灣')) {
        $isOldMixed = $version === 'OLD' && str_contains($mapName, '全台及澎湖');
        return [
            'id' => $version === 'OLD' ? 'dtm_old_taiwan_penghu_unified' : 'dtm_' . strtolower($version) . '_taiwan_unified',
            'countyId' => $isOldMixed ? 'all_taiwan' : 'taiwan',
            'countyName' => $isOldMixed ? '全臺含澎湖' : '全臺主島',
            'sourceSrs' => 'EPSG:3826',
            'role' => 'reference',
            'priority' => $version === 'OLD' ? 3 : (int) $version,
            'enabled' => false,
            'downloadEnabled' => true,
            'note' => $isOldMixed ? '內政部不分幅全台及澎湖 zip 內混有 119/121 分帶 GeoTIFF，先下載保留，不納入 bbox best-source 掃描。' : '',
        ];
    }
    return null;
}

function sourcePaths(string $version, string $countyId, bool $isUnified, string $mapName): array
{
    $slug = countySlug($countyId);
    if ($version === 'OLD') {
        if ($isUnified) {
            $dir = 'data/raw/taiwan_moi_unified';
            $zip = 'taiwan-and-penghu-dem-moi.zip';
        } else {
            $dir = 'data/raw/' . $slug . '_moi';
            $zip = $slug . '-dem-moi.zip';
        }
        return [$dir . '/' . $zip, $dir . '/extract'];
    }

    if ($isUnified) {
        if ($countyId === 'taiwan') {
            $dir = $version === '2025' ? 'data/raw/taiwan_unified' : 'data/raw/taiwan_' . strtolower($version) . '_unified';
            $zip = 'taiwan_unified-20mdem-' . strtolower($version) . '.zip';
        } else {
            $dir = $version === '2025' ? 'data/raw/' . $slug . '_unified' : 'data/raw/' . $slug . '_' . strtolower($version) . '_unified';
            $zip = $slug . '_unified-20mdem-' . strtolower($version) . '.zip';
        }
        return [$dir . '/' . $zip, $dir . '/extract'];
    }

    $dir = $version === '2025' ? 'data/raw/' . $slug : 'data/raw/' . $slug . '_' . strtolower($version);
    $zip = $slug . '-20mdem-' . strtolower($version) . '.zip';
    return [$dir . '/' . $zip, $dir . '/extract'];
}

function buildSource(
    string $id,
    string $mapName,
    string $version,
    int $priority,
    string $role,
    string $countyId,
    string $countyName,
    string $sourceSrs,
    string $zipPath,
    string $extractPath,
    string $url,
    string $datasetId,
    string $dataGovUrl,
    bool $enabled,
    bool $downloadEnabled,
    string $note
): array {
    $displayVersion = $version === 'OLD' ? '內政部 OLD' : $version;
    return [
        'id' => $id,
        'name' => $countyName . ' ' . $displayVersion . ' DTM ' . (str_starts_with($mapName, '不分幅_') ? '不分幅' : '分幅'),
        'mapName' => $mapName,
        'version' => $version,
        'priority' => $priority,
        'role' => $role,
        'countyId' => $countyId,
        'countyName' => $countyName,
        'sourceSrs' => $sourceSrs,
        'zipPath' => $zipPath,
        'extractPath' => $extractPath,
        'url' => $url,
        'datasetId' => $datasetId,
        'dataGovUrl' => $dataGovUrl,
        'enabled' => $enabled,
        'downloadEnabled' => $downloadEnabled,
        'note' => $note,
    ];
}

function compareSource(array $a, array $b): int
{
    $versionOrder = ['2025' => 1, '2024' => 2, 'OLD' => 3, 'GLOBAL_RESERVED' => 99];
    $av = $versionOrder[$a['version']] ?? 50;
    $bv = $versionOrder[$b['version']] ?? 50;
    if ($av !== $bv) {
        return $av <=> $bv;
    }
    if ((int) $a['priority'] !== (int) $b['priority']) {
        return (int) $a['priority'] <=> (int) $b['priority'];
    }
    return strcmp((string) $a['id'], (string) $b['id']);
}

function writeJson(string $path, array $value): void
{
    $json = json_encode($value, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    if ($json === false) {
        throw new RuntimeException('JSON encode failed: ' . json_last_error_msg());
    }
    file_put_contents($path, $json . PHP_EOL);
}
