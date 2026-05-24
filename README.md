# dem20M_terrain

本專案將 2025 年版 20M DTM 轉成 Cesium quantized-mesh terrain，目標是讓產線可以穩定重跑、續跑、驗證與發布。

正式產線以 `2025年版全臺灣20公尺網格數值地形模型DTM資料` 為主。疊圖策略是 2025 不分幅全臺當連續底圖、2025 縣市分幅補不分幅缺值；苗栗、新竹縣這類已確認 2025 仍有異常有效值或缺格的位置，內政部 `全臺灣20公尺網格數值地形模型資料` 的完整分幅會放在最上層修補。澎湖則保留內政部版本作為錯包/高程合理性比對。

## 產出

- 來源資料：`data/raw/<county>/`
- GDAL 中繼：`data/work/<county>/`
- 縣市 terrain：`output/<county>`；以 2025 DTM 為主，先用 2025 分幅補不分幅缺值，必要時再用內政部 DEM 補缺格（只補確認缺格）
- 全臺主島 terrain：`output/taiwan`
- 全臺含外島 terrain：`output/all_taiwan`
- 2025 分幅 GRD 組合本島：`output/taiwan_from_grd`
- 2025 分幅 GRD 組合含外島：`output/all_taiwan_from_grd`
- 每個 provider 都會產出 `layer.json`、`.terrain` 與 `build-manifest.json`

例子：

```text
output/taichung/
output/penghu/
output/taiwan/
output/all_taiwan/
```

大型下載資料與 terrain 成果不簽入版控；版控只追蹤設定、腳本、測試、viewer 與文件。

## 目前定版

2026-05-24 這版先以 terrain_demo 實測確認為正式可用版，發布目錄為 `Z:\data\terrain20M`，也就是站台 `/data/terrain20M`。

- `hsinchu_county`：直接使用內政部完整新竹縣 DEM 重轉，tile 數 3281。
- `taiwan`：2025 不分幅全臺主島 + 2025 縣市分幅補值 + 苗栗縣、新竹縣 MOI full composite 補洞，tile 數 75692。
- `all_taiwan`：`taiwan` 同策略再加 2025 不分幅澎湖、金門，tile 數 144313。
- terrain demo 快取版本號：`20260524-full-moi-composite`。

這版的關鍵修正是 full provider 不再直接把多個 MOI full raster 疊成 VRT 後交給 CTB，而是先用 `gdalwarp -srcnodata -32768 -dstnodata -32768` 燒成 composite GeoTIFF，避免後列來源的 NoData 把前列有效高程蓋掉。

## 資料來源

- 主要來源：政府資料開放平臺 [2025年版全臺灣20公尺網格數值地形模型DTM資料](https://data.gov.tw/dataset/176927)
- 主要下載清單：3WA 筆記 [2025 20M DEM TGOS 下載清單](https://3wa.tw/mypaper/?uid=shadow&mode=view&id=2695)
- 補洞/比對來源：政府資料開放平臺 [全臺灣20公尺網格數值地形模型資料](https://data.gov.tw/dataset/35430)
- 補洞/比對下載清單：3WA 筆記 [dem20M 內政部](https://3wa.tw/mypaper/index.php?uid=shadow&mode=view&id=2704)

正式產線目前使用 2025 來源：

- 21 個縣市分幅 DEM
- `不分幅_全台20MDEM(2025)`
- `不分幅_澎湖20MDEM(2025)`
- `不分幅_金門20MDEM(2025)`

主島來源座標以 `EPSG:3826` 處理；澎湖、金門這類 119 度分帶資料以 `EPSG:3825` 處理。`data/polygons/*.txt` 的檢查用 WKT 仍統一輸出成 `EPSG:3826`，方便 `check_grd.html` 用 Easymap 疊圖確認。

## DTM 版本整併庫 V1

V1 先做資料盤點與 tile bbox coverage，不重建 terrain、不發布、不把 NoData 轉 polygon。來源策略固定為 `2025 > 2024 > OLD > GLOBAL_RESERVED`：2025 DTM 是主資料，2024 與內政部 OLD DTM 只補缺，ASTER / SRTM / COPDEM 目前只保留 registry 欄位。

目前 annual catalog 先鎖三套：2025、2024、內政部 OLD。`config/dtm_source_datasets.json` 記官方 data.gov.tw 頁與 CSV API，`tools/update-dtm-sources.php` 會把 CSV 展開成 `config/dtm_sources.json`，避免以後手動補漏縣市。

```powershell
php .\tools\update-dtm-sources.php --datasets .\config\dtm_source_datasets.json --out .\config\dtm_sources.json
php .\tools\download-dtm-sources.php --source .\config\dtm_sources.json --only 2025,2024,OLD
```

下載器只抓 zip 到 `data/raw/`，不解壓、不建 catalog。官方年度 CSV 也會快取到 `data/source-catalog/`，方便追來源異動。

```powershell
php .\tools\build-dtm-catalog.php --source .\config\dtm_sources.json --db .\data\catalog\dtm_inventory.sqlite --coverage-dir .\data\coverage
```

主要輸出：

- `data/catalog/dtm_inventory.sqlite`
- `data/coverage/index.json`
- `data/coverage/best_source.json`
- `data/coverage/tiles_<source_id>.json`
- `data/coverage/missing_primary_fallback.json`
- `data/coverage/overlap_tiles.json`

SQLite 主要表與 view：

- `dtm_sources`
- `dtm_tiles`
- `v_tile_best_source`
- `v_missing_primary_fallback`
- `v_overlap_tiles`
- `v_coverage_summary`

`check_grd.html` 會讀 `data/coverage/index.json` 顯示 Coverage 模式，左側用頁籤切 `2025`、`2024`、`內政部` 三套來源，也可直接看整併後 best-source、fallback-only 缺格與 overlap tiles。Coverage JSON 的 WKT 固定輸出為 `EPSG:3826`，讓 Easymap 用 `dgWKT(rows, "EPSG:3826")` 疊圖。

## 必要工具

- PowerShell 7+
- GDAL
- Docker Desktop / Docker daemon
- CTB image：`ghcr.io/tum-gis/ctb-quantized-mesh:latest`
- Node.js，用來跑 repo 內的 contract tests

先檢查全部來源：

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\build-terrain.ps1 -All -ValidateOnly
```

正式產製 21 個縣市：

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\build-terrain.ps1 -All
```

正式產製縣市、全臺主島與全臺含外島 provider：

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\build-terrain.ps1 -AllWithTaiwan
```

如果 2025 不分幅全臺主島來源暫時不可用，可手動指定回到縣市 mosaic 流程；澎湖、金門仍會強制使用 2025 不分幅離島來源，不會退回疑似錯包的分幅資料：

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\build-terrain.ps1 -AllWithTaiwan -SkipUnifiedTaiwanSource
```

只產台中：

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\build-terrain.ps1 -County taichung
```

一次產多個指定縣市：

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\build-terrain.ps1 -County taichung,penghu
```

只修補關鍵 provider（例：苗栗/新竹縣補洞、澎湖/金門離島、本島與含外島）：

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\build-terrain.ps1 -County miaoli,hsinchu_county,penghu,kinmen -AllWithTaiwan
```

有指定 `-County` 時，`-AllWithTaiwan` 只重建指定縣市 provider；`output/taiwan` 與 `output/all_taiwan` 仍會使用 2025 不分幅主島、指定縣市補洞來源，以及 2025 不分幅澎湖/金門。

苗栗或新竹縣若要整套改用內政部 DEM 重轉比對，不覆蓋正式縣市輸出，會輸出到 `output/<county>_moi`：

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\build-terrain.ps1 -County miaoli,hsinchu_county -UseMoiForCounty
```

若要把內政部完整苗栗、新竹縣 DEM 納入全臺主島與全臺含外島的下層補源，只重建 `output/taiwan` 與 `output/all_taiwan`：

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\build-terrain.ps1 -County miaoli,hsinchu_county -AllWithTaiwan -UseMoiForCounty
```

若要完全用 2025 縣市分幅 GRD 組一套獨立 provider，苗栗、新竹縣改用內政部完整 DEM，會產出 `output/taiwan_from_grd` 與 `output/all_taiwan_from_grd`，不覆蓋正式 `taiwan` / `all_taiwan`：

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\build-terrain.ps1 -AllWithTaiwan -FromGrd
```

重建既有輸出：

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\build-terrain.ps1 -AllWithTaiwan -ForceRebuild
```

## 產製流程

1. 使用 `Invoke-WebRequest -Method Head` 檢查 TGOS zip 連結與檔案大小。
2. 下載 zip 到 `data/raw/<county>/`，解壓到 `data/raw/<county>/extract/`。
3. 掃描 DEM raster / grid 檔。
4. 優先用 `gdalbuildvrt` 建來源 VRT。
5. 如果來源 grid 因 positive NS resolution 不能直接建 VRT，改用 `gdalwarp` 逐檔轉成 north-up GeoTIFF。
6. 如果遇到 GDAL 無法直接讀取的稀疏 XYZ，先補齊缺格為 `-32768` 再重試。
7. 將來源合併後轉成 `EPSG:4326` GeoTIFF。
8. 在 `-AllWithTaiwan` 流程中，優先下載 2025 官方不分幅全臺 TIF，轉成 `data/work/taiwan_unified/taiwan_unified-4326.tif`。
9. 澎湖、金門正式 terrain 優先使用 2025 官方不分幅離島 GeoTIFF。
10. 用 2025 不分幅全臺來源裁主島縣市 bbox，再用 2025 分幅補不分幅缺值；遇到 2025 分幅也缺的確認缺格時，才用內政部 DEM 補。
11. 用 Docker 執行 `ctb-tile -f Mesh -p geodetic -C` 產出 quantized-mesh terrain。
12. 將 `.terrain.gz` 或 gzip 內容的 `.terrain` 正規化成未壓縮 `.terrain`，避免 Web Server 沒送 `Content-Encoding: gzip` 時 Cesium 讀壞。
13. 使用 raster metadata 回寫 `layer.json` 的實際 `bounds`。
14. 寫出 `build-manifest.json`，記錄來源、bbox、tile 數、zoom levels、GDAL/Docker/CTB 設定。
15. 先產到 `.tmp-<run>` 目錄，驗證成功後才發布到正式 output，避免中斷留下半套成果。

## 全臺含外島 all_taiwan

`all_taiwan` 不是前端拼接多個縣市，而是產線中正式建立的合併 provider。目前資料源以 2025 `不分幅_全台20MDEM(2025)` 加上 2025 不分幅澎湖、金門為主；2025 縣市分幅會放在下層補不分幅缺值，苗栗、新竹縣這類 2025 分幅也缺的確認缺格，再用內政部 DEM 補。

`taiwan` 是只含主島的正式 provider，來源策略與 `all_taiwan` 的主島部分相同；`all_taiwan` 則再加 2025 不分幅澎湖、金門。這樣前端可依需求載入 `terrain/taiwan` 或 `terrain/all_taiwan`，不用在 Cesium 端拼多個 terrain provider。

流程：

1. `-AllWithTaiwan` 會先跑縣市來源，確保縣市有 EPSG:4326 raster 與 bbox；若有指定 `-County`，就只跑指定縣市來源。
2. 下載並轉換 2025 `不分幅_全台20MDEM(2025)`、`不分幅_澎湖20MDEM(2025)`、`不分幅_金門20MDEM(2025)`。
3. 用 2025 縣市分幅、2025 不分幅全臺主島、離島 raster 建立合併清單；若使用 `-UseMoiForCounty`，苗栗、新竹縣的內政部完整 DEM 會最後加入，再用 `gdalwarp -srcnodata -32768` 先燒成 NoData 透明的 composite GeoTIFF，避免上層補源的 NoData 蓋掉下層有效值。
4. 先產出 `output/taiwan`，`buildKind` 會記為 `taiwan_unified_split_gapfill` 或 `taiwan_unified_split_moi_gapfill`。
5. 再用同一套 CTB 流程產出 `output/all_taiwan`，`buildKind` 會記為 `all_taiwan_unified_split_gapfill` 或 `all_taiwan_unified_split_moi_gapfill`。
6. 再用 2025 不分幅全臺 raster 依各縣市原始 bbox 裁出 `data/work/<county>/<county>-unified-4326.tif`，並疊 2025 分幅與必要的內政部補洞來源產主島縣市 `output/<county>`；澎湖、金門使用 2025 不分幅離島 GeoTIFF。

若加上 `-UseMoiForCounty`，苗栗、新竹縣可改用 `data/work/<county>_moi_full/<county>_moi_full-4326.tif` 作為完整內政部補源；`taiwan` / `all_taiwan` 的 buildKind 會分別記為 `taiwan_unified_split_moi_full_gapfill`、`all_taiwan_unified_split_moi_full_gapfill`。這個模式會先建立 `data/work/taiwan/*-moi-full-composite-4326.tif` / `data/work/all_taiwan/*-moi-full-composite-4326.tif` 再切 terrain，避免 VRT 疊多個 MOI full 時 NoData 互相蓋掉。這個模式只重建全臺 provider，不會順手覆蓋正式縣市 `output/<county>`。

`-FromGrd` 是另一條獨立比對線：`taiwan_from_grd` 只含臺灣本島，由 2025 各縣市分幅 GRD 組成，苗栗與新竹縣直接用 `*_moi_full` 取代 2025 年度分幅；`all_taiwan_from_grd` 則在同一個本島 VRT 外，再加入 2025 官方不分幅澎湖與金門。澎湖、金門仍不使用疑似錯包的 2025 分幅 GRD。

Cesium 同時間只會掛一個 `terrainProvider`，所以全臺含外島必須是獨立 provider，不能只靠前端多選縣市。

縣市分幅本身是不規則覆蓋，如果直接把單一縣市來源做成 provider，畫面跨到縣市邊界時會看到 NoData 被拉成牆。`-AllWithTaiwan` 的主島縣市 provider 改由 2025 不分幅全臺來源裁 bbox，保留縣市端點，也讓邊界附近有連續地形銜接；2025 分幅只作為下層補不分幅缺值，避免苗栗、新竹山區這類不分幅空窗。只有像苗栗、新竹縣這種已確認 2025 分幅也缺、且內政部有對應格網時才補。

澎湖、金門的離島資料座標應以 `EPSG:3825` 解讀，不是本島常用的 `EPSG:3826`。

澎湖正式輸出禁止使用 `分幅_澎湖縣20MDEM(2025).zip`。該分幅包已確認疑似南投山區錯包，只保留給 `check_grd.html` 診斷；正式 terrain 必須使用 `不分幅_澎湖20MDEM(2025)`，避免輸出位置錯誤。

## Resume 與安全發布

產線支援續跑，但不只看資料夾是否存在。

既有 output 會先確認：

- `layer.json` 存在
- 至少有一個 `.terrain`
- `build-manifest.json` 的 `buildKind` 符合目前要產的類型
- 驗證通過才會跳過 CTB

如果要重建，使用 `-ForceRebuild`。正式 output 採 atomic publish：先產到暫存 output，驗證後再替換正式 output。

## Cesium 接法

靜態發布時，把 `output/<provider>` 放到 web root 的 `terrain/<provider>`。

```js
viewer.terrainProvider = await Cesium.CesiumTerrainProvider.fromUrl("terrain/all_taiwan");

viewer.terrainProvider = await Cesium.CesiumTerrainProvider.fromUrl("terrain/all_taiwan", {
  requestVertexNormals: true,
  requestWaterMask: false
});
```

縣市 provider 也一樣：

```js
viewer.terrainProvider = await Cesium.CesiumTerrainProvider.fromUrl("terrain/taichung", {
  requestVertexNormals: true,
  requestWaterMask: false
});
```

## Apache / Nginx / IIS

Apache `.htaccess`：

```apache
AddType application/json .json
AddType application/vnd.quantized-mesh .terrain

<IfModule mod_headers.c>
  <FilesMatch "\.(json|terrain)$">
    Header set Access-Control-Allow-Origin "*"
  </FilesMatch>
</IfModule>
```

Nginx：

```nginx
types {
    application/json json;
    application/vnd.quantized-mesh terrain;
}
add_header Access-Control-Allow-Origin *;
```

IIS：

```xml
<staticContent>
  <mimeMap fileExtension=".terrain" mimeType="application/vnd.quantized-mesh" />
  <mimeMap fileExtension=".json" mimeType="application/json" />
</staticContent>
```

## 預覽

`viewer/terrain-preview.html` 是 Cesium terrain 切換測試頁。部署時讓頁面所在 web root 可讀到：

```text
terrain/all_taiwan/layer.json
terrain/taichung/layer.json
terrain/penghu/layer.json
```

## 驗證

```powershell
node --test tests/*.test.js
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\build-terrain.ps1 -All -ValidateOnly
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\build-terrain.ps1 -AllWithTaiwan -ValidateOnly
git status --short --branch
```

發布後使用 HTTP 檢查：

```bash
curl -I https://example.com/terrain/all_taiwan/layer.json
curl -I https://example.com/terrain/all_taiwan/0/0/0.terrain
```

`.terrain` 應該回 `Content-Type: application/vnd.quantized-mesh`。

## 適用範圍

這套 20M terrain 適合做全臺、縣市、山區、災防、林火、水庫、路廊等大範圍 3D 地形底座。

它不適合做工程級高程、都市微地形、道路/橋梁細節或建物精準貼地。後續若要接建物 3D Tiles，需要另外定義 terrain-on 與 terrain-off 的高度策略。

## 研究筆記

這次整理下來，不再把「年度較新」直接視為「資料較正確」。DEM 來源要用圖台與分幅 bbox 實際疊過一次，尤其是山區縣市和離島。

TGOS zip 的 `Last-Modified` 顯示 2025 來源確實比較新：2025 分幅大多是 `2025-09-09` 到 `2025-09-10`，高雄、臺東甚至更新到 `2026-02-23`；內政部 35430 大多是 `2024-04-11`，臺南是 `2024-04-23`。所以正式產線仍以 2025 DTM 為主，內政部資料只當補洞與異常比對來源。

苗栗、新竹山區的缺洞比較像資料釋出策略造成的空窗，而不是轉檔錯誤。工作假設是：舊版不分幅全臺在機敏或管制區附近可能保留 NoData，分幅版或圖資服務雲查詢到的分幅資料可能提供較完整覆蓋；所以正式流程不單吃不分幅，而是把 2025 分幅放在不分幅下層補值。若 2025 分幅仍缺，再用內政部資料集中已確認的分幅格網補洞。

苗栗缺洞的重點不是下載失敗，也不是轉檔漏檔；年度版分幅資料在同一個位置缺同一塊。內政部 `分幅_苗栗縣DEM.zip` 則有 306 個 `.grd`，比先前測過的年度版多 17 格，剛好補到苗栗東北側缺角。後續用 terrain_demo 疊 `/data/city.json` 縣市界後確認，視覺上被誤判成苗栗的缺洞其實有一段落在新竹縣山區；內政部 `分幅_新竹縣DEM.zip` 有 246 個 `.grd`，比 2025 新竹縣分幅多 7 格，因此也納入 MOI full 補源。這代表同樣是 TGOS 下載點，不同 data.gov.tw 資料集指到的 Product UUID 可能有不同內容，不能只看檔名像不像。

苗栗缺格 snapshot 放在 `snapshots/miaoli-gap-annual-vs-moi.png`，紅色是內政部比 2025/2024 年度分幅多出的 17 格，方便後續回看補洞依據。

澎湖問題更明顯：某包澎湖分幅 `.grd` 疑似錯包成南投山區資料。它的格網若用本島分帶會落在南投附近，高程約 `500~3500m` 也像山區；硬轉外島分帶再平移到澎湖，只會得到看似漂亮但本質錯誤的假格網。內政部 `分幅_澎湖縣DEM.zip` 內含 92 個 `.grd`，扣掉 `-999` 後高程約 `-0.5~122m`，比對澎湖地形合理許多。

後續檢查流程以 `check_grd.html` 為準：先套縣市界線，再疊各來源的 GRD bbox。點 GRD 格可看縣市與檔名，方便追缺格、錯位、錯包。`data/polygons/*.txt` 只用於檢查 bbox 覆蓋與分幅關係，不代表 terrain 高程本身已驗證完成。
