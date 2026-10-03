# User Guide screenshots / 使用指南截圖

These unedited PNGs were exported from real XCTest screenshot attachments, not generated or composited. 這些未編修 PNG 來自實際 XCTest 畫面附件，並非合成示意圖。

- Workflow: `.github/workflows/capture_guide.yml`
- Successful run: https://github.com/peijungwu0302-Wu/StikDebug/actions/runs/37143533391 (attempt 1)
- Capture source: `30cd778265dd84dcf5bcd506018dec54b15fbb3f`
- Artifact ID: `11281102728`
- Archive bytes: `6092249`
- Archive SHA-256: `0a15b7874ae78a435d4a26d53aa8d99ceb49bf1aea096db8d27ba926d9ad8afe`
- Device: iPhone 17 Pro simulator; Xcode 26.6 (17F113), light appearance.
- Tests: `RouteLocationGuideUITests` navigate all seven topics in English and Traditional Chinese.

The selected topic-list and setup pages are unchanged by subsequent v1.2.21 guide wording corrections. Other captured pages are intentionally not included. 選用的主題列表與初次設定頁不受後續 v1.2.21 文案修正影響；其餘截圖未納入。

To reproduce, run **Capture RouteLocation User Guide** from Actions for a source ref containing the guide, or push a matching guide/UI-test change to a feature branch. The workflow exports `xcresult` attachments and retains the source SHA, Xcode version, simulator inventory, and logs in its artifact. Reinspect images before replacing these documentation files. 可由 Actions 重新擷取，替換文件圖片前請再次檢視。

The simulator has no real pairing file or working device tunnel. These images demonstrate navigation and documentation only; they do not validate GPS simulation, cellular recovery, VPN, HealthKit signing, or background execution on a physical iPhone. 模擬器截圖只證明畫面與導覽，不代表實機定位、行動網路恢復或背景功能已驗證。
