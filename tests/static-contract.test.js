const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const root = path.resolve(__dirname, "..");
const expectedCountyIds = [
  "changhua",
  "chiayi_city",
  "chiayi_county",
  "hsinchu_city",
  "hsinchu_county",
  "hualien",
  "kaohsiung",
  "keelung",
  "kinmen",
  "miaoli",
  "nantou",
  "newtaipei",
  "penghu",
  "pingtung",
  "taichung",
  "tainan",
  "taipei",
  "taitung",
  "taoyuan",
  "yilan",
  "yunlin",
];

function readText(relativePath) {
  return fs.readFileSync(path.join(root, relativePath), "utf8");
}

test("county config tracks all 2025 split county TGOS sources", () => {
  const counties = JSON.parse(readText("config/counties.json"));
  const ids = counties.map((county) => county.id).sort();

  assert.deepEqual(ids, expectedCountyIds);

  for (const county of counties) {
    assert.match(county.url, /^https:\/\/www\.tgos\.tw:443\/MDE\/VirtualDir_TC\/Product\//);
    assert.match(county.url, /\/分幅_.+20MDEM\(2025\)\.zip$/);
    assert.match(county.zipName, /\.zip$/);
    assert.equal(county.targetSrs, "EPSG:4326");
    assert.equal(county.outputDir, `output/${county.id}`);
    assert.equal(Number.isInteger(county.expectedBytes), true);
    assert.equal(county.expectedBytes > 0, true);
  }

  const byId = Object.fromEntries(counties.map((county) => [county.id, county]));
  assert.equal(byId.penghu.sourceSrs, "EPSG:3825");
  assert.equal(byId.kinmen.sourceSrs, "EPSG:3825");
});

test("DTM source registry defines V1 source priority policy", () => {
  const registry = JSON.parse(readText("config/dtm_sources.json"));
  assert.equal(registry.schemaVersion, 1);
  assert.equal(registry.policy, "2025 > 2024 > OLD > GLOBAL_RESERVED");
  assert.ok(Array.isArray(registry.datasets));
  assert.ok(registry.datasets.some((dataset) => dataset.dataGovUrl === "https://data.gov.tw/dataset/176927"));
  assert.ok(registry.datasets.some((dataset) => dataset.dataGovUrl === "https://data.gov.tw/dataset/169807"));
  assert.ok(registry.datasets.some((dataset) => dataset.dataGovUrl === "https://data.gov.tw/dataset/35430"));

  const sources = registry.sources;
  const enabledPrimary2025CountyIds = sources
    .filter((source) => source.enabled && source.version === "2025" && source.priority === 1 && source.role === "primary")
    .map((source) => source.countyId)
    .sort();

  assert.deepEqual(enabledPrimary2025CountyIds, expectedCountyIds);

  const mainlandCountyIds = expectedCountyIds.filter((id) => !["penghu", "kinmen"].includes(id));
  const fallback2024CountyIds = sources
    .filter((source) => source.enabled && source.version === "2024" && source.priority === 2 && source.role === "fallback" && source.countyId !== "taiwan")
    .map((source) => source.countyId)
    .sort();
  assert.deepEqual(fallback2024CountyIds, mainlandCountyIds);

  const oldCountyIds = sources
    .filter((source) => source.enabled && source.version === "OLD" && source.priority === 3 && source.role === "fallback")
    .map((source) => source.countyId)
    .sort();
  assert.ok(oldCountyIds.includes("miaoli"));
  assert.ok(oldCountyIds.includes("penghu"));
  assert.ok(oldCountyIds.includes("keelung"));

  assert.ok(sources.some((source) => source.id === "dtm_global_reserved" && source.priority === 4 && source.enabled === false));
  assert.ok(sources.some((source) => source.id === "dtm_2025_penghu_split_diagnostic" && source.role === "diagnostic"));
  assert.ok(sources.some((source) => source.id === "dtm_old_taiwan_penghu_unified" && source.downloadEnabled === true && source.enabled === false));

  for (const source of sources) {
    assert.match(source.id, /^dtm_/);
    assert.equal(typeof source.name, "string");
    assert.equal(typeof source.version, "string");
    assert.equal(Number.isInteger(source.priority), true);
    assert.equal(typeof source.countyId, "string");
    assert.match(source.sourceSrs, /^EPSG:/);
  }
});

test("build script contains the repeatable terrain pipeline", () => {
  const script = readText("tools/build-terrain.ps1");

  assert.match(script, /ghcr\.io\/tum-gis\/ctb-quantized-mesh:latest/);
  assert.match(script, /Invoke-WebRequest/);
  assert.match(script, /Expand-Archive/);
  assert.match(script, /gdalbuildvrt/);
  assert.match(script, /gdalwarp/);
  assert.match(script, /ctb-tile -f Mesh -p geodetic -C/);
  assert.match(script, /layer\.json/);
  assert.match(script, /history\.md/);
  assert.match(script, /Normalize-TerrainTiles/);
  assert.match(script, /function Normalize-CountyIds/);
  assert.match(script, /未知縣市 id/);
  assert.match(script, /ProgressMessage/);
  assert.match(script, /指令執行中/);
  assert.match(script, /\[int\] \$PollIntervalMs = 100/);
  assert.match(script, /\$process\.WaitForExit\(\$pollMs\)/);
  assert.doesNotMatch(script, /Start-Sleep -Seconds 5/);
  assert.match(script, /Write-Host/);
  assert.match(script, /Add-Content -LiteralPath \$LogPath/);
  assert.doesNotMatch(script, /Tee-Object/);
  assert.match(script, /northup/);
  assert.match(script, /positive NS resolution/);
  assert.match(script, /Test-PositiveNsResolution/);
  assert.match(script, /Pixel Size =/);
  assert.match(script, /跳過直接 VRT/);
  assert.match(script, /gdalwarp \[\{0\}\/\{1\}\]/);
  assert.doesNotMatch(script, /gdal_translate \[\{0\}\/\{1\}\]/);
  assert.match(script, /\[5\/8\]/);
  assert.match(script, /\[6\/8\]/);
  assert.match(script, /\[7\/8\]/);
  assert.doesNotMatch(script, /ValidateSet\("taichung", "taoyuan", "newtaipei"\)/);
});

test("build script builds all_taiwan as a first-class combined provider", () => {
  const script = readText("tools/build-terrain.ps1");

  assert.match(script, /\[switch\] \$AllWithTaiwan/);
  assert.match(script, /\[switch\] \$FromGrd/);
  assert.match(script, /\$TaiwanProviderId = "all_taiwan"/);
  assert.match(script, /\$MainTaiwanProviderId = "taiwan"/);
  assert.match(script, /\$FromGrdTaiwanProviderId = "taiwan_from_grd"/);
  assert.match(script, /\$FromGrdAllTaiwanProviderId = "all_taiwan_from_grd"/);
  assert.match(script, /function Invoke-TaiwanMainBuild/);
  assert.match(script, /function Invoke-AllTaiwanBuild/);
  assert.match(script, /function Invoke-FromGrdTaiwanBuild/);
  assert.match(script, /function Invoke-UnifiedTaiwanSourceBuild/);
  assert.match(script, /function Build-CountyMosaicRaster/);
  assert.match(script, /function Build-CountyUnifiedRaster/);
  assert.match(script, /function Invoke-CountyMosaicProviderBuild/);
  assert.match(script, /function Invoke-CountyUnifiedProviderBuild/);
  assert.match(script, /output\/all_taiwan/);
  assert.match(script, /output\/\$MainTaiwanProviderId/);
  assert.match(script, /全臺主島 terrain 產製完成/);
  assert.match(script, /不分幅_全台20MDEM\(2025\)/);
  assert.match(script, /不分幅_澎湖20MDEM\(2025\)/);
  assert.match(script, /不分幅_金門20MDEM\(2025\)/);
  assert.match(script, /528530be-0710-431e-954e-2f2f5e98b0c5/);
  assert.match(script, /47910269-7315-4cd2-9101-7cdf524b47f5/);
  assert.match(script, /0e018335-80f1-4489-990c-ecf2bef1a9b6/);
  assert.match(script, /function Invoke-UnifiedGeoTiffSourceBuild/);
  assert.match(script, /function Get-OffshoreUnifiedSourceConfig/);
  assert.match(script, /function Build-CompositeRaster/);
  assert.match(script, /gdalbuildvrt 建立全臺 VRT/);
  assert.match(script, /gdalwarp 建立 NoData 透明 composite GeoTIFF/);
  assert.match(script, /21 個縣市 EPSG:4326 GeoTIFF/);
  assert.match(script, /AllWithTaiwan 指定縣市模式/);
  assert.match(script, /\$taiwanSourceCounties = if \(\$useSubsetForAllWithTaiwan\)/);
  assert.match(script, /Invoke-AllTaiwanBuild -CountyConfigs \$taiwanSourceCounties/);
  assert.match(script, /Invoke-TaiwanMainBuild -CountyConfigs \$taiwanSourceCounties/);
  assert.match(script, /SkipUnifiedTaiwanSource/);
  assert.match(script, /taiwan_unified_split_gapfill/);
  assert.match(script, /taiwan_unified_split_moi_gapfill/);
  assert.match(script, /taiwan_unified_split_moi_full_gapfill/);
  assert.match(script, /all_taiwan_unified/);
  assert.match(script, /all_taiwan_unified_split_gapfill/);
  assert.match(script, /all_taiwan_unified_split_moi_gapfill/);
  assert.match(script, /all_taiwan_unified_split_moi_full_gapfill/);
  assert.match(script, /taiwan_from_grd_moi_full/);
  assert.match(script, /all_taiwan_from_grd_moi_full/);
  assert.match(script, /2025縣市分幅GRD/);
  assert.match(script, /hsinchu_county_moi/);
  assert.match(script, /ed20601a-24dd-48f9-a4c0-1659aaccda28/);
  assert.match(script, /Get-MoiFullSourceModeText/);
  assert.match(script, /只重建 taiwan_from_grd\/all_taiwan_from_grd/);
  assert.match(script, /county_offshore_unified/);
  assert.match(script, /Invoke-CountyMosaicProviderBuild -CountyConfigs \$selected -TaiwanRaster \$mainTaiwanRaster/);
  assert.match(script, /-UnifiedOffshoreRasterByCounty \$unifiedOffshoreRasterByCounty/);
  assert.match(script, /Invoke-CountyUnifiedProviderBuild -CountyConfigs \$selected -UnifiedTaiwanRaster \$unifiedTaiwanRaster -UnifiedOffshoreRasterByCounty \$unifiedOffshoreRasterByCounty/);
  assert.match(script, /county_mosaic_clip/);
  assert.match(script, /county_unified_clip/);
  assert.match(script, /county_unified_clip_split_gapfill/);
  assert.match(script, /county_unified_clip_split_moi_gapfill/);
  assert.match(script, /\[switch\] \$UseMoiForCounty/);
  assert.match(script, /function Invoke-CountyMoiFullRasterBuild/);
  assert.match(script, /function Invoke-CountyMoiProviderBuild/);
  assert.match(script, /county_moi_full/);
  assert.match(script, /output\/\$\(\$CountyConfig\.id\)_moi/);
  assert.match(script, /內政部完整DEM補洞/);
  assert.match(script, /\$moiFullRasters = @\(\)/);
  assert.match(script, /gdalbuildvrt 以後列來源為優先/);
  assert.match(script, /Build-CompositeRaster -ProviderName "全臺主島"/);
  assert.match(script, /Build-CompositeRaster -ProviderName "全臺含外島"/);
  assert.match(script, /只重建 taiwan\/all_taiwan，略過縣市 provider 重建/);
  assert.match(script, /避免縣市邊界 NoData 牆/);
  assert.match(script, /來源 NoData 不內插補洞/);
  assert.match(script, /2025縣市分幅缺值補洞/);
  assert.match(script, /澎湖、金門仍強制使用不分幅離島來源/);
  assert.match(script, /foreach \(\$offshoreSourceConfig in \$UnifiedOffshoreSourceConfigs\)/);
  assert.match(script, /正式 terrain 禁止使用 2025 分幅錯包來源/);
  assert.doesNotMatch(script, /county_split_source/);
  assert.match(script, /"-te", \$bbox\[0\], \$bbox\[1\], \$bbox\[2\], \$bbox\[3\]/);
});

test("build script publishes terrain atomically and resumes only valid output", () => {
  const script = readText("tools/build-terrain.ps1");

  assert.match(script, /function Test-ExistingTerrainOutput/);
  assert.match(script, /terrain output 已存在，跳過 CTB/);
  assert.match(script, /terrain output 已存在，跳過重建/);
  assert.match(script, /build-manifest\.json/);
  assert.match(script, /BuildKind -eq "county"/);
  assert.match(script, /Get-TmpOutputPath/);
  assert.match(script, /\.tmp-/);
  assert.match(script, /Move-Item -LiteralPath \$tmpOutputPath -Destination \$outputPath/);
  assert.match(script, /Remove-Item -LiteralPath \$tmpOutputPath -Recurse -Force/);
});

test("build script writes build manifests and rewrites layer bounds", () => {
  const script = readText("tools/build-terrain.ps1");

  assert.match(script, /function Get-RasterMetadata/);
  assert.match(script, /function Get-ManifestPathText/);
  assert.match(script, /function Update-LayerJsonBounds/);
  assert.match(script, /function Write-BuildManifest/);
  assert.match(script, /ConvertFrom-Json -AsHashtable/);
  assert.match(script, /build-manifest\.json/);
  assert.match(script, /"bbox"/);
  assert.match(script, /"terrainTileCount"/);
  assert.match(script, /"zoomLevels"/);
  assert.match(script, /"dockerImage"/);
  assert.match(script, /Add-Member -MemberType NoteProperty -Name "bounds" -Value/);
});

test("build script batches terrain tile normalization logs", () => {
  const script = readText("tools/build-terrain.ps1");

  assert.match(script, /\[int\] \$NormalizeProgressEvery = 100/);
  assert.match(script, /terrain\.gz 解壓開始/);
  assert.match(script, /terrain\.gz 解壓進度/);
  assert.match(script, /gzip 內容檢查開始/);
  assert.match(script, /gzip 內容正規化進度/);
  assert.match(script, /gzip 內容正規化完成/);
  assert.doesNotMatch(script, /terrain\.gz 解壓 \[\{0\}\/\{1\}\] \{2\}/);
  assert.doesNotMatch(script, /gzip 內容正規化 \[\{0\}\/\{1\}\] \{2\}/);
});

test("build script skips existing generated TIFF files unless force rebuild is requested", () => {
  const script = readText("tools/build-terrain.ps1");

  assert.match(script, /GeoTIFF 已存在，跳過轉檔/);
  assert.match(script, /EPSG:4326 TIFF 已存在，跳過重投影/);
  assert.match(script, /function Test-ExistingTerrainOutput/);
  assert.match(script, /terrain output 已存在，跳過 CTB/);
  assert.match(script, /-not \$ForceRebuild/);
});

test("build script checks Docker daemon before long terrain work", () => {
  const script = readText("tools/build-terrain.ps1");

  assert.match(script, /function Assert-DockerDaemon/);
  assert.match(script, /docker version/);
  assert.match(script, /Docker Desktop daemon 尚未啟動/);
  assert.match(script, /if \(-not \$ValidateOnly\) \{\s+Assert-DockerDaemon\s+\}/);
});

test("build script completes sparse XYZ grids before GDAL fallback conversion", () => {
  const script = readText("tools/build-terrain.ps1");

  assert.match(script, /function Convert-SparseXyzToCompleteXyz/);
  assert.match(script, /補齊稀疏 XYZ/);
  assert.match(script, /-complete\.xyz/);
  assert.match(script, /"-srcnodata", "-32768", "-dstnodata", "-32768"/);
});

test("build script fills small nodata holes with GDAL FillNodata through MS4W Python", () => {
  const script = readText("tools/build-terrain.ps1");
  const helper = readText("tools/fill-nodata.py");

  assert.match(script, /\[switch\] \$SkipFillNoData/);
  assert.match(script, /\[int\] \$FillDistancePixels = 5/);
  assert.match(script, /function Get-GdalPythonCommand/);
  assert.match(script, /function Invoke-FillNoData/);
  assert.match(script, /fill-nodata\.py/);
  assert.match(script, /補齊小範圍 NoData/);
  assert.match(helper, /gdal\.FillNodata/);
});

test("DTM catalog builder exposes SQLite coverage inventory contract", () => {
  const script = readText("tools/build-dtm-catalog.php");

  assert.match(script, /dtm_sources/);
  assert.match(script, /dtm_tiles/);
  assert.match(script, /v_tile_best_source/);
  assert.match(script, /v_missing_primary_fallback/);
  assert.match(script, /v_overlap_tiles/);
  assert.match(script, /v_coverage_summary/);
  assert.match(script, /'tiles_' \. \$source\['id'\] \. '\.json'/);
  assert.match(script, /best_source\.json/);
  assert.match(script, /coverage-only/);
  assert.match(script, /missing_primary_fallback\.json/);
  assert.match(script, /EPSG:3826/);
  assert.match(script, /s\.role = 'fallback'/);
});

test("DTM source updater and downloader expose annual source workflow", () => {
  const datasets = JSON.parse(readText("config/dtm_source_datasets.json"));
  const updater = readText("tools/update-dtm-sources.php");
  const downloader = readText("tools/download-dtm-sources.php");

  assert.equal(datasets.schemaVersion, 1);
  assert.deepEqual(
    datasets.datasets.map((dataset) => dataset.version),
    ["2025", "2024", "OLD"]
  );
  assert.match(updater, /opdadm\.moi\.gov\.tw/);
  assert.match(updater, /_split_diagnostic/);
  assert.match(updater, /data\/source-catalog/);
  assert.match(downloader, /downloadEnabled/);
  assert.match(downloader, /--only/);
  assert.match(downloader, /normalizeUrlForCurl/);
});

test("check_grd exposes DTM coverage mode without replacing polygon checks", () => {
  const html = readText("check_grd.html");

  assert.match(html, /COVERAGE_INDEX_URL = "data\/coverage\/index\.json"/);
  assert.match(html, /Coverage 模式/);
  assert.match(html, /loadCoverageIndex/);
  assert.match(html, /loadCoverageSource/);
  assert.match(html, /loadCoverageSpecialLayer/);
  assert.match(html, /bestSource/);
  assert.match(html, /整併後 best-source/);
  assert.match(html, /missingPrimaryFallback/);
  assert.match(html, /coverageTabs/);
  assert.match(html, /coverage-tab/);
  assert.match(html, /currentCoverageTab = "2025"/);
  assert.match(html, /內政部/);
  assert.match(html, /sourceId/);
  assert.match(html, /tileKey/);
  assert.match(html, /md5/);
  assert.match(html, /data\/polygons\//);
  assert.match(html, /new dgWKT/);
  assert.doesNotMatch(html, /alert\s*\(/);
});

test("documentation explains sources, run, output, Cesium, IIS, and verification", () => {
  const readme = readText("README.md");

  assert.match(readme, /https:\/\/data\.gov\.tw\/dataset\/176927/);
  assert.match(readme, /https:\/\/3wa\.tw\/mypaper\/\?uid=shadow&mode=view&id=2695/);
  assert.match(readme, /https:\/\/data\.gov\.tw\/dataset\/35430/);
  assert.match(readme, /https:\/\/3wa\.tw\/mypaper\/index\.php\?uid=shadow&mode=view&id=2704/);
  assert.match(readme, /2025年版全臺灣20公尺網格數值地形模型DTM資料/);
  assert.match(readme, /不分幅_全台20MDEM\(2025\)/);
  assert.match(readme, /不分幅_澎湖20MDEM\(2025\)/);
  assert.match(readme, /不分幅_金門20MDEM\(2025\)/);
  assert.match(readme, /內政部 DEM 補缺格/);
  assert.match(readme, /2025 分幅補不分幅缺值/);
  assert.match(readme, /all_taiwan_unified_split_moi_gapfill/);
  assert.match(readme, /pwsh\.exe -NoProfile -ExecutionPolicy Bypass -File \.\\tools\\build-terrain\.ps1 -All/);
  assert.match(readme, /output\/all_taiwan/);
  assert.match(readme, /output\/taiwan_from_grd/);
  assert.match(readme, /output\/all_taiwan_from_grd/);
  assert.match(readme, /-FromGrd/);
  assert.match(readme, /taiwan_from_grd/);
  assert.match(readme, /all_taiwan_from_grd/);
  assert.match(readme, /build-manifest\.json/);
  assert.match(readme, /全臺含外島 all_taiwan/);
  assert.match(readme, /SkipUnifiedTaiwanSource/);
  assert.match(readme, /避免苗栗、新竹山區這類不分幅空窗/);
  assert.match(readme, /output\/taichung/);
  assert.match(readme, /output\/penghu/);
  assert.match(readme, /研究筆記/);
  assert.match(readme, /機敏或管制區附近可能保留 NoData/);
  assert.match(readme, /snapshots\/miaoli-gap-annual-vs-moi\.png/);
  assert.match(readme, /Cesium\.CesiumTerrainProvider\.fromUrl\("terrain\/all_taiwan"\)/);
  assert.match(readme, /Apache \/ Nginx \/ IIS/);
  assert.match(readme, /application\/vnd\.quantized-mesh/);
  assert.match(readme, /node --test tests\/\*\.test\.js/);
  assert.match(readme, /DTM 版本整併庫 V1/);
  assert.match(readme, /tools[\\\/]build-dtm-catalog\.php/);
  assert.match(readme, /tools[\\\/]update-dtm-sources\.php/);
  assert.match(readme, /tools[\\\/]download-dtm-sources\.php/);
  assert.match(readme, /data\/catalog\/dtm_inventory\.sqlite/);
  assert.match(readme, /data\/coverage\/index\.json/);
  assert.match(readme, /v_missing_primary_fallback/);
  assert.doesNotMatch(readme, /Rust/i);
});

test("history records the initial implementation context", () => {
  const history = readText("history.md");

  assert.match(history, /2026-05-16/);
  assert.match(history, /台中、桃園、新北/);
  assert.match(history, /Docker Desktop/);
  assert.match(history, /大檔資料不簽入版控/);
  assert.match(history, /我把全臺含外島 `all_taiwan` provider 正式納入產線/);
  assert.match(history, /build-manifest\.json/);
  assert.match(history, /DTM 版本整併庫 V1/);
  assert.doesNotMatch(history, /Rust/i);
});

test("preview page can switch among generated terrain folders", () => {
  const preview = readText("viewer/terrain-preview.html");

  assert.match(preview, /terrain\/all_taiwan/);
  assert.match(preview, /terrain\/all_taiwan_from_grd/);
  assert.match(preview, /terrain\/taiwan/);
  assert.match(preview, /terrain\/taiwan_from_grd/);
  assert.match(preview, /select\.value = "all_taiwan"/);
  assert.match(preview, /loadTerrain\("all_taiwan"\)/);
  for (const id of expectedCountyIds) {
    assert.match(preview, new RegExp(`terrain/${id}`));
  }
  assert.match(preview, /Cesium\.CesiumTerrainProvider\.fromUrl/);
});
