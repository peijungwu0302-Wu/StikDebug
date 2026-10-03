# RouteLocation v1.2.22

## 繁體中文

- 新增可主動開啟的互動教學中心，涵蓋單點、路線、恢復真實位置、座標、收藏、儲存路線與連線說明。
- 教學指向實際控制項，依真正操作結果前進；結束教學不會自動模擬、恢復位置或回滾已完成的操作。
- 暫時無法讀取資料時維持寫入保護；重新可讀後只重試失敗的資料庫。
- 收藏變更必須成功儲存才更新畫面，並補強暫停與恢復播放的非同步回歸測試。
- 補充雙語教學與 Simulator UI 示範；模擬器畫面不代表實體 iPhone 定位驗證。

## English

- Added an opt-in interactive Tutorial Center for single points, routes, restoring real location, coordinates, favorites, saved routes, and connection guidance.
- Guidance highlights real controls and advances from actual results. Ending a tutorial never simulates, restores location, or rolls back completed actions.
- Temporary library read failures remain write-protected; only failed libraries are retried when data becomes available.
- Favorite changes appear only after successful persistence, with additional deterministic pause/resume race coverage.
- Expanded bilingual guidance and Simulator UI demonstrations, clearly distinguished from physical-iPhone location validation.

Re-sign with SideStore, AltStore, TrollStore, or a compatible tool.
