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
  assert.match(script, /未知縣市 id/);
  assert.match(script, /ProgressMessage/);
  assert.match(script, /指令執行中/);
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

test("build script skips existing generated TIFF files unless force rebuild is requested", () => {
  const script = readText("tools/build-terrain.ps1");

  assert.match(script, /GeoTIFF 已存在，跳過轉檔/);
  assert.match(script, /EPSG:4326 TIFF 已存在，跳過重投影/);
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

test("documentation explains sources, run, output, Cesium, IIS, and verification", () => {
  const readme = readText("README.md");

  assert.match(readme, /https:\/\/data\.gov\.tw\/dataset\/176927/);
  assert.match(readme, /https:\/\/3wa\.tw\/mypaper\/\?uid=shadow&mode=view&id=2695/);
  assert.match(readme, /21 個分幅縣市/);
  assert.match(readme, /pwsh\.exe -NoProfile -ExecutionPolicy Bypass -File \.\\tools\\build-terrain\.ps1 -All/);
  assert.match(readme, /output\/taichung/);
  assert.match(readme, /output\/kinmen/);
  assert.match(readme, /Cesium\.CesiumTerrainProvider\.fromUrl\("terrain\/taichung"\)/);
  assert.match(readme, /application\/vnd\.quantized-mesh/);
  assert.match(readme, /node --test tests\/\*\.test\.js/);
});

test("history records the initial implementation context", () => {
  const history = readText("history.md");

  assert.match(history, /2026-05-16/);
  assert.match(history, /台中、桃園、新北/);
  assert.match(history, /Docker Desktop/);
  assert.match(history, /大檔資料不簽入版控/);
});

test("preview page can switch among generated terrain folders", () => {
  const preview = readText("viewer/terrain-preview.html");

  for (const id of expectedCountyIds) {
    assert.match(preview, new RegExp(`terrain/${id}`));
  }
  assert.match(preview, /Cesium\.CesiumTerrainProvider\.fromUrl/);
});
