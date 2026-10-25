# RouteLocation v1.2.27

## 繁體中文

- 設定新增完整版與 v1.2.21 風格精簡地圖版面，共用既有選點、航點、智慧貼上、收藏與安全停止流程。切換版面保留草稿及模擬狀態。
- 新增道路約束智慧路線 MVP，可由選定地點或空白路線卡進入，預設 5 公里、建議 8 個主要航點、18.6 km/h 與無限循環。
- 使用有限次 Apple 地圖導航驗證候選，顯示實際距離、目標差異和主要航點數，保留完整道路幾何。找不到環狀路線時，可明確選擇另試經驗證的折返路線。
- 候選可預覽、儲存及收藏；只有明確套用才會進入路線草稿，保留草稿衝突確認，不自動開始定位模擬。修改航點後須重新計算導航。
- 地圖服務、道路與步道資料有涵蓋限制；不保證任何地區或山區皆可生成。服務失敗不會改成未經驗證的直線，也不影響既有定位模擬。

## English

- Choose the Full map or a Compact layout inspired by v1.2.21. Both share existing selection, waypoints, smart paste, favorites and safe stop actions. Switching layouts preserves drafts and simulation state.
- Added a road-constrained Smart Route MVP, available from a selected place or empty route card. Defaults are 5 km, 8 preferred control points, 18.6 km/h and infinite repetition.
- A bounded set of Apple Maps directions verifies candidates, with actual distance, target deviation and control-point count shown. Full road geometry is retained. A verified out-and-back alternative requires an explicit choice.
- Preview, save and favorite candidates independently. Only explicit application replaces the guarded draft; generation never starts simulation. Waypoint edits require navigation recalculation.
- Availability depends on map and road/trail coverage; arbitrary regions and mountains are not guaranteed. Service failures never fall back to unverified straight lines or interrupt existing location simulation.

Re-sign with SideStore, AltStore, TrollStore, or a compatible tool.
