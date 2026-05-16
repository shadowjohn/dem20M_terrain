# dem20M_terrain

台中、桃園、新北 2025 版 20M DEM 轉 Cesium quantized-mesh terrain 的可重跑流程。

## 目標

- 來源資料放在 `data/raw/<county>/`。
- GDAL 中繼資料放在 `data/work/<county>/`。
- 最終 Cesium terrain 放在 `output/taichung`、`output/taoyuan`、`output/newtaipei`。
- 大型下載資料與 terrain 成果不簽入版控，只追蹤設定、腳本、測試與文件。

## 資料來源

| county | TGOS 2025 20MDEM |
| --- | --- |
| taichung | https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/ef57682a-4ec6-45a5-a265-a4dda08e6f7f/分幅_臺中市20MDEM(2025).zip |
| taoyuan | https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/ba0fcc26-f82e-4345-bfc4-4785574d9014/分幅_桃園市20MDEM(2025).zip |
| newtaipei | https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/9574dbb5-ca32-4ea3-aaf7-a9f582b9357b/分幅_新北市20MDEM(2025).zip |

來源座標系先視為 `EPSG:3826`，正式 terrain 前會轉成 `EPSG:4326`。

## 必要工具

- PowerShell 7
- GDAL：目前使用 `C:\ms4w_MSSQL\GDAL`
- Docker Desktop
- CTB image：`ghcr.io/tum-gis/ctb-quantized-mesh:latest`

先檢查：

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\build-terrain.ps1 -All -ValidateOnly
```

正式產製三縣市：

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\build-terrain.ps1 -All
```

只產台中：

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\build-terrain.ps1 -County taichung
```

重建既有輸出：

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\build-terrain.ps1 -All -ForceRebuild
```

## 產製流程

1. `Invoke-WebRequest -Method Head` 確認 TGOS zip 連結與檔案大小。
2. 下載 zip 到 `data/raw/<county>/`，解壓到 `data/raw/<county>/extract/`。
3. 用 `gdalbuildvrt` 建來源 VRT；若來源 grid 不能直接建 VRT，改用 `gdal_translate` 逐檔轉 GeoTIFF。
4. 用 `gdalwarp` 轉成 `EPSG:4326`。
5. Docker 執行 `ctb-tile -f Mesh -p geodetic -C` 產出 terrain 與 `layer.json`。
6. `Normalize-TerrainTiles` 將 `.terrain.gz` 或 gzip 內容的 `.terrain` 解成未壓縮 `.terrain`，避免 IIS 沒設 `Content-Encoding: gzip` 時 Cesium 讀壞。
7. 檢查 `layer.json` 與至少一個 `.terrain`。
8. 將每縣市結果追加到 `history.md`。

## Cesium 接法

靜態發布時，把 `output/<county>` 放到 web root 的 `terrain/<county>`。

```js
viewer.terrainProvider = await Cesium.CesiumTerrainProvider.fromUrl("terrain/taichung");
viewer.terrainProvider = await Cesium.CesiumTerrainProvider.fromUrl("terrain/taoyuan");
viewer.terrainProvider = await Cesium.CesiumTerrainProvider.fromUrl("terrain/newtaipei");

viewer.terrainProvider = await Cesium.CesiumTerrainProvider.fromUrl("terrain/taichung", {
  requestVertexNormals: true,
});

viewer.terrainProvider = await Cesium.CesiumTerrainProvider.fromUrl("terrain/taoyuan", {
  requestVertexNormals: true,
});

viewer.terrainProvider = await Cesium.CesiumTerrainProvider.fromUrl("terrain/newtaipei", {
  requestVertexNormals: true,
});
```

IIS MIME 建議：

```xml
<staticContent>
  <mimeMap fileExtension=".terrain" mimeType="application/vnd.quantized-mesh" />
  <mimeMap fileExtension=".json" mimeType="application/json" />
</staticContent>
```

若選擇保留 gzip 版 `.terrain`，IIS 還要正確送 `Content-Encoding: gzip`；本 repo 預設改成未壓縮 `.terrain`，優先換穩定。

## 預覽

`viewer/terrain-preview.html` 是 Cesium terrain 切換測試頁。部署時讓頁面所在 web root 可讀到：

```text
terrain/taichung/layer.json
terrain/taoyuan/layer.json
terrain/newtaipei/layer.json
```

## 驗證

```powershell
node --test tests/*.test.js
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\build-terrain.ps1 -All -ValidateOnly
git status --short --branch
```

目前若尚未安裝 Docker Desktop，第二個指令會停在 docker 前置檢查，這是預期的環境阻擋。
