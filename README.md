# dem20M_terrain

2025 版 20M DEM 轉 Cesium quantized-mesh terrain 的可重跑流程。目前 config 放入 21 個分幅縣市資料。

## 目標

- 來源資料放在 `data/raw/<county>/`。
- GDAL 中繼資料放在 `data/work/<county>/`。
- 最終 Cesium terrain 放在 `output/<county>`，例如 `output/taichung`、`output/newtaipei`、`output/kinmen`。
- 大型下載資料與 terrain 成果不簽入版控，只追蹤設定、腳本、測試與文件。

## 資料來源

- 政府資料開放平臺：[2025年版全臺灣20公尺網格數值地形模型DTM資料](https://data.gov.tw/dataset/176927)
- 3WA 筆記：[2025 20M DEM TGOS 下載清單](https://3wa.tw/mypaper/?uid=shadow&mode=view&id=2695)

`config/counties.json` 收錄 21 個分幅縣市 TGOS zip，未收錄 `schema_hdr`、`不分幅_澎湖`、`不分幅_金門`、`不分幅_全台`。

| county | name | TGOS 2025 20MDEM |
| --- | --- | --- |
| keelung | 基隆市 | https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/2313548d-ccaa-4539-81a3-13f5a0e94dbd/分幅_基隆市20MDEM(2025).zip |
| taipei | 臺北市 | https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/60e634ea-7c59-47a4-a967-ac33694e0d05/分幅_臺北市20MDEM(2025).zip |
| newtaipei | 新北市 | https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/9574dbb5-ca32-4ea3-aaf7-a9f582b9357b/分幅_新北市20MDEM(2025).zip |
| taoyuan | 桃園市 | https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/ba0fcc26-f82e-4345-bfc4-4785574d9014/分幅_桃園市20MDEM(2025).zip |
| hsinchu_county | 新竹縣 | https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/cc78d253-6b5a-47d8-85c7-996b91749945/分幅_新竹縣20MDEM(2025).zip |
| hsinchu_city | 新竹市 | https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/d3b4ae6e-4ca2-40da-9a32-28769415dd3a/分幅_新竹市20MDEM(2025).zip |
| miaoli | 苗栗縣 | https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/a455608a-d932-48e2-b0f9-c864a8f566e2/分幅_苗栗縣20MDEM(2025).zip |
| taichung | 臺中市 | https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/ef57682a-4ec6-45a5-a265-a4dda08e6f7f/分幅_臺中市20MDEM(2025).zip |
| changhua | 彰化縣 | https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/5acc0542-ffcb-4c9f-9200-876b97ff6355/分幅_彰化縣20MDEM(2025).zip |
| nantou | 南投縣 | https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/29d2ab12-bda0-4c5c-b547-ce0a8c3f1231/分幅_南投縣20MDEM(2025).zip |
| yunlin | 雲林縣 | https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/0e6e327a-6910-42fd-be5c-00a2ac2c4b54/分幅_雲林縣20MDEM(2025).zip |
| chiayi_county | 嘉義縣 | https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/e0be7bc8-714c-40b5-9658-b9269a1a73df/分幅_嘉義縣20MDEM(2025).zip |
| chiayi_city | 嘉義市 | https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/c93b7a60-820a-47e5-88d7-8280c6ae7665/分幅_嘉義市20MDEM(2025).zip |
| tainan | 臺南市 | https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/8c0f413d-bfdc-4e7c-b173-a9829e5ddc78/分幅_臺南市20MDEM(2025).zip |
| kaohsiung | 高雄市 | https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/bcb6993a-e17a-408f-b82e-1fc4ba2370ef/分幅_高雄市20MDEM(2025).zip |
| pingtung | 屏東縣 | https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/6063e435-51c2-4035-a4b6-a846aea91161/分幅_屏東縣20MDEM(2025).zip |
| yilan | 宜蘭縣 | https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/fd54d8f2-ad3b-4afe-b30d-cf86ad845cae/分幅_宜蘭縣20MDEM(2025).zip |
| hualien | 花蓮縣 | https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/4d5725ad-1be0-4b90-be5a-ca1071690fec/分幅_花蓮縣20MDEM(2025).zip |
| taitung | 臺東縣 | https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/794ca116-8ceb-4c4b-af3d-3e7c46398660/分幅_臺東縣20MDEM(2025).zip |
| penghu | 澎湖縣 | https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/c1bdbb99-6290-42fb-a971-3db9fae3242c/分幅_澎湖縣20MDEM(2025).zip |
| kinmen | 金門縣 | https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/821ed3ad-7825-4fe6-aaac-d2d6df8ac7cb/分幅_金門縣20MDEM(2025).zip |

來源座標系先視為 `EPSG:3826`，正式 terrain 前會轉成 `EPSG:4326`。

## 必要工具

- PowerShell 7
- GDAL：目前使用 `C:\ms4w_MSSQL\GDAL`
- Docker Desktop
- CTB image：`ghcr.io/tum-gis/ctb-quantized-mesh:latest`

先檢查全部來源：

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\build-terrain.ps1 -All -ValidateOnly
```

正式產製全部縣市：

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\build-terrain.ps1 -All
```

只產台中：

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\build-terrain.ps1 -County taichung
```

一次產多個指定縣市：

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\build-terrain.ps1 -County taichung,kinmen
```

重建既有輸出：

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\build-terrain.ps1 -All -ForceRebuild
```

## 產製流程

1. `Invoke-WebRequest -Method Head` 確認 TGOS zip 連結與檔案大小。
2. 下載 zip 到 `data/raw/<county>/`，解壓到 `data/raw/<county>/extract/`。
3. 用 `gdalbuildvrt` 建來源 VRT；若來源 grid 因 positive NS resolution 不能直接建 VRT，改用 `gdalwarp` 逐檔轉成 north-up GeoTIFF。遇到 GDAL 無法直接讀取的稀疏 XYZ，會先補齊缺格為 `-32768` 再重試。
4. 已產出的 `data/work/<county>/northup/*.tif` 與 `data/work/<county>/<county>-4326.tif` 會自動跳過；需要重產時加 `-ForceRebuild`。
5. 用 `gdalwarp` 將合併後資料轉成 `EPSG:4326`。
6. Docker 執行 `ctb-tile -f Mesh -p geodetic -C` 產出 terrain 與 `layer.json`。
7. `Normalize-TerrainTiles` 將 `.terrain.gz` 或 gzip 內容的 `.terrain` 解成未壓縮 `.terrain`，避免 IIS 沒設 `Content-Encoding: gzip` 時 Cesium 讀壞。
8. 檢查 `layer.json` 與至少一個 `.terrain`。
9. 將每縣市結果追加到 `history.md`。

## Cesium 接法

靜態發布時，把 `output/<county>` 放到 web root 的 `terrain/<county>`。

```js
viewer.terrainProvider = await Cesium.CesiumTerrainProvider.fromUrl("terrain/taichung");

viewer.terrainProvider = await Cesium.CesiumTerrainProvider.fromUrl("terrain/taichung", {
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
terrain/newtaipei/layer.json
terrain/kinmen/layer.json
```

## 驗證

```powershell
node --test tests/*.test.js
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\build-terrain.ps1 -All -ValidateOnly
git status --short --branch
```

目前若尚未安裝 Docker Desktop，第二個指令會停在 docker 前置檢查，這是預期的環境阻擋。
