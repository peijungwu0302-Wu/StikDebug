# RouteLocation v1.2.21

## 繁體中文

- 設定新增隨時可查閱的「使用指南」，涵蓋準備、單點與座標輸入、路線、收藏和連線恢復。
- 改善暫停時的非同步失敗處理，避免較晚完成的回呼覆蓋暫停狀態。
- 已儲存資料無法讀取時保留原檔並阻止意外覆寫；不同資料庫獨立載入。
- 中斷的路線仍顯示狀態與既有停止／恢復操作；開放路線的圈數選項更清楚。
- 修正配對錯誤的匯入入口、特殊字元捷徑名稱，以及部分診斷顯示細節。
- 保留既有單點切換、行動網路輔助流程與背景播放設計。

## English

- Added an on-demand User Guide in Settings for setup, single-point and coordinate input, routes, favorites, and connection recovery.
- Prevented late asynchronous failures from overwriting a paused playback state.
- Preserved unreadable saved data instead of overwriting it, and loaded libraries independently.
- Kept interrupted-route status and existing stop/restore controls visible; clarified repeat controls for open routes.
- Fixed the pairing-error import entry point, Shortcut names containing special characters, and diagnostic display details.
- Preserved existing retargeting, cellular-assisted connection, and background playback behavior.

Re-sign with SideStore, AltStore, TrollStore, or a compatible tool. Simulator and automated tests do not constitute physical-iPhone validation.
