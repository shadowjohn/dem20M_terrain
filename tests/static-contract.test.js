const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const root = path.resolve(__dirname, "..");

function readText(relativePath) {
  return fs.readFileSync(path.join(root, relativePath), "utf8");
}

test("county config tracks the three first delivery targets and TGOS sources", () => {
  const counties = JSON.parse(readText("config/counties.json"));
  const ids = counties.map((county) => county.id).sort();

  assert.deepEqual(ids, ["newtaipei", "taichung", "taoyuan"]);

  for (const county of counties) {
    assert.match(county.url, /^https:\/\/www\.tgos\.tw:443\/MDE\/VirtualDir_TC\/Product\//);
    assert.match(county.zipName, /\.zip$/);
    assert.equal(county.targetSrs, "EPSG:4326");
    assert.equal(county.outputDir, `output/${county.id}`);
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
});

test("documentation explains run, output, Cesium, IIS, and verification", () => {
  const readme = readText("README.md");

  assert.match(readme, /pwsh\.exe -NoProfile -ExecutionPolicy Bypass -File \.\\tools\\build-terrain\.ps1 -All/);
  assert.match(readme, /output\/taichung/);
  assert.match(readme, /output\/taoyuan/);
  assert.match(readme, /output\/newtaipei/);
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

  assert.match(preview, /terrain\/taichung/);
  assert.match(preview, /terrain\/taoyuan/);
  assert.match(preview, /terrain\/newtaipei/);
  assert.match(preview, /Cesium\.CesiumTerrainProvider\.fromUrl/);
});
