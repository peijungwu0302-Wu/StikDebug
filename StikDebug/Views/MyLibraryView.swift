import SwiftUI

struct MyLibraryView: View {
    @Binding var selectedTab: RouteLocationTab
    @State private var selectedSection: MyLibrarySection = .places
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker(L10n.text("資料庫"), selection: $selectedSection) {
                    ForEach(MyLibrarySection.allCases) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                
                if selectedSection == .places {
                    MyPlacesView(selectedTab: $selectedTab)
                } else {
                    MyRoutesView(selectedTab: $selectedTab)
                }
            }
            .navigationTitle(L10n.text("我的"))
            .onReceive(NotificationCenter.default.publisher(for: .switchToRoutesTab)) { _ in
                selectedSection = .routes
            }
        }
    }
}

private enum MyLibrarySection: String, CaseIterable, Identifiable {
    case places, routes
    var id: String { rawValue }
    var title: String { L10n.text(self == .places ? "地點" : "路線") }
}
