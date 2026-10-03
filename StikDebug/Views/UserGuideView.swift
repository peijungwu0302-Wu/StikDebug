import SwiftUI

/// Read-only help content. Opening a topic never changes location or playback.
struct UserGuideTopic: Identifiable {
    let id: String
    let symbol: String
    let title: String
    let summary: String
    let steps: [String]
    let note: String

    static let all: [UserGuideTopic] = [
        .init(id: "setup", symbol: "checklist", title: "第一次使用", summary: "準備好 iPhone 與本機連線", steps: [
            "在 iPhone「設定」中確認已開啟 Developer Mode；App 無法代你開啟。",
            "在「設定 → 配對檔案」匯入屬於這台 iPhone 的有效配對檔案。",
            "安裝並啟用 LocalDevVPN，回到 RouteLocation，依提示允許所需權限。Wi-Fi 或行動數據皆可。",
            "開啟「設定 → RouteLocation 使用準備」查看可確認的狀態，再回地圖選擇位置。"
        ], note: "配對檔案是敏感的信任憑證，請勿分享或上傳。DDI 是選用元件，未掛載不會阻止一般定位功能。"),
        .init(id: "singlePoint", symbol: "mappin.and.ellipse", title: "單點定位", summary: "選擇、移動與恢復真實位置", steps: [
            "在地圖點選位置，或使用搜尋、收藏與精確座標選取目標。",
            "確認位置後按「在此模擬」。裝置通道需要準備時，請依畫面提示完成。",
            "要移到另一點，直接選擇新位置並再次模擬；不必先恢復真實位置。",
            "按「恢復真實位置」以停止模擬並清除開發者位置覆寫，並確認成功訊息；若顯示錯誤，請依提示重試。"
        ], note: "切換單點與路線時，App 會依你的設定顯示確認。結束路線與恢復真實位置不同，請依目的選擇。"),
        .init(id: "coordinates", symbol: "location.viewfinder", title: "輸入與貼上座標", summary: "先預覽，再決定是否模擬", steps: [
            "按地圖上的「輸入座標」，輸入緯度、經度，例如 25.0330, 121.5654。",
            "複製純文字座標或含座標的 Google Maps 連結，再按輸入框旁的系統貼上按鈕。",
            "有效座標才會啟用動作。按「地圖預覽」確認目標；此動作不會開始定位模擬。",
            "確認無誤後可按「立即模擬」，或取消返回地圖。"
        ], note: "貼上按鈕由 iOS 管理；若無可貼上的文字，請先複製座標。無法解析的連結可改貼緯度、經度純文字。"),
        .init(id: "routes", symbol: "point.topleft.down.to.point.bottomright.curvepath", title: "建立與播放路線", summary: "航點、速度、圈數與播放控制", steps: [
            "依序加入航點，選擇直線或導航路線。直線在本機產生；新導航路線由 Apple Maps 計算。",
            "設定 km/h 速度。開放路線只播放一次；需要有限多圈或無限循環時，請開啟「封閉路線」。",
            "預覽路線，可先儲存，再開始播放。播放中可調整速度、暫停與繼續；暫停不會解除路線編輯鎖定。",
            "要修改航點或路線設定，先結束目前路線。正常播放完成後會停留在最後模擬位置。"
        ], note: "速度由你設定，與 Apple Maps 預估時間無關。完整導航幾何會隨路線儲存；已儲存路線可離線播放。要回到真實 GPS，請按「恢復真實位置」。"),
        .init(id: "library", symbol: "tray.full", title: "收藏與我的路線", summary: "整理常用地點與已儲存路線", steps: [
            "在地圖選取位置後加入收藏，取一個容易辨識的名稱。",
            "到「我的」查看收藏地點、最近位置與已儲存路線。",
            "使用排序或手動順序整理收藏；地圖快速收藏清單會使用相同順序。",
            "開啟已儲存路線可預覽並播放。編輯路線前，請先結束目前執行中的路線。"
        ], note: "地點與路線儲存在裝置本機，沒有帳號、雲端同步或路線上傳。刪除資料前請確認不再需要。"),
        .init(id: "recovery", symbol: "arrow.triangle.2.circlepath", title: "背景播放與連線恢復", summary: "了解暫停、重連與 iOS 限制", steps: [
            "開始播放後可以切換分頁或將 App 移到背景；背景執行仍受 iOS 管理，無法保證持續運作。",
            "保持 LocalDevVPN 可用。強制結束 App、重新啟動 iPhone 或系統終止程序可能中斷播放。",
            "連線中斷時依提示重新建立連線；App 會保留已播放進度，不會從第一個航點重新開始。",
            "行動網路輔助恢復可能暫時關閉行動數據。背景中需要處理時，請回到 App 確認與繼續。"
        ], note: "恢復嘗試有次數限制。若仍無法連線，請確認配對檔案、LocalDevVPN 與裝置解鎖狀態。App 無法控制其他 App 的 VPN。"),
        .init(id: "health", symbol: "heart", title: "選用健康同步", summary: "路線步數與授權限制", steps: [
            "到「設定 → 健康同步」選擇是否在路線播放時同步步數。",
            "依偏好選擇固定步頻或以步長計算，並允許所需的 Apple Health 寫入權限。",
            "步數只依實際路線播放新增的時間或距離批次寫入；單點傳送不會增加步數。"
        ], note: "部分簽名方式沒有可用的 HealthKit 權限，因此步數同步可能無法使用。這不影響單點或路線定位模擬。")
    ]
}

struct UserGuideView: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("熟悉 RouteLocation")).font(.title2.bold())
                    Text(L10n.text("依照你想做的事選擇主題，隨時回來查看。"))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
            Section(L10n.text("探索功能")) {
                ForEach(UserGuideTopic.all) { topic in
                    NavigationLink {
                        UserGuideDetailView(topic: topic)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.text(topic.title)).font(.headline)
                                Text(L10n.text(topic.summary))
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 5)
                        } icon: {
                            Image(systemName: topic.symbol).foregroundStyle(.tint)
                        }
                    }
                    .accessibilityIdentifier("guide.topic.\(topic.id)")
                }
            }
        }
        .navigationTitle(L10n.text("使用指南"))
        .navigationBarTitleDisplayMode(.large)
    }
}

private struct UserGuideDetailView: View {
    let topic: UserGuideTopic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: topic.symbol)
                    .font(.system(size: 38)).foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(L10n.text(topic.summary)).font(.title2.bold())
                ForEach(Array(topic.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 14) {
                        Text("\(index + 1)")
                            .font(.headline).foregroundStyle(.tint)
                            .frame(minWidth: 28, minHeight: 28)
                            .background(Color.accentColor.opacity(0.12), in: Circle())
                        Text(L10n.text(step)).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
                Text(L10n.text(topic.note))
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(L10n.text(topic.title))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("guide.detail.\(topic.id)")
    }
}
