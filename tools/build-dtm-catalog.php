<?php
declare(strict_types=1);

/**
 * DTM 版本整併庫 V1：
 * - 只做來源盤點與 tile bbox coverage
 * - 本工具不下載、不重建 terrain、不產 NoData polygon
 */

setlocale(LC_ALL, 'C');

$repoRoot = dirname(__DIR__);
$options = parseCliOptions($argv);
$sourcePath = resolvePath((string) ($options['source'] ?? 'config/dtm_sources.json'), $repoRoot);
$dbPath = resolvePath((string) ($options['db'] ?? 'data/catalog/dtm_inventory.sqlite'), $repoRoot);
$coverageDir = resolvePath((string) ($options['coverage-dir'] ?? 'data/coverage'), $repoRoot);
$coverageOnly = isset($options['coverage-only']);

if (!is_file($sourcePath)) {
    fwrite(STDERR, "ERROR: 找不到 source registry：{$sourcePath}\n");
    exit(1);
}

$registry = json_decode((string) file_get_contents($sourcePath), true);
if (!is_array($registry) || !isset($registry['sources']) || !is_array($registry['sources'])) {
    fwrite(STDERR, "ERROR: source registry 格式錯誤，必須包含 sources 陣列\n");
    exit(1);
}

ensureDir(dirname($dbPath));
ensureDir($coverageDir);
if ($coverageOnly) {
    if (!is_file($dbPath)) {
        fwrite(STDERR, "ERROR: coverage-only 找不到 SQLite：{$dbPath}\n");
        exit(1);
    }
    $pdo = new PDO('sqlite:' . $dbPath);
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    $generatedAt = gmdate('c');
    $sourceSummaries = sourceSummariesFromDatabase($pdo);
    writeCoverageJson($pdo, $coverageDir, $sourceSummaries, $generatedAt, $sourcePath, $dbPath);
    fwrite(STDOUT, "Coverage JSON 已刷新：sources=" . count($sourceSummaries) . "\n");
    fwrite(STDOUT, "Coverage：{$coverageDir}\n");
    exit(0);
}

if (is_file($dbPath)) {
    unlink($dbPath);
}

$pdo = new PDO('sqlite:' . $dbPath);
$pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
$pdo->exec('PRAGMA journal_mode = WAL');
$pdo->exec('PRAGMA synchronous = NORMAL');

createSchema($pdo);

$generatedAt = gmdate('c');
$sourceSummaries = [];
$totalTiles = 0;

$pdo->beginTransaction();
foreach ($registry['sources'] as $source) {
    if (!is_array($source)) {
        continue;
    }

    $normalized = normalizeSource($source, $repoRoot, $generatedAt);
    insertSource($pdo, $normalized);

    if (!$normalized['enabled']) {
        $sourceSummaries[] = summaryFromSource($normalized, 0, false, 'disabled');
        continue;
    }

    $scanRoot = chooseScanRoot($normalized);
    if ($scanRoot === null) {
        $sourceSummaries[] = summaryFromSource($normalized, 0, false, 'missing source path');
        continue;
    }

    $tiles = scanSourceTiles($normalized, $scanRoot);
    foreach ($tiles as $tile) {
        insertTile($pdo, $tile);
    }
    markSourceAvailable($pdo, $normalized['id'], true);
    $tileCount = count($tiles);
    $totalTiles += $tileCount;
    $sourceSummaries[] = summaryFromSource($normalized, $tileCount, true, '');
}
$pdo->commit();

createViews($pdo);
writeCoverageJson($pdo, $coverageDir, $sourceSummaries, $generatedAt, $sourcePath, $dbPath);

fwrite(STDOUT, "DTM catalog 完成：sources=" . count($sourceSummaries) . ", tiles={$totalTiles}\n");
fwrite(STDOUT, "SQLite：{$dbPath}\n");
fwrite(STDOUT, "Coverage：{$coverageDir}\n");

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

function normalizeSource(array $source, string $repoRoot, string $generatedAt): array
{
    $id = trim((string) ($source['id'] ?? ''));
    if ($id === '') {
        throw new RuntimeException('source id 不可為空');
    }
    $sourceSrs = normalizeSrs((string) ($source['sourceSrs'] ?? $source['epsg'] ?? 'EPSG:3826'));
    return [
        'id' => $id,
        'name' => (string) ($source['name'] ?? $id),
        'version' => (string) ($source['version'] ?? ''),
        'priority' => (int) ($source['priority'] ?? 999),
        'role' => (string) ($source['role'] ?? 'fallback'),
        'county_id' => (string) ($source['countyId'] ?? $source['county_id'] ?? ''),
        'county_name' => (string) ($source['countyName'] ?? $source['county_name'] ?? ''),
        'source_srs' => $sourceSrs,
        'zip_path' => isset($source['zipPath']) ? resolvePath((string) $source['zipPath'], $repoRoot) : '',
        'extract_path' => isset($source['extractPath']) ? resolvePath((string) $source['extractPath'], $repoRoot) : '',
        'url' => (string) ($source['url'] ?? ''),
        'enabled' => !array_key_exists('enabled', $source) || (bool) $source['enabled'],
        'note' => (string) ($source['note'] ?? ''),
        'scanned_at' => $generatedAt,
    ];
}

function normalizeSrs(string $srs): string
{
    $upper = strtoupper(trim($srs));
    if ($upper === '') {
        return 'EPSG:3826';
    }
    if (str_starts_with($upper, 'EPSG:')) {
        return $upper;
    }
    if (preg_match('/^\d+$/', $upper) === 1) {
        return 'EPSG:' . $upper;
    }
    return $upper;
}

function chooseScanRoot(array $source): ?array
{
    if ($source['extract_path'] !== '' && is_dir($source['extract_path'])) {
        return ['type' => 'dir', 'path' => $source['extract_path']];
    }
    if ($source['zip_path'] !== '' && is_file($source['zip_path'])) {
        return ['type' => 'zip', 'path' => $source['zip_path']];
    }
    return null;
}

function createSchema(PDO $pdo): void
{
    $pdo->exec(<<<'SQL'
CREATE TABLE dtm_sources (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    version TEXT NOT NULL,
    priority INTEGER NOT NULL,
    role TEXT NOT NULL,
    county_id TEXT NOT NULL,
    county_name TEXT NOT NULL,
    source_srs TEXT NOT NULL,
    zip_path TEXT NOT NULL,
    extract_path TEXT NOT NULL,
    url TEXT NOT NULL,
    enabled INTEGER NOT NULL,
    is_available INTEGER NOT NULL DEFAULT 0,
    note TEXT NOT NULL,
    scanned_at TEXT NOT NULL
);

CREATE TABLE dtm_tiles (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source_id TEXT NOT NULL,
    county_id TEXT NOT NULL,
    county_name TEXT NOT NULL,
    version TEXT NOT NULL,
    priority INTEGER NOT NULL,
    role TEXT NOT NULL,
    tile_key TEXT NOT NULL,
    label TEXT NOT NULL,
    file_name TEXT NOT NULL,
    entry_name TEXT NOT NULL,
    format TEXT NOT NULL,
    source_srs TEXT NOT NULL,
    epsg TEXT NOT NULL,
    min_x REAL NOT NULL,
    min_y REAL NOT NULL,
    max_x REAL NOT NULL,
    max_y REAL NOT NULL,
    wkt TEXT NOT NULL,
    resolution_x REAL,
    resolution_y REAL,
    nodata TEXT NOT NULL,
    md5 TEXT NOT NULL,
    bytes INTEGER NOT NULL,
    scanned_at TEXT NOT NULL,
    UNIQUE(source_id, entry_name)
);

CREATE INDEX idx_dtm_tiles_county_tile ON dtm_tiles(county_id, tile_key);
CREATE INDEX idx_dtm_tiles_source ON dtm_tiles(source_id);
SQL);
}

function createViews(PDO $pdo): void
{
    $pdo->exec(<<<'SQL'
CREATE VIEW v_tile_best_source AS
SELECT t.*
FROM dtm_tiles t
JOIN dtm_sources s ON s.id = t.source_id
WHERE s.enabled = 1
  AND s.role IN ('primary', 'fallback')
  AND NOT EXISTS (
      SELECT 1
      FROM dtm_tiles other
      JOIN dtm_sources os ON os.id = other.source_id
      WHERE other.county_id = t.county_id
        AND other.tile_key = t.tile_key
        AND os.enabled = 1
        AND os.role IN ('primary', 'fallback')
        AND (
            other.priority < t.priority
            OR (other.priority = t.priority AND other.source_id < t.source_id)
        )
  );

CREATE VIEW v_missing_primary_fallback AS
SELECT t.*
FROM dtm_tiles t
JOIN dtm_sources s ON s.id = t.source_id
WHERE s.enabled = 1
  AND s.role = 'fallback'
  AND NOT EXISTS (
      SELECT 1
      FROM dtm_tiles p
      JOIN dtm_sources ps ON ps.id = p.source_id
      WHERE p.county_id = t.county_id
        AND p.tile_key = t.tile_key
        AND ps.enabled = 1
        AND ps.role = 'primary'
  );

CREATE VIEW v_overlap_tiles AS
SELECT
    county_id,
    county_name,
    tile_key,
    COUNT(DISTINCT source_id) AS source_count,
    GROUP_CONCAT(source_id, ',') AS source_ids,
    MIN(priority) AS best_priority
FROM dtm_tiles
WHERE role IN ('primary', 'fallback')
GROUP BY county_id, tile_key
HAVING COUNT(DISTINCT source_id) > 1;

CREATE VIEW v_coverage_summary AS
SELECT
    s.id AS source_id,
    s.name,
    s.version,
    s.priority,
    s.role,
    s.county_id,
    s.county_name,
    s.enabled,
    s.is_available,
    COUNT(t.id) AS tile_count,
    SUM(t.bytes) AS total_bytes
FROM dtm_sources s
LEFT JOIN dtm_tiles t ON t.source_id = s.id
GROUP BY s.id;
SQL);
}

function insertSource(PDO $pdo, array $source): void
{
    $stmt = $pdo->prepare(<<<'SQL'
INSERT INTO dtm_sources (
    id, name, version, priority, role, county_id, county_name, source_srs,
    zip_path, extract_path, url, enabled, is_available, note, scanned_at
) VALUES (
    :id, :name, :version, :priority, :role, :county_id, :county_name, :source_srs,
    :zip_path, :extract_path, :url, :enabled, 0, :note, :scanned_at
)
SQL);
    $stmt->execute([
        ':id' => $source['id'],
        ':name' => $source['name'],
        ':version' => $source['version'],
        ':priority' => $source['priority'],
        ':role' => $source['role'],
        ':county_id' => $source['county_id'],
        ':county_name' => $source['county_name'],
        ':source_srs' => $source['source_srs'],
        ':zip_path' => $source['zip_path'],
        ':extract_path' => $source['extract_path'],
        ':url' => $source['url'],
        ':enabled' => $source['enabled'] ? 1 : 0,
        ':note' => $source['note'],
        ':scanned_at' => $source['scanned_at'],
    ]);
}

function markSourceAvailable(PDO $pdo, string $sourceId, bool $available): void
{
    $stmt = $pdo->prepare('UPDATE dtm_sources SET is_available = :available WHERE id = :id');
    $stmt->execute([':available' => $available ? 1 : 0, ':id' => $sourceId]);
}

function insertTile(PDO $pdo, array $tile): void
{
    $stmt = $pdo->prepare(<<<'SQL'
INSERT OR REPLACE INTO dtm_tiles (
    source_id, county_id, county_name, version, priority, role,
    tile_key, label, file_name, entry_name, format, source_srs, epsg,
    min_x, min_y, max_x, max_y, wkt, resolution_x, resolution_y,
    nodata, md5, bytes, scanned_at
) VALUES (
    :source_id, :county_id, :county_name, :version, :priority, :role,
    :tile_key, :label, :file_name, :entry_name, :format, :source_srs, :epsg,
    :min_x, :min_y, :max_x, :max_y, :wkt, :resolution_x, :resolution_y,
    :nodata, :md5, :bytes, :scanned_at
)
SQL);
    $stmt->execute([
        ':source_id' => $tile['source_id'],
        ':county_id' => $tile['county_id'],
        ':county_name' => $tile['county_name'],
        ':version' => $tile['version'],
        ':priority' => $tile['priority'],
        ':role' => $tile['role'],
        ':tile_key' => $tile['tile_key'],
        ':label' => $tile['label'],
        ':file_name' => $tile['file_name'],
        ':entry_name' => $tile['entry_name'],
        ':format' => $tile['format'],
        ':source_srs' => $tile['source_srs'],
        ':epsg' => $tile['epsg'],
        ':min_x' => $tile['min_x'],
        ':min_y' => $tile['min_y'],
        ':max_x' => $tile['max_x'],
        ':max_y' => $tile['max_y'],
        ':wkt' => $tile['wkt'],
        ':resolution_x' => $tile['resolution_x'],
        ':resolution_y' => $tile['resolution_y'],
        ':nodata' => $tile['nodata'],
        ':md5' => $tile['md5'],
        ':bytes' => $tile['bytes'],
        ':scanned_at' => $tile['scanned_at'],
    ]);
}

function scanSourceTiles(array $source, array $scanRoot): array
{
    if ($scanRoot['type'] === 'dir') {
        return scanDirectoryTiles($source, $scanRoot['path']);
    }
    return scanZipTiles($source, $scanRoot['path']);
}

function scanDirectoryTiles(array $source, string $dir): array
{
    $tiles = [];
    $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($dir, FilesystemIterator::SKIP_DOTS));
    foreach ($it as $file) {
        if (!$file instanceof SplFileInfo || !$file->isFile()) {
            continue;
        }
        $ext = strtolower($file->getExtension());
        if (!in_array($ext, ['grd', 'tif', 'tiff'], true)) {
            continue;
        }
        $path = $file->getPathname();
        $relative = str_replace('\\', '/', substr($path, strlen(rtrim($dir, "\\/")) + 1));
        $tiles[] = tileFromFile($source, $path, $relative, $ext);
    }
    return $tiles;
}

function scanZipTiles(array $source, string $zipPath): array
{
    $zip = new ZipArchive();
    if ($zip->open($zipPath) !== true) {
        throw new RuntimeException("無法開啟 zip：{$zipPath}");
    }

    $tiles = [];
    for ($i = 0; $i < $zip->numFiles; $i++) {
        $stat = $zip->statIndex($i);
        if (!is_array($stat) || !isset($stat['name'])) {
            continue;
        }
        $entry = (string) $stat['name'];
        if (str_ends_with($entry, '/')) {
            continue;
        }
        $ext = strtolower(pathinfo($entry, PATHINFO_EXTENSION));
        if (!in_array($ext, ['grd', 'tif', 'tiff'], true)) {
            continue;
        }
        if ($ext === 'grd') {
            $tile = tileFromZipGrd($source, $zip, $zipPath, $entry);
        } else {
            $tile = tileFromZipTif($source, $zip, $zipPath, $entry);
        }
        if ($tile !== null) {
            $tiles[] = $tile;
        }
    }
    $zip->close();
    return $tiles;
}

function tileFromFile(array $source, string $path, string $entryName, string $ext): array
{
    if ($ext === 'grd') {
        $fp = fopen($path, 'rb');
        if (!is_resource($fp)) {
            throw new RuntimeException("無法讀取 GRD：{$path}");
        }
        $scan = scanGrdStream($fp);
        fclose($fp);
        return tileFromScan($source, basename($path), $entryName, 'grd', $scan);
    }

    $scan = scanTifPath($path, md5_file($path) ?: '', filesize($path) ?: 0);
    return tileFromScan($source, basename($path), $entryName, 'tif', $scan);
}

function tileFromZipGrd(array $source, ZipArchive $zip, string $zipPath, string $entryName): ?array
{
    $stream = $zip->getStream($entryName);
    if (!is_resource($stream)) {
        return null;
    }
    $scan = scanGrdStream($stream);
    fclose($stream);
    return tileFromScan($source, basename($entryName), $entryName, 'grd', $scan);
}

function tileFromZipTif(array $source, ZipArchive $zip, string $zipPath, string $entryName): ?array
{
    $stream = $zip->getStream($entryName);
    if (!is_resource($stream)) {
        return null;
    }
    $ctx = hash_init('md5');
    $bytes = 0;
    $tmpPath = tempnam(sys_get_temp_dir(), 'dtm-tif-');
    if ($tmpPath === false) {
        fclose($stream);
        throw new RuntimeException('建立暫存 TIF 失敗');
    }
    $out = fopen($tmpPath, 'wb');
    if (!is_resource($out)) {
        fclose($stream);
        @unlink($tmpPath);
        throw new RuntimeException("無法寫入暫存 TIF：{$tmpPath}");
    }
    while (!feof($stream)) {
        $chunk = fread($stream, 1024 * 1024);
        if ($chunk === false || $chunk === '') {
            break;
        }
        $bytes += strlen($chunk);
        hash_update($ctx, $chunk);
        fwrite($out, $chunk);
    }
    fclose($out);
    fclose($stream);

    try {
        $scan = scanTifPath($tmpPath, hash_final($ctx), $bytes);
    } finally {
        @unlink($tmpPath);
    }
    return tileFromScan($source, basename($entryName), $entryName, 'tif', $scan);
}

function scanGrdStream($stream): array
{
    $minX = null;
    $minY = null;
    $maxX = null;
    $maxY = null;
    $xs = [];
    $ys = [];
    $bytes = 0;
    $ctx = hash_init('md5');
    $nodata = '';

    while (($line = fgets($stream)) !== false) {
        $bytes += strlen($line);
        hash_update($ctx, $line);
        $trimmed = trim($line);
        if ($trimmed === '') {
            continue;
        }
        $parts = preg_split('/\s+/', $trimmed);
        if (!is_array($parts) || count($parts) < 2 || !is_numeric($parts[0]) || !is_numeric($parts[1])) {
            continue;
        }

        $x = (float) $parts[0];
        $y = (float) $parts[1];
        $minX = ($minX === null || $x < $minX) ? $x : $minX;
        $maxX = ($maxX === null || $x > $maxX) ? $x : $maxX;
        $minY = ($minY === null || $y < $minY) ? $y : $minY;
        $maxY = ($maxY === null || $y > $maxY) ? $y : $maxY;
        $xs[(string) $x] = $x;
        $ys[(string) $y] = $y;
        if (isset($parts[2]) && ((string) $parts[2] === '-999' || (string) $parts[2] === '-32768')) {
            $nodata = (string) $parts[2];
        }
    }

    if ($minX === null || $minY === null || $maxX === null || $maxY === null) {
        throw new RuntimeException('GRD 沒有可用座標');
    }

    return [
        'bbox' => [$minX, $minY, $maxX, $maxY],
        'resolution_x' => minDelta(array_values($xs)),
        'resolution_y' => minDelta(array_values($ys)),
        'nodata' => $nodata,
        'md5' => hash_final($ctx),
        'bytes' => $bytes,
    ];
}

function minDelta(array $values): ?float
{
    $values = array_values(array_unique(array_map('floatval', $values)));
    sort($values, SORT_NUMERIC);
    $min = null;
    for ($i = 1; $i < count($values); $i++) {
        $delta = abs($values[$i] - $values[$i - 1]);
        if ($delta <= 0) {
            continue;
        }
        $min = ($min === null || $delta < $min) ? $delta : $min;
    }
    return $min;
}

function scanTifPath(string $path, string $md5, int $bytes): array
{
    $json = runCommand('gdalinfo -json ' . escapeshellarg($path));
    $info = json_decode($json, true);
    if (!is_array($info) || !isset($info['cornerCoordinates'])) {
        throw new RuntimeException("gdalinfo 缺少 cornerCoordinates：{$path}");
    }
    $corners = $info['cornerCoordinates'];
    $points = [
        $corners['upperLeft'] ?? null,
        $corners['lowerLeft'] ?? null,
        $corners['lowerRight'] ?? null,
        $corners['upperRight'] ?? null,
    ];
    $xs = [];
    $ys = [];
    foreach ($points as $point) {
        if (!is_array($point) || count($point) < 2) {
            continue;
        }
        $xs[] = (float) $point[0];
        $ys[] = (float) $point[1];
    }
    if (!$xs || !$ys) {
        throw new RuntimeException("gdalinfo cornerCoordinates 格式異常：{$path}");
    }
    $geoTransform = $info['geoTransform'] ?? [];
    $nodata = '';
    if (isset($info['bands'][0]['noDataValue'])) {
        $nodata = (string) $info['bands'][0]['noDataValue'];
    }
    return [
        'bbox' => [min($xs), min($ys), max($xs), max($ys)],
        'resolution_x' => isset($geoTransform[1]) ? abs((float) $geoTransform[1]) : null,
        'resolution_y' => isset($geoTransform[5]) ? abs((float) $geoTransform[5]) : null,
        'nodata' => $nodata,
        'md5' => $md5,
        'bytes' => $bytes,
    ];
}

function tileFromScan(array $source, string $fileName, string $entryName, string $format, array $scan): array
{
    [$minX, $minY, $maxX, $maxY] = $scan['bbox'];
    $wkt = wktFromBbox((float) $minX, (float) $minY, (float) $maxX, (float) $maxY, $source['source_srs']);
    $tileKey = tileKey($fileName);
    return [
        'source_id' => $source['id'],
        'county_id' => $source['county_id'],
        'county_name' => $source['county_name'],
        'version' => $source['version'],
        'priority' => $source['priority'],
        'role' => $source['role'],
        'tile_key' => $tileKey,
        'label' => $fileName,
        'file_name' => $fileName,
        'entry_name' => $entryName,
        'format' => $format,
        'source_srs' => $source['source_srs'],
        'epsg' => 'EPSG:3826',
        'min_x' => (float) $minX,
        'min_y' => (float) $minY,
        'max_x' => (float) $maxX,
        'max_y' => (float) $maxY,
        'wkt' => $wkt,
        'resolution_x' => $scan['resolution_x'],
        'resolution_y' => $scan['resolution_y'],
        'nodata' => (string) $scan['nodata'],
        'md5' => (string) $scan['md5'],
        'bytes' => (int) $scan['bytes'],
        'scanned_at' => $source['scanned_at'],
    ];
}

function tileKey(string $fileName): string
{
    $base = strtolower(pathinfo($fileName, PATHINFO_FILENAME));
    return preg_replace('/[^a-z0-9_]+/', '_', $base) ?? $base;
}

function wktFromBbox(float $minX, float $minY, float $maxX, float $maxY, string $sourceSrs): string
{
    $points = [
        [$minX, $maxY],
        [$minX, $minY],
        [$maxX, $minY],
        [$maxX, $maxY],
    ];
    if (normalizeSrs($sourceSrs) !== 'EPSG:3826') {
        $points = transformPoints($points, $sourceSrs, 'EPSG:3826');
    }
    $ring = [];
    foreach ($points as $point) {
        $ring[] = number_format((float) $point[0], 4, '.', '') . ' ' . number_format((float) $point[1], 4, '.', '');
    }
    $ring[] = $ring[0];
    return 'POLYGON((' . implode(', ', $ring) . '))';
}

function transformPoints(array $points, string $sourceSrs, string $targetSrs): array
{
    $input = '';
    foreach ($points as $point) {
        $input .= sprintf("%.10f %.10f\n", (float) $point[0], (float) $point[1]);
    }

    $command = 'gdaltransform -s_srs ' . escapeshellarg(normalizeSrs($sourceSrs)) . ' -t_srs ' . escapeshellarg(normalizeSrs($targetSrs));
    $descriptor = [['pipe', 'r'], ['pipe', 'w'], ['pipe', 'w']];
    $process = proc_open($command, $descriptor, $pipes);
    if (!is_resource($process)) {
        throw new RuntimeException("無法啟動 gdaltransform：{$command}");
    }
    fwrite($pipes[0], $input);
    fclose($pipes[0]);
    $stdout = trim((string) stream_get_contents($pipes[1]));
    $stderr = trim((string) stream_get_contents($pipes[2]));
    fclose($pipes[1]);
    fclose($pipes[2]);
    $code = proc_close($process);
    if ($code !== 0 || $stdout === '') {
        throw new RuntimeException("gdaltransform 失敗：{$stderr}");
    }

    $out = [];
    foreach (preg_split('/\r?\n/', $stdout) ?: [] as $line) {
        $parts = preg_split('/\s+/', trim($line));
        if (!is_array($parts) || count($parts) < 2) {
            continue;
        }
        $out[] = [(float) $parts[0], (float) $parts[1]];
    }
    if (count($out) !== count($points)) {
        throw new RuntimeException("gdaltransform 回傳點數異常：{$stdout}");
    }
    return $out;
}

function runCommand(string $command): string
{
    $descriptor = [['pipe', 'r'], ['pipe', 'w'], ['pipe', 'w']];
    $process = proc_open($command, $descriptor, $pipes);
    if (!is_resource($process)) {
        throw new RuntimeException("無法啟動指令：{$command}");
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

function summaryFromSource(array $source, int $tileCount, bool $available, string $message): array
{
    return [
        'id' => $source['id'],
        'name' => $source['name'],
        'version' => $source['version'],
        'priority' => $source['priority'],
        'role' => $source['role'],
        'countyId' => $source['county_id'],
        'countyName' => $source['county_name'],
        'enabled' => $source['enabled'],
        'available' => $available,
        'tileCount' => $tileCount,
        'url' => 'tiles_' . $source['id'] . '.json',
        'message' => $message,
    ];
}

function writeCoverageJson(PDO $pdo, string $coverageDir, array $sourceSummaries, string $generatedAt, string $sourcePath, string $dbPath): void
{
    foreach ($sourceSummaries as $source) {
        $tiles = queryTiles($pdo, 'SELECT * FROM dtm_tiles WHERE source_id = :source_id ORDER BY tile_key', [':source_id' => $source['id']]);
        writeJson($coverageDir . DIRECTORY_SEPARATOR . 'tiles_' . $source['id'] . '.json', [
            'schemaVersion' => 1,
            'generatedAt' => $generatedAt,
            'epsg' => 'EPSG:3826',
            'source' => $source,
            'tiles' => array_map('tileRowForJson', $tiles),
        ]);
    }

    $best = queryTiles($pdo, 'SELECT * FROM v_tile_best_source ORDER BY county_id, tile_key');
    writeJson($coverageDir . DIRECTORY_SEPARATOR . 'best_source.json', [
        'schemaVersion' => 1,
        'generatedAt' => $generatedAt,
        'epsg' => 'EPSG:3826',
        'tiles' => array_map('tileRowForJson', $best),
    ]);

    $missing = queryTiles($pdo, 'SELECT * FROM v_missing_primary_fallback ORDER BY county_id, tile_key');
    writeJson($coverageDir . DIRECTORY_SEPARATOR . 'missing_primary_fallback.json', [
        'schemaVersion' => 1,
        'generatedAt' => $generatedAt,
        'epsg' => 'EPSG:3826',
        'tiles' => array_map('tileRowForJson', $missing),
    ]);

    $overlap = $pdo->query('SELECT * FROM v_overlap_tiles ORDER BY county_id, tile_key')->fetchAll(PDO::FETCH_ASSOC);
    $overlapTiles = queryTiles($pdo, <<<SQL
SELECT best.*
FROM v_tile_best_source best
JOIN v_overlap_tiles overlap
  ON overlap.county_id = best.county_id
 AND overlap.tile_key = best.tile_key
ORDER BY best.county_id, best.tile_key
SQL);
    writeJson($coverageDir . DIRECTORY_SEPARATOR . 'overlap_tiles.json', [
        'schemaVersion' => 1,
        'generatedAt' => $generatedAt,
        'rows' => $overlap,
        'tiles' => array_map('tileRowForJson', $overlapTiles),
    ]);

    writeJson($coverageDir . DIRECTORY_SEPARATOR . 'index.json', [
        'schemaVersion' => 1,
        'generatedAt' => $generatedAt,
        'epsg' => 'EPSG:3826',
        'sourceRegistry' => $sourcePath,
        'sqlite' => $dbPath,
        'sources' => $sourceSummaries,
        'layers' => [
            'bestSource' => 'best_source.json',
            'missingPrimaryFallback' => 'missing_primary_fallback.json',
            'overlapTiles' => 'overlap_tiles.json',
        ],
    ]);
}

function sourceSummariesFromDatabase(PDO $pdo): array
{
    $rows = $pdo->query(<<<'SQL'
SELECT
    s.id,
    s.name,
    s.version,
    s.priority,
    s.role,
    s.county_id,
    s.county_name,
    s.enabled,
    s.is_available,
    COUNT(t.id) AS tile_count
FROM dtm_sources s
LEFT JOIN dtm_tiles t ON t.source_id = s.id
GROUP BY s.id
ORDER BY
    CASE s.version
        WHEN '2025' THEN 1
        WHEN '2024' THEN 2
        WHEN 'OLD' THEN 3
        WHEN 'GLOBAL_RESERVED' THEN 99
        ELSE 50
    END,
    s.priority,
    s.id
SQL)->fetchAll(PDO::FETCH_ASSOC);

    $out = [];
    foreach ($rows as $row) {
        $message = '';
        if ((int) $row['enabled'] === 0) {
            $message = 'disabled';
        } elseif ((int) $row['is_available'] === 0) {
            $message = 'missing source path';
        }
        $out[] = [
            'id' => $row['id'],
            'name' => $row['name'],
            'version' => $row['version'],
            'priority' => (int) $row['priority'],
            'role' => $row['role'],
            'countyId' => $row['county_id'],
            'countyName' => $row['county_name'],
            'enabled' => (int) $row['enabled'] === 1,
            'available' => (int) $row['is_available'] === 1,
            'tileCount' => (int) $row['tile_count'],
            'url' => 'tiles_' . $row['id'] . '.json',
            'message' => $message,
        ];
    }
    return $out;
}

function queryTiles(PDO $pdo, string $sql, array $params = []): array
{
    $stmt = $pdo->prepare($sql);
    $stmt->execute($params);
    return $stmt->fetchAll(PDO::FETCH_ASSOC);
}

function tileRowForJson(array $row): array
{
    return [
        'label' => $row['label'],
        'tileKey' => $row['tile_key'],
        'sourceId' => $row['source_id'],
        'countyId' => $row['county_id'],
        'countyName' => $row['county_name'],
        'version' => $row['version'],
        'priority' => (int) $row['priority'],
        'role' => $row['role'],
        'fileName' => $row['file_name'],
        'entryName' => $row['entry_name'],
        'format' => $row['format'],
        'sourceSrs' => $row['source_srs'],
        'epsg' => $row['epsg'],
        'bbox' => [(float) $row['min_x'], (float) $row['min_y'], (float) $row['max_x'], (float) $row['max_y']],
        'resolutionX' => $row['resolution_x'] === null ? null : (float) $row['resolution_x'],
        'resolutionY' => $row['resolution_y'] === null ? null : (float) $row['resolution_y'],
        'nodata' => $row['nodata'],
        'md5' => $row['md5'],
        'bytes' => (int) $row['bytes'],
        'wkt' => $row['wkt'],
    ];
}

function writeJson(string $path, array $value): void
{
    $json = json_encode($value, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    if ($json === false) {
        throw new RuntimeException('JSON encode failed: ' . json_last_error_msg());
    }
    file_put_contents($path, $json . PHP_EOL);
}
