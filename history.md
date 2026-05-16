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
