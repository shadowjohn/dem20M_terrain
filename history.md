# dem20M_terrain History

## 2026-05-16 - Initial terrain pipeline

- 建立台中、桃園、新北 20M DEM 轉 Cesium quantized-mesh terrain 的可重跑流程。
- 來源採用 TGOS 2025 20MDEM；HEAD 檢查三個縣市連結皆回傳 200。
- 台中來源大小：38501281 bytes。
- 桃園來源大小：20272123 bytes。
- 新北來源大小：36525419 bytes。
- Builder 鎖定 Docker Desktop 與 `ghcr.io/tum-gis/ctb-quantized-mesh:latest`。
- 大檔資料不簽入版控：`data/raw/`、`data/work/`、`output/`、zip、GeoTIFF、terrain 均由 `.gitignore` 排除。
- 後續正式執行 `tools/build-terrain.ps1` 時，每縣市成功或失敗會追加記錄到本檔。

## 2026-05-23 - 我把全臺含外島 all_taiwan 納入主流程

- 我把全臺含外島 `all_taiwan` provider 正式納入產線。
- 我新增 `-AllWithTaiwan`，讓它先產 21 個縣市，再用 21 個縣市 EPSG:4326 GeoTIFF 建立全臺 VRT，最後產出 `output/all_taiwan`。
- 我把原本直接寫正式 output 的方法改成先寫 `.tmp-<run>`，驗證成功後才發布，避免中斷留下半套 terrain。
- 我讓 resume 不只看資料夾是否存在，會檢查 `layer.json` 與至少一個 `.terrain`。
- 我讓 `layer.json` 回寫 raster 的實際 bounds，不再只依賴 CTB 預設世界範圍。
- 我新增 `build-manifest.json`，記錄 provider、bbox、tile 數、zoom levels、CTB image、產製時間與補洞設定。
- 我把大量短外部指令的輪詢從固定等待改成短輪詢，避免 GDAL 小檔轉檔被等待時間拖慢。
- 我把 terrain 正規化 log 改成批次進度，保留可讀性又避免逐 tile 洗版。
- 我把 viewer 預設改成 `all_taiwan`，讓預覽先看到全臺含外島，再切縣市。

## 2026-05-23 - 我修正縣市 provider 的 NoData 邊界牆

- 我檢查苗栗 provider 後確認 `.terrain` 檔不是少檔；問題是單一縣市 DEM 覆蓋範圍不規則，NoData 從縣市邊界伸進 bbox，Cesium 會把邊界拉成明顯的牆。
- 我不把這件事當成 CTB 錯誤處理，也不拿大範圍 FillNodata 硬補假地形。
- 我發現官方 CSV 另有 `不分幅_全台20MDEM(2025)`，先下載驗證後確認它比縣市分幅更適合當主島 provider 的來源。
- 我也確認苗栗中央缺口在不分幅全臺 TIF 內仍是 NoData；這不是漏下載、漏解壓或漏轉檔，而是官方 2025 來源本身有空窗。
- 我改 `-AllWithTaiwan` 的縣市 provider 產法：主島縣市從不分幅全臺來源裁 `data/work/<county>/<county>-unified-4326.tif`，離島 provider 保持縣市分幅來源。
- 我用裁出的 unified raster 產 `output/<county>`，保留縣市端點，避免縣市邊界 NoData 牆出現在畫面中間；來源真正存在的 NoData 不在主流程內插補洞。
- 我讓 `build-manifest.json` 的 `buildKind` 參與 resume 判斷；舊的 `county` provider 不會被誤當成新的 `county_unified_clip` provider 沿用。

## 2026-05-23 - 我修正澎湖與金門離島 terrain 來源

- 我確認金門與澎湖分幅資料不能用本島 `EPSG:3826` 解讀，應使用 `EPSG:3825`，否則 provider 會往東偏約 2 度，demo 飛到真實離島位置時看起來像沒有地形。
- 我也確認澎湖分幅 `.grd` 第三欄高程值落在 `466~3559`，不像公尺高程；官方不分幅澎湖 GeoTIFF 則是 `-5.1~73.36m`，比較合理。
- 我把 `config/counties.json` 的 `penghu`、`kinmen` fallback `sourceSrs` 改成 `EPSG:3825`。
- 我讓正式產線優先使用官方 `不分幅_澎湖20MDEM(2025)` 與 `不分幅_金門20MDEM(2025)` GeoTIFF，輸出 buildKind 記為 `county_offshore_unified`。
- `all_taiwan` 也改為由不分幅全臺主島加不分幅澎湖、金門共同組成，避免全臺含外島 provider 使用錯位離島 terrain。

## 2026-05-23 - 我用內政部 DEM 補苗栗官方缺格

- 我用 `check_grd.html` 比對苗栗 2025 與 2024 分幅資料，確認兩者 bbox 完全一致，缺同一塊。
- 我測試 data.gov.tw/dataset/35430 的內政部 `分幅_苗栗縣DEM.zip`，發現它比 2025/2024 多 17 個 `.grd`：`96214001~05`、`96214011~15`、`96223082~83`、`96223091~95`。
- 我讓 `all_gdr_to_wkt_array.php` 的正式 `miaoli.txt` 合併這 17 個內政部缺格，另外保留 `miaoli_moi.txt` 方便圖台比對。
- 我把 terrain 產線改成苗栗專用補源：官方 2025/不分幅全臺有效值優先，只有官方 NoData 的位置才由內政部 DEM 補洞。

## 2026-05-23 - 我修正澎湖 polygon 檢查來源

- 我用 `check_grd.html` 發現 `penghu.txt` 由 2025 分幅 `.grd` 產生時會落在實際澎湖西北側。
- 我抽查分幅 `.grd` bbox，確認即使用 `EPSG:3825` 轉出來仍在 `119.1E, 24.0N` 附近，不適合作為澎湖位置檢查來源。
- 我把 `all_gdr_to_wkt_array.php` 的正式 `penghu.txt` 改成仍輸出每塊分幅 `.grd` polygon，但用官方 `不分幅_澎湖20MDEM(2025)` GeoTIFF 的中心校正整組 bbox 位置。

## 2026-05-23 - 我確認澎湖分幅 zip 疑似錯包

- 我比對 `分幅_澎湖縣20MDEM(2025).zip` 後確認：117 個 `.grd` 檔名全部都是南投 2025 zip 的子集。
- 抽樣 `96212041dem.grd`、`96204080dem.grd`、`95201010dem.grd` 的 SHA256 與南投 zip 內同名檔完全相同。
- 這些 `.grd` 若用 `EPSG:3826` 會落在本島南投山區，高程約 `500~3500m`，比硬轉 `EPSG:3825` 更符合資料內容。
- 我移除先前把錯包分幅中心校正到澎湖的做法，正式 `data/polygons/penghu.txt` 改用官方 `不分幅_澎湖20MDEM(2025)` GeoTIFF bbox。
- 我新增 `data/polygons/penghu_grd_raw.txt` 作為診斷來源，`check_grd.html` 可點 `澎湖縣(分幅原始診斷)` 看它實際落點。

## 2026-05-23 - 我加入內政部舊版澎湖 DEM 比對

- 我確認 data.gov.tw/dataset/35430 的 CSV 有 `不分幅_全台及澎湖DEM`，也有 `分幅_澎湖縣DEM`。
- `分幅_澎湖縣DEM.zip` 來源為 TGOS Product `152e3c53-a023-40ed-91e8-99ba9653661f`，檔案約 `3474997` bytes。
- 我下載到 `data/raw/penghu_moi/penghu-dem-moi.zip`，內含 92 個 `.grd`，高程扣掉 `-999` 後約 `-0.5~122m`。
- 我新增 `data/polygons/penghu_moi.txt`，`check_grd.html` 可點 `澎湖縣(內政部DEM)` 與官方 2025 不分幅澎湖比對。

## 2026-05-23 - 我定版正式來源策略

- 正式產線以 `2025年版全臺灣20公尺網格數值地形模型DTM資料` 為主，不整套改回內政部資料。
- 疊圖策略改成 2025 不分幅全臺在上層、2025 縣市分幅在下層補不分幅缺值；內政部 `全臺灣20公尺網格數值地形模型資料` 只作為補洞與異常比對來源。
- 目前已確認要進正式產線的補洞只有苗栗：2025 分幅與 2024 分幅都缺同一塊，內政部苗栗 DEM 多 17 格可補。
- 澎湖正式 terrain 改用 2025 官方不分幅澎湖 GeoTIFF；內政部澎湖 DEM 與 2025 分幅原始落點只保留給 `check_grd.html` 診斷。
- 我比較 TGOS `Last-Modified` 後確認 2025 來源大多比內政部 35430 新，所以以 2025 為主比較符合目前多數專案使用狀態。
- 苗栗、新竹山區的不分幅空窗先記成資料釋出策略/機敏區造成的工作假設，正式流程用分幅補不分幅，避免只吃不分幅版本。

## 2026-05-23 - 我建立 DTM 版本整併庫 V1

- 我新增 `config/dtm_sources.json`，把來源策略固定為 `2025 > 2024 > OLD > GLOBAL_RESERVED`。
- 我新增 `tools/build-dtm-catalog.php`，只做資料盤點與 tile bbox coverage，不下載、不重建 terrain、不產 NoData polygon。
- Catalog 會產出 `data/catalog/dtm_inventory.sqlite`，內含 `dtm_sources`、`dtm_tiles` 與 `v_tile_best_source`、`v_missing_primary_fallback`、`v_overlap_tiles`、`v_coverage_summary`。
- Coverage JSON 會輸出到 `data/coverage/`，供 `check_grd.html` 直接讀取。
- 我把 `check_grd.html` 擴充成 Coverage 模式，可切 2025 / 2024 / OLD，並顯示 fallback-only 與 overlap tiles。
- 實資料盤點結果：26 個 source、6999 個 tile；`dtm_old_miaoli` 在 `v_missing_primary_fallback` 有 17 格，澎湖 2025 分幅診斷來源在 `v_tile_best_source` 為 0 筆。

## 2026-05-23 - 我把 annual catalog 收斂成 2025 / 2024 / 內政部三套

- 我新增 `config/dtm_source_datasets.json`，用官方 data.gov.tw 頁與 CSV API 管理 2025、2024、內政部 OLD 三套來源。
- 我新增 `tools/update-dtm-sources.php`，可由官方 CSV 重新展開 `config/dtm_sources.json`，避免年度來源手工維護漏掉基隆或其他縣市。
- 我新增 `tools/download-dtm-sources.php`，依 registry 把 zip 抓回 `data/raw/`；下載與 catalog build 分開，方便先抓資料再盤 coverage。
- 我把 `check_grd.html` 的 Coverage 模式改成頁籤：`2025`、`2024`、`內政部`，原本縣市 polygon 與 bbox 檢查保留。
- 我把 catalog 的 best-source / missing-primary fallback view 限定在 `primary` 與 `fallback`，不再把不分幅 reference layer 誤算進補缺格。

## 2026-05-23 - 我把最終 terrain provider 目標補齊

- 我確認最終目標不是只做 catalog，而是要穩定產出一套完整 terrain。
- `-AllWithTaiwan` 流程現在會產出三類 provider：21 個縣市、`output/taiwan` 全臺主島、`output/all_taiwan` 全臺含澎湖金門。
- `output/taiwan` 使用與 `all_taiwan` 主島部分相同的補洞策略：2025 不分幅全臺為主、2025 縣市分幅補不分幅缺值、內政部只補確認缺格。
- `viewer/terrain-preview.html` 新增 `terrain/taiwan`，可直接切主島或含外島版本。

## 2026-05-23 - 我補上整併後 coverage 圖層

- 我確認苗栗 best-source 已是 306 格：2025 分幅 289 格，加上內政部 `dtm_old_miaoli` 補 17 格。
- `check_grd.html` 原本的 2025 頁籤只顯示單一來源，因此仍會看到苗栗 17 格缺口；這不是 catalog 沒補，而是圖台沒有顯示整併結果。
- 我讓 catalog 產出 `data/coverage/best_source.json`，圖台新增 `整併後 best-source` 按鈕，可直接看 2025 + fallback 後的實際覆蓋。
- 我新增 `tools/build-dtm-catalog.php --coverage-only`，以後只改 coverage JSON 時不用重掃所有 GRD。

## 2026-05-23 - 我把澎湖正式 terrain 來源鎖死

- 我把 `-SkipUnifiedTaiwanSource` 的語意收窄成只略過不分幅全臺主島，不再影響澎湖、金門。
- 澎湖、金門正式 provider 一律使用 2025 不分幅離島 GeoTIFF 與 `EPSG:3825`，不允許退回 2025 分幅來源。
- 若流程中缺少不分幅離島 raster，產線會直接失敗，不會產出疑似錯位的澎湖 terrain。

## 2026-05-23 - 我完成關鍵 terrain subset 發布

- 我把 `-AllWithTaiwan -County miaoli,penghu,kinmen` 改成只重建指定縣市 provider，但 `output/taiwan` 與 `output/all_taiwan` 仍使用不分幅主島、苗栗補洞與不分幅澎湖/金門。
- 本次產出 `output/taiwan`、`output/all_taiwan`、`output/miaoli`，並驗證既有 `output/penghu`、`output/kinmen` 的 manifest。
- 澎湖正式輸出確認為 `county_offshore_unified`、`sourceSrs=EPSG:3825`、bbox=`119.313858,23.1853253,119.7285263,23.8108387`，位置正確。
- 我已把 `taiwan`、`all_taiwan`、`miaoli`、`penghu`、`kinmen` 覆蓋同步到 `Z:\data\terrain20M`，目標端 tile 數與 manifest 皆一致。

## 2026-05-16 16:47:11 - 臺中市 FAILED

- 來源：https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/ef57682a-4ec6-45a5-a265-a4dda08e6f7f/分幅_臺中市20MDEM(2025).zip
- 來源大小：38501281 bytes
- GDAL：GDAL 2.4.0, released 2018/12/14
- Docker：Docker version 29.4.3, build 055a478
- CTB image：ghcr.io/tum-gis/ctb-quantized-mesh:latest
- 輸出：output/taichung
- 結果：指令執行失敗，exit code=1：C:\ms4w_MSSQL\GDAL\gdalbuildvrt.exe

## 2026-05-16 17:35:25 - 臺中市 FAILED

- 來源：https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/ef57682a-4ec6-45a5-a265-a4dda08e6f7f/分幅_臺中市20MDEM(2025).zip
- 來源大小：38501281 bytes
- GDAL：GDAL 2.4.0, released 2018/12/14
- Docker：Docker version 29.4.3, build 055a478
- CTB image：ghcr.io/tum-gis/ctb-quantized-mesh:latest
- 輸出：output/taichung
- 結果：指令執行失敗，exit code=1：C:\Program Files\Docker\Docker\resources\bin\docker.exe

## 2026-05-16 18:19:30 - 臺中市 SUCCESS

- 來源：https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/ef57682a-4ec6-45a5-a265-a4dda08e6f7f/分幅_臺中市20MDEM(2025).zip
- 來源大小：38501281 bytes
- GDAL：GDAL 2.4.0, released 2018/12/14
- Docker：Docker version 29.4.3, build 055a478
- CTB image：ghcr.io/tum-gis/ctb-quantized-mesh:latest
- 輸出：output/taichung
- 結果：terrain 產製完成

## 2026-05-16 20:52:33 - 桃園市 FAILED

- 來源：https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/ba0fcc26-f82e-4345-bfc4-4785574d9014/分幅_桃園市20MDEM(2025).zip
- 來源大小：20272123 bytes
- GDAL：GDAL 2.4.0, released 2018/12/14
- Docker：Docker version 29.4.3, build 055a478
- CTB image：ghcr.io/tum-gis/ctb-quantized-mesh:latest
- 輸出：output/taoyuan
- 結果：找不到來源 zip，請先下載或取消 -SkipDownload：D:\mytools\dem20M_terrain\data\raw\taoyuan\taoyuan-20mdem-2025.zip

## 2026-05-16 20:54:04 - 桃園市 FAILED

- 來源：https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/ba0fcc26-f82e-4345-bfc4-4785574d9014/分幅_桃園市20MDEM(2025).zip
- 來源大小：20272123 bytes
- GDAL：GDAL 2.4.0, released 2018/12/14
- Docker：Docker version 29.4.3, build 055a478
- CTB image：ghcr.io/tum-gis/ctb-quantized-mesh:latest
- 輸出：output/taoyuan
- 結果：指令執行失敗，exit code=2：C:\ms4w_MSSQL\GDAL\gdalwarp.exe

## 2026-05-16 21:37:27 - 桃園市 SUCCESS

- 來源：https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/ba0fcc26-f82e-4345-bfc4-4785574d9014/分幅_桃園市20MDEM(2025).zip
- 來源大小：20272123 bytes
- GDAL：GDAL 2.4.0, released 2018/12/14
- Docker：Docker version 29.4.3, build 055a478
- CTB image：ghcr.io/tum-gis/ctb-quantized-mesh:latest
- 輸出：output/taoyuan
- 結果：terrain 產製完成

## 2026-05-16 22:19:43 - 新北市 SUCCESS

- 來源：https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/9574dbb5-ca32-4ea3-aaf7-a9f582b9357b/分幅_新北市20MDEM(2025).zip
- 來源大小：36525419 bytes
- GDAL：GDAL 2.4.0, released 2018/12/14
- Docker：Docker version 29.4.3, build 055a478
- CTB image：ghcr.io/tum-gis/ctb-quantized-mesh:latest
- 輸出：output/newtaipei
- 結果：terrain 產製完成

## 2026-05-16 23:04:13 - 桃園市 SUCCESS

- 來源：https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/ba0fcc26-f82e-4345-bfc4-4785574d9014/分幅_桃園市20MDEM(2025).zip
- 來源大小：20272123 bytes
- GDAL：GDAL 2.4.0, released 2018/12/14
- Docker：Docker version 29.4.3, build 055a478
- CTB image：ghcr.io/tum-gis/ctb-quantized-mesh:latest
- 輸出：output/taoyuan
- 結果：terrain 產製完成

## 2026-05-23 10:44:04 - 澎湖縣 FAILED

- 來源：https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/c1bdbb99-6290-42fb-a971-3db9fae3242c/分幅_澎湖縣20MDEM(2025).zip
- 來源大小：12858236 bytes
- GDAL：GDAL 2.4.0, released 2018/12/14
- Docker：Docker version 29.4.3, build 055a478
- CTB image：kinmen
- 輸出：output/penghu
- 結果：The provided JSON includes a property whose name is an empty string, this is only supported using the -AsHashTable switch.

## 2026-05-23 10:46:04 - 澎湖縣 SUCCESS

- 來源：https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/47910269-7315-4cd2-9101-7cdf524b47f5/不分幅_澎湖20MDEM(2025).zip
- 來源大小：1268059 bytes
- GDAL：GDAL 2.4.0, released 2018/12/14
- Docker：Docker version 29.4.3, build 055a478
- CTB image：ghcr.io/tum-gis/ctb-quantized-mesh:latest
- 輸出：output/penghu
- 結果：terrain 產製完成；使用官方不分幅離島 GeoTIFF，sourceSrs=EPSG:3825

## 2026-05-23 10:46:12 - 金門縣 SUCCESS

- 來源：https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/0e018335-80f1-4489-990c-ecf2bef1a9b6/不分幅_金門20MDEM(2025).zip
- 來源大小：1647039 bytes
- GDAL：GDAL 2.4.0, released 2018/12/14
- Docker：Docker version 29.4.3, build 055a478
- CTB image：ghcr.io/tum-gis/ctb-quantized-mesh:latest
- 輸出：output/kinmen
- 結果：terrain 產製完成；使用官方不分幅離島 GeoTIFF，sourceSrs=EPSG:3825

## 2026-05-23 11:28:44 - 全臺含外島 SUCCESS

- 來源：官方不分幅全臺主島 + 官方不分幅澎湖 + 官方不分幅金門
- 離島座標：澎湖、金門以 EPSG:3825 轉 EPSG:4326
- GDAL：GDAL 2.4.0, released 2018/12/14
- Docker：Docker version 29.4.3, build 055a478
- CTB image：ghcr.io/tum-gis/ctb-quantized-mesh:latest
- 輸出：output/all_taiwan
- 結果：terrain 產製完成；buildKind=all_taiwan_unified，bounds=118.2063723,21.8937588,122.0097055,25.3014734，tiles=144313


## 2026-05-23 17:10:02 - 全臺主島 SUCCESS

- 來源：taiwan-unified-mainland-vrt
- 來源大小：0 bytes
- GDAL：GDAL 2.4.0, released 2018/12/14
- Docker：Docker version 29.4.3, build 055a478
- CTB image：ghcr.io/tum-gis/ctb-quantized-mesh:latest
- 輸出：output/taiwan
- 結果：全臺主島 terrain 產製完成；來源模式：不分幅全臺主島 + 2025縣市分幅缺值補洞 + 內政部確認缺格補洞

## 2026-05-23 17:51:04 - 全臺含外島 SUCCESS

- 來源：taiwan-unified-mainland-plus-offshore-vrt
- 來源大小：0 bytes
- GDAL：GDAL 2.4.0, released 2018/12/14
- Docker：Docker version 29.4.3, build 055a478
- CTB image：ghcr.io/tum-gis/ctb-quantized-mesh:latest
- 輸出：output/all_taiwan
- 結果：全臺含外島 terrain 產製完成；來源模式：不分幅全臺主島 + 不分幅離島 + 2025縣市分幅缺值補洞 + 內政部確認缺格補洞

## 2026-05-23 17:51:50 - 苗栗縣 SUCCESS

- 來源：https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/a455608a-d932-48e2-b0f9-c864a8f566e2/分幅_苗栗縣20MDEM(2025).zip
- 來源大小：28448238 bytes
- GDAL：GDAL 2.4.0, released 2018/12/14
- Docker：Docker version 29.4.3, build 055a478
- CTB image：ghcr.io/tum-gis/ctb-quantized-mesh:latest
- 輸出：output/miaoli
- 結果：terrain 產製完成；不分幅全臺裁 bbox，2025 分幅補不分幅缺值，內政部 DEM 補確認缺格

## 2026-05-23 17:51:51 - 澎湖縣 SUCCESS

- 來源：https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/47910269-7315-4cd2-9101-7cdf524b47f5/不分幅_澎湖20MDEM(2025).zip
- 來源大小：1268059 bytes
- GDAL：GDAL 2.4.0, released 2018/12/14
- Docker：Docker version 29.4.3, build 055a478
- CTB image：ghcr.io/tum-gis/ctb-quantized-mesh:latest
- 輸出：output/penghu
- 結果：離島 terrain 產製完成；使用官方不分幅離島 GeoTIFF，sourceSrs=EPSG:3825

## 2026-05-23 17:51:52 - 金門縣 SUCCESS

- 來源：https://www.tgos.tw:443/MDE/VirtualDir_TC/Product/0e018335-80f1-4489-990c-ecf2bef1a9b6/不分幅_金門20MDEM(2025).zip
- 來源大小：1647039 bytes
- GDAL：GDAL 2.4.0, released 2018/12/14
- Docker：Docker version 29.4.3, build 055a478
- CTB image：ghcr.io/tum-gis/ctb-quantized-mesh:latest
- 輸出：output/kinmen
- 結果：離島 terrain 產製完成；使用官方不分幅離島 GeoTIFF，sourceSrs=EPSG:3825

## 2026-05-23 20:08:07 - 苗栗縣(內政部DEM) SUCCESS

- 來源：https://www.tgos.tw/MDE/VirtualDir_TC/Product/700a0fca-1778-4da9-a8f0-b1d164f80923/分幅_苗栗縣DEM.zip
- 來源大小：25052979 bytes
- GDAL：GDAL 2.4.0, released 2018/12/14
- Docker：Docker version 29.4.3, build 055a478
- CTB image：ghcr.io/tum-gis/ctb-quantized-mesh:latest
- 輸出：output/miaoli_moi
- 結果：terrain 產製完成；完整使用內政部 DEM 重轉，供 2025+補洞版比對

## 2026-05-23 20:34:28 - 全臺主島 SUCCESS

- 來源：taiwan-unified-mainland-vrt
- 來源大小：0 bytes
- GDAL：GDAL 2.4.0, released 2018/12/14
- Docker：Docker version 29.4.3, build 055a478
- CTB image：ghcr.io/tum-gis/ctb-quantized-mesh:latest
- 輸出：output/taiwan
- 結果：全臺主島 terrain 產製完成；來源模式：不分幅全臺主島 + 2025縣市分幅缺值補洞 + 內政部完整苗栗DEM補洞

## 2026-05-23 20:45:35 - 全臺含外島 SUCCESS

- 來源：taiwan-unified-mainland-plus-offshore-vrt
- 來源大小：0 bytes
- GDAL：GDAL 2.4.0, released 2018/12/14
- Docker：Docker version 29.4.3, build 055a478
- CTB image：ghcr.io/tum-gis/ctb-quantized-mesh:latest
- 輸出：output/all_taiwan
- 結果：全臺含外島 terrain 產製完成；來源模式：不分幅全臺主島 + 不分幅離島 + 2025縣市分幅缺值補洞 + 內政部完整苗栗DEM補洞

## 2026-05-23 20:47:39 - 全臺主島 SUCCESS

- 來源：taiwan-unified-mainland-vrt
- 來源大小：0 bytes
- GDAL：GDAL 2.4.0, released 2018/12/14
- Docker：Docker version 29.4.3, build 055a478
- CTB image：ghcr.io/tum-gis/ctb-quantized-mesh:latest
- 輸出：output/taiwan
- 結果：全臺主島 terrain 產製完成；來源模式：不分幅全臺主島 + 2025縣市分幅缺值補洞 + 內政部完整苗栗DEM補洞

## 2026-05-23 21:12:53 - 全臺含外島 SUCCESS

- 來源：taiwan-unified-mainland-plus-offshore-vrt
- 來源大小：0 bytes
- GDAL：GDAL 2.4.0, released 2018/12/14
- Docker：Docker version 29.4.3, build 055a478
- CTB image：ghcr.io/tum-gis/ctb-quantized-mesh:latest
- 輸出：output/all_taiwan
- 結果：全臺含外島 terrain 產製完成；來源模式：不分幅全臺主島 + 不分幅離島 + 2025縣市分幅缺值補洞 + 內政部完整苗栗DEM補洞

## 2026-05-23 - 我修正指定縣市模式的 all_taiwan 離島來源

- 第一次用 `-County miaoli -AllWithTaiwan -UseMoiForCounty` 重跑時，`all_taiwan` 在指定縣市模式只吃到主島與苗栗補源，沒有把澎湖、金門不分幅離島 raster 加回來，tile 數只剩 75692。
- 我修正 `Invoke-AllTaiwanBuild`，讓 `-AllWithTaiwan` 即使只指定苗栗，也會固定把 `UnifiedOffshoreSourceConfigs` 的澎湖、金門加入 `all_taiwan` VRT。
- 重新產出的 `output/all_taiwan` 為 `all_taiwan_unified_split_moi_full_gapfill`，tile 數回到 144313，bbox 為 `118.2063723,21.8937264,122.0096968,25.3014734`。

## 2026-05-24 10:04:13 - 臺灣本島(from GRD) SUCCESS

- 來源：2025-mainland-county-grd-vrt
- 來源大小：0 bytes
- GDAL：GDAL 2.4.0, released 2018/12/14
- Docker：Docker version 29.4.3, build 055a478
- CTB image：ghcr.io/tum-gis/ctb-quantized-mesh:latest
- 輸出：output/taiwan_from_grd
- 結果：臺灣本島(from GRD) terrain 產製完成；來源模式：2025縣市分幅GRD + 苗栗MOI完整DEM

## 2026-05-24 10:33:14 - 全臺含外島(from GRD) SUCCESS

- 來源：2025-county-grd-plus-offshore-vrt
- 來源大小：0 bytes
- GDAL：GDAL 2.4.0, released 2018/12/14
- Docker：Docker version 29.4.3, build 055a478
- CTB image：ghcr.io/tum-gis/ctb-quantized-mesh:latest
- 輸出：output/all_taiwan_from_grd
- 結果：全臺含外島(from GRD) terrain 產製完成；來源模式：2025縣市分幅GRD + 2025不分幅離島 + 苗栗MOI完整DEM

## 2026-05-24 - from_grd provider 發布到 3wa terrain20M

- 定義：`taiwan_from_grd` 只包含臺灣本島；`all_taiwan_from_grd` 為臺灣本島 + 外島。
- 本島來源以 2025 縣市分幅 GRD 組成，苗栗與新竹縣改用內政部 MOI 完整 DEM，避開 2025 分幅缺洞。
- 含外島版本額外加入 2025 官方不分幅澎湖、金門，避免使用位置異常的澎湖分幅 GRD 組合。
- 本機輸出已鏡射到 `Z:\data\terrain20M\taiwan_from_grd` 與 `Z:\data\terrain20M\all_taiwan_from_grd`。
- 驗證：`taiwan_from_grd` 75200 tiles；`all_taiwan_from_grd` 143966 tiles；public `layer.json` 與 `0/0/0.terrain` HEAD 均回 200。

## 2026-05-24 11:24:33 - 全臺主島 SUCCESS

- 來源：taiwan-unified-mainland-vrt
- 來源大小：0 bytes
- GDAL：GDAL 2.4.0, released 2018/12/14
- Docker：Docker version 29.4.3, build 055a478
- CTB image：ghcr.io/tum-gis/ctb-quantized-mesh:latest
- 輸出：output/taiwan
- 結果：全臺主島 terrain 產製完成；來源模式：不分幅全臺主島 + 2025縣市分幅缺值補洞 + 內政部完整DEM補洞(苗栗縣、新竹縣)

## 2026-05-24 11:52:25 - 全臺含外島 SUCCESS

- 來源：taiwan-unified-mainland-plus-offshore-vrt
- 來源大小：0 bytes
- GDAL：GDAL 2.4.0, released 2018/12/14
- Docker：Docker version 29.4.3, build 055a478
- CTB image：ghcr.io/tum-gis/ctb-quantized-mesh:latest
- 輸出：output/all_taiwan
- 結果：全臺含外島 terrain 產製完成；來源模式：不分幅全臺主島 + 不分幅離島 + 2025縣市分幅缺值補洞 + 內政部完整DEM補洞(苗栗縣、新竹縣)

## 2026-05-24 12:12:07 - 臺灣本島(from GRD) SUCCESS

- 來源：2025-mainland-county-grd-vrt
- 來源大小：0 bytes
- GDAL：GDAL 2.4.0, released 2018/12/14
- Docker：Docker version 29.4.3, build 055a478
- CTB image：ghcr.io/tum-gis/ctb-quantized-mesh:latest
- 輸出：output/taiwan_from_grd
- 結果：臺灣本島(from GRD) terrain 產製完成；來源模式：2025縣市分幅GRD + 內政部完整DEM補洞(苗栗縣、新竹縣)

## 2026-05-24 12:41:50 - 全臺含外島(from GRD) SUCCESS

- 來源：2025-county-grd-plus-offshore-vrt
- 來源大小：0 bytes
- GDAL：GDAL 2.4.0, released 2018/12/14
- Docker：Docker version 29.4.3, build 055a478
- CTB image：ghcr.io/tum-gis/ctb-quantized-mesh:latest
- 輸出：output/all_taiwan_from_grd
- 結果：全臺含外島(from GRD) terrain 產製完成；來源模式：2025縣市分幅GRD + 2025不分幅離島 + 內政部完整DEM補洞(苗栗縣、新竹縣)

## 2026-05-24 - 新竹縣 MOI 補洞納入正式 terrain

- 我在 terrain_demo 疊 `/data/city.json` 後確認，原本以為是苗栗缺洞的區塊，有一段實際落在新竹縣山區。
- 2025 新竹縣分幅有 239 個 DEM，內政部 `分幅_新竹縣DEM.zip` 有 246 個 DEM，多出的 7 格納入 `hsinchu_county_moi_full` 補源。
- 我把 `taiwan`、`all_taiwan`、`taiwan_from_grd`、`all_taiwan_from_grd` 都重跑成苗栗縣 + 新竹縣 MOI full 補洞版本，並鏡射到 `Z:\data\terrain20M` 覆蓋正式發布目錄。
- 鏡射後 tile 數：`taiwan` 75692、`all_taiwan` 144313、`taiwan_from_grd` 75200、`all_taiwan_from_grd` 143966。

## 2026-05-24 - 新竹縣單縣市 provider 改用 MOI full

- terrain_demo 若選到單一「新竹縣」，原本 `/data/terrain20M/hsinchu_county` 還是 2026-05-23 的舊版，沒有吃到 `hsinchu_county_moi_full`。
- 我重轉 `output/hsinchu_county_moi`，再鏡射覆蓋 `output/hsinchu_county` 與 `Z:\data\terrain20M\hsinchu_county`，讓正式新竹縣 URL 直接使用內政部完整 DEM 版。
- 新竹縣 MOI full terrain tile 數為 3281，bbox 為 `120.9076073,24.4224956,121.434893,24.9486503`。
- terrain_demo 的 terrain provider 加上 `terrainVersion=20260524-hsinchu-moi` query，避免瀏覽器沿用舊 `.terrain` 快取。

## 2026-05-24 - full provider 改用 NoData 透明 composite

- 新竹縣單縣市 terrain 已補好後，`taiwan` / `all_taiwan` 仍可看到洞；原因是 full VRT 原本把 2025 不分幅全臺放在最後，實際會壓過 MOI full 補源。
- 我先把 `hsinchu_county_moi_full` / `miaoli_moi_full` 移到 source list 最後，確認 `gdalbuildvrt` 後列來源優先；但又發現多個 MOI full 疊在 VRT 時，最後一個來源的 `-32768` NoData 會蓋掉前面有效值。
- 最終修法是：`-UseMoiForCounty` 建 full provider 時，先用 `gdalwarp -srcnodata -32768 -dstnodata -32768` 把來源燒成 `taiwan-moi-full-composite-4326.tif` / `all_taiwan-moi-full-composite-4326.tif`，再交給 CTB 切 terrain。
- 抽樣驗證：`121.02,24.72` 在 Hsinchu MOI 有值、Miaoli MOI 為 `-32768` 時，新的 `taiwan` / `all_taiwan` composite 仍讀到有效高程，不再被後列 NoData 蓋掉。
- 重新發布：`taiwan` 75692 tiles，`all_taiwan` 144313 tiles，並鏡射覆蓋 `Z:\data\terrain20M\taiwan`、`Z:\data\terrain20M\all_taiwan`。terrain_demo 版本號更新為 `20260524-full-moi-composite`。

## 2026-05-24 13:22:53 - 新竹縣(內政部DEM) SUCCESS

- 來源：https://www.tgos.tw/MDE/VirtualDir_TC/Product/ed20601a-24dd-48f9-a4c0-1659aaccda28/分幅_新竹縣DEM.zip
- 來源大小：20692559 bytes
- GDAL：GDAL 2.4.0, released 2018/12/14
- Docker：Docker version 29.4.3, build 055a478
- CTB image：ghcr.io/tum-gis/ctb-quantized-mesh:latest
- 輸出：output/hsinchu_county_moi
- 結果：terrain 產製完成；完整使用內政部 DEM 重轉，供 2025+補洞版比對

## 2026-05-24 13:45:53 - 全臺主島 SUCCESS

- 來源：taiwan-unified-mainland-vrt
- 來源大小：0 bytes
- GDAL：GDAL 2.4.0, released 2018/12/14
- Docker：Docker version 29.4.3, build 055a478
- CTB image：ghcr.io/tum-gis/ctb-quantized-mesh:latest
- 輸出：output/taiwan
- 結果：全臺主島 terrain 產製完成；來源模式：不分幅全臺主島 + 2025縣市分幅缺值補洞 + 內政部完整DEM補洞(苗栗縣、新竹縣)

## 2026-05-24 14:21:38 - 全臺含外島 SUCCESS

- 來源：taiwan-unified-mainland-plus-offshore-vrt
- 來源大小：0 bytes
- GDAL：GDAL 2.4.0, released 2018/12/14
- Docker：Docker version 29.4.3, build 055a478
- CTB image：ghcr.io/tum-gis/ctb-quantized-mesh:latest
- 輸出：output/all_taiwan
- 結果：全臺含外島 terrain 產製完成；來源模式：不分幅全臺主島 + 不分幅離島 + 2025縣市分幅缺值補洞 + 內政部完整DEM補洞(苗栗縣、新竹縣)

## 2026-05-24 14:41:05 - 全臺主島 SUCCESS

- 來源：taiwan-unified-mainland-vrt
- 來源大小：0 bytes
- GDAL：GDAL 2.4.0, released 2018/12/14
- Docker：Docker version 29.4.3, build 055a478
- CTB image：ghcr.io/tum-gis/ctb-quantized-mesh:latest
- 輸出：output/taiwan
- 結果：全臺主島 terrain 產製完成；來源模式：不分幅全臺主島 + 2025縣市分幅缺值補洞 + 內政部完整DEM補洞(苗栗縣、新竹縣)

## 2026-05-24 15:01:23 - 全臺含外島 SUCCESS

- 來源：taiwan-unified-mainland-plus-offshore-vrt
- 來源大小：0 bytes
- GDAL：GDAL 2.4.0, released 2018/12/14
- Docker：Docker version 29.4.3, build 055a478
- CTB image：ghcr.io/tum-gis/ctb-quantized-mesh:latest
- 輸出：output/all_taiwan
- 結果：全臺含外島 terrain 產製完成；來源模式：不分幅全臺主島 + 不分幅離島 + 2025縣市分幅缺值補洞 + 內政部完整DEM補洞(苗栗縣、新竹縣)
