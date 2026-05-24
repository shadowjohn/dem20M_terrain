<?php
declare(strict_types=1);

/**
 * 依 config/dtm_sources.json 下載 DTM zip。
 *
 * 下載器只負責把官方 zip 抓回 data/raw，不解壓、不建 catalog。
 *
 * Usage:
 * php tools/download-dtm-sources.php --source config/dtm_sources.json --only 2025,2024,OLD
 */

setlocale(LC_ALL, 'C');

$repoRoot = dirname(__DIR__);
$options = parseCliOptions($argv);
$sourcePath = resolvePath((string) ($options['source'] ?? 'config/dtm_sources.json'), $repoRoot);
$onlyVersions = parseOnlyVersions((string) ($options['only'] ?? ''));
$force = isset($options['force']);
$dryRun = isset($options['dry-run']);
$maxRetries = max(1, (int) ($options['retry'] ?? 3));

if (!extension_loaded('curl')) {
    fwrite(STDERR, "ERROR: PHP curl extension 未啟用\n");
    exit(1);
}
if (!is_file($sourcePath)) {
    fwrite(STDERR, "ERROR: 找不到 source registry：{$sourcePath}\n");
    exit(1);
}

$registry = json_decode((string) file_get_contents($sourcePath), true);
if (!is_array($registry) || !isset($registry['sources']) || !is_array($registry['sources'])) {
    fwrite(STDERR, "ERROR: source registry 格式錯誤，必須包含 sources 陣列\n");
    exit(1);
}

$targets = [];
foreach ($registry['sources'] as $source) {
    if (!is_array($source) || !shouldDownload($source, $onlyVersions)) {
        continue;
    }
    $zipPath = resolvePath((string) ($source['zipPath'] ?? ''), $repoRoot);
    $targets[] = [
        'id' => (string) $source['id'],
        'version' => (string) $source['version'],
        'name' => (string) ($source['name'] ?? $source['id']),
        'url' => (string) $source['url'],
        'zipPath' => $zipPath,
    ];
}

fwrite(STDOUT, "DTM download targets=" . count($targets) . "\n");

$downloaded = 0;
$skipped = 0;
$failed = 0;
foreach ($targets as $idx => $target) {
    $n = $idx + 1;
    if (!$force && is_file($target['zipPath']) && filesize($target['zipPath']) > 0) {
        $skipped++;
        fwrite(STDOUT, "[{$n}/" . count($targets) . "] skip {$target['id']} (" . filesize($target['zipPath']) . " bytes)\n");
        continue;
    }
    if ($dryRun) {
        fwrite(STDOUT, "[{$n}/" . count($targets) . "] dry-run {$target['id']} -> {$target['zipPath']}\n");
        continue;
    }
    ensureDir(dirname($target['zipPath']));
    $ok = downloadWithRetry($target['url'], $target['zipPath'], $target['id'], $maxRetries, $n, count($targets));
    if ($ok) {
        $downloaded++;
    } else {
        $failed++;
    }
}

fwrite(STDOUT, "DTM download 完成：downloaded={$downloaded}, skipped={$skipped}, failed={$failed}\n");
exit($failed > 0 ? 1 : 0);

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

function parseOnlyVersions(string $value): array
{
    if (trim($value) === '') {
        return [];
    }
    return array_values(array_filter(array_map(static fn($v) => strtoupper(trim($v)), explode(',', $value))));
}

function shouldDownload(array $source, array $onlyVersions): bool
{
    $url = (string) ($source['url'] ?? '');
    $zipPath = (string) ($source['zipPath'] ?? '');
    if ($url === '' || $zipPath === '' || !str_ends_with(strtolower($url), '.zip')) {
        return false;
    }
    if (array_key_exists('downloadEnabled', $source) && !$source['downloadEnabled']) {
        return false;
    }
    $version = strtoupper((string) ($source['version'] ?? ''));
    if ($onlyVersions && !in_array($version, $onlyVersions, true)) {
        return false;
    }
    return true;
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

function downloadWithRetry(string $url, string $targetPath, string $sourceId, int $maxRetries, int $index, int $total): bool
{
    $tmpPath = $targetPath . '.part';
    for ($attempt = 1; $attempt <= $maxRetries; $attempt++) {
        @unlink($tmpPath);
        fwrite(STDOUT, "[{$index}/{$total}] download {$sourceId} attempt {$attempt}/{$maxRetries}\n");
        $ok = downloadOnce($url, $tmpPath);
        if ($ok && is_file($tmpPath) && filesize($tmpPath) > 0) {
            if (is_file($targetPath)) {
                @unlink($targetPath);
            }
            rename($tmpPath, $targetPath);
            fwrite(STDOUT, "[{$index}/{$total}] done {$sourceId} (" . filesize($targetPath) . " bytes)\n");
            return true;
        }
        @unlink($tmpPath);
        usleep(300000 * $attempt);
    }
    fwrite(STDERR, "[{$index}/{$total}] FAILED {$sourceId}: {$url}\n");
    return false;
}

function downloadOnce(string $url, string $tmpPath): bool
{
    $fp = fopen($tmpPath, 'wb');
    if (!is_resource($fp)) {
        throw new RuntimeException("無法寫入暫存檔：{$tmpPath}");
    }

    $ch = curl_init(normalizeUrlForCurl($url));
    curl_setopt_array($ch, [
        CURLOPT_FILE => $fp,
        CURLOPT_FOLLOWLOCATION => true,
        CURLOPT_CONNECTTIMEOUT => 30,
        CURLOPT_TIMEOUT => 0,
        CURLOPT_USERAGENT => 'dem20M-terrain-downloader/1.0',
        CURLOPT_FAILONERROR => false,
        CURLOPT_SSL_VERIFYPEER => true,
        CURLOPT_SSL_VERIFYHOST => 2,
    ]);
    $result = curl_exec($ch);
    $httpCode = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
    $error = curl_error($ch);
    curl_close($ch);
    fclose($fp);

    if ($result !== true || $httpCode < 200 || $httpCode >= 300) {
        if ($error !== '') {
            fwrite(STDERR, "curl error: {$error}\n");
        } else {
            fwrite(STDERR, "HTTP {$httpCode}\n");
        }
        return false;
    }
    return true;
}

function normalizeUrlForCurl(string $url): string
{
    $parts = parse_url($url);
    if (!is_array($parts) || !isset($parts['scheme'], $parts['host'])) {
        return $url;
    }
    $path = $parts['path'] ?? '';
    $encodedPath = implode('/', array_map(
        static fn($segment) => rawurlencode(rawurldecode($segment)),
        explode('/', $path)
    ));
    $out = $parts['scheme'] . '://' . $parts['host'];
    if (isset($parts['port'])) {
        $out .= ':' . $parts['port'];
    }
    $out .= $encodedPath;
    if (isset($parts['query'])) {
        $out .= '?' . $parts['query'];
    }
    return $out;
}
