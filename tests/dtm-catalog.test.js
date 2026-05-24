const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const test = require("node:test");

const root = path.resolve(__dirname, "..");

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: root,
    encoding: "utf8",
    ...options,
  });
  assert.equal(
    result.status,
    0,
    `${command} ${args.join(" ")}\nSTDOUT:\n${result.stdout}\nSTDERR:\n${result.stderr}`
  );
  return result.stdout;
}

function writeFixtureZip(zipPath, entries) {
  const phpCode = `
    $zip = new ZipArchive();
    if ($zip->open($argv[1], ZipArchive::CREATE | ZipArchive::OVERWRITE) !== true) { fwrite(STDERR, "zip open failed"); exit(1); }
    $entries = json_decode($argv[2], true);
    foreach ($entries as $name => $body) { $zip->addFromString($name, $body); }
    $zip->close();
  `;
  run("php", ["-r", phpCode, zipPath, JSON.stringify(entries)]);
}

function grd(minX, minY) {
  return [
    `${minX} ${minY} 1`,
    `${minX + 20} ${minY} 2`,
    `${minX} ${minY + 20} 3`,
    `${minX + 20} ${minY + 20} 4`,
  ].join("\n");
}

test("DTM catalog builder creates SQLite inventory and coverage JSON from fixture zips", () => {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "dtm-catalog-"));
  const primaryZip = path.join(tempRoot, "primary-2025.zip");
  const oldZip = path.join(tempRoot, "old.zip");
  const sourcePath = path.join(tempRoot, "dtm_sources.json");
  const dbPath = path.join(tempRoot, "dtm_inventory.sqlite");
  const coverageDir = path.join(tempRoot, "coverage");

  writeFixtureZip(primaryZip, {
    "10000001dem.grd": grd(250000, 2700000),
    "10000002dem.grd": grd(250040, 2700000),
  });
  writeFixtureZip(oldZip, {
    "10000001dem.grd": grd(250000, 2700000),
    "10000003dem.grd": grd(250080, 2700000),
  });

  fs.writeFileSync(
    sourcePath,
    JSON.stringify(
      {
        schemaVersion: 1,
        sources: [
          {
            id: "fixture_2025_miaoli",
            name: "Fixture 2025 Miaoli",
            version: "2025",
            priority: 1,
            role: "primary",
            countyId: "miaoli",
            countyName: "苗栗縣",
            sourceSrs: "EPSG:3826",
            zipPath: primaryZip,
            enabled: true,
          },
          {
            id: "fixture_old_miaoli",
            name: "Fixture OLD Miaoli",
            version: "OLD",
            priority: 3,
            role: "fallback",
            countyId: "miaoli",
            countyName: "苗栗縣",
            sourceSrs: "EPSG:3826",
            zipPath: oldZip,
            enabled: true,
          },
        ],
      },
      null,
      2
    )
  );

  run("php", [
    "tools/build-dtm-catalog.php",
    "--source",
    sourcePath,
    "--db",
    dbPath,
    "--coverage-dir",
    coverageDir,
  ]);

  const schema = run("sqlite3", [dbPath, ".schema"]);
  for (const name of [
    "dtm_sources",
    "dtm_tiles",
    "v_tile_best_source",
    "v_missing_primary_fallback",
    "v_overlap_tiles",
    "v_coverage_summary",
  ]) {
    assert.match(schema, new RegExp(name));
  }

  const index = JSON.parse(fs.readFileSync(path.join(coverageDir, "index.json"), "utf8"));
  assert.equal(index.schemaVersion, 1);
  assert.equal(index.epsg, "EPSG:3826");
  assert.equal(index.sources.length, 2);
  assert.equal(index.layers.bestSource, "best_source.json");
  assert.equal(index.layers.missingPrimaryFallback, "missing_primary_fallback.json");

  const primaryTiles = JSON.parse(
    fs.readFileSync(path.join(coverageDir, "tiles_fixture_2025_miaoli.json"), "utf8")
  );
  assert.equal(primaryTiles.source.id, "fixture_2025_miaoli");
  assert.equal(primaryTiles.tiles.length, 2);
  assert.match(primaryTiles.tiles[0].wkt, /^POLYGON\(\(/);
  assert.equal(primaryTiles.tiles[0].epsg, "EPSG:3826");
  assert.match(primaryTiles.tiles[0].md5, /^[a-f0-9]{32}$/);

  const fallback = JSON.parse(
    fs.readFileSync(path.join(coverageDir, "missing_primary_fallback.json"), "utf8")
  );
  assert.deepEqual(
    fallback.tiles.map((tile) => tile.tileKey),
    ["10000003dem"]
  );
  assert.equal(fallback.tiles[0].sourceId, "fixture_old_miaoli");

  const bestSource = JSON.parse(fs.readFileSync(path.join(coverageDir, "best_source.json"), "utf8"));
  assert.equal(bestSource.tiles.length, 3);

  const bestCount = run("sqlite3", [
    dbPath,
    "select count(*) from v_tile_best_source where county_id='miaoli';",
  ]).trim();
  assert.equal(bestCount, "3");
});

test("DTM catalog ignores reference layers for best-source and fallback-missing views", () => {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "dtm-catalog-reference-"));
  const referenceZip = path.join(tempRoot, "reference.zip");
  const sourcePath = path.join(tempRoot, "dtm_sources.json");
  const dbPath = path.join(tempRoot, "dtm_inventory.sqlite");
  const coverageDir = path.join(tempRoot, "coverage");

  writeFixtureZip(referenceZip, {
    "taiwan.tif.grd": grd(250000, 2700000),
  });

  fs.writeFileSync(
    sourcePath,
    JSON.stringify(
      {
        schemaVersion: 1,
        sources: [
          {
            id: "fixture_reference_taiwan",
            name: "Fixture Taiwan Reference",
            version: "2025",
            priority: 1,
            role: "reference",
            countyId: "taiwan",
            countyName: "全臺主島",
            sourceSrs: "EPSG:3826",
            zipPath: referenceZip,
            enabled: true,
          },
        ],
      },
      null,
      2
    )
  );

  run("php", [
    "tools/build-dtm-catalog.php",
    "--source",
    sourcePath,
    "--db",
    dbPath,
    "--coverage-dir",
    coverageDir,
  ]);

  const bestCount = run("sqlite3", [dbPath, "select count(*) from v_tile_best_source;"]).trim();
  const missingCount = run("sqlite3", [dbPath, "select count(*) from v_missing_primary_fallback;"]).trim();
  assert.equal(bestCount, "0");
  assert.equal(missingCount, "0");
});
