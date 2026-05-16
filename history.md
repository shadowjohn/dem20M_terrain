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
