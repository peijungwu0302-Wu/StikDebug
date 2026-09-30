import SwiftUI
import UniformTypeIdentifiers

struct RouteInputChooser: View {
    @Environment(\.dismiss) private var dismiss
    let hasExistingWaypoints: Bool
    let onSingle: () -> Void
    let onPaste: () -> Void
    let onImport: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Button(L10n.text("輸入一個航點")) { dismiss(); onSingle() }
                Button(L10n.text("貼上多個座標")) { dismiss(); onPaste() }
                Button(L10n.text("從檔案匯入")) { dismiss(); onImport() }
            }
            .navigationTitle(L10n.text("加入路線"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("取消")) { dismiss() } } }
        }
    }
}

struct RoutePasteView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var parsedCount = 0
    @State private var error: String?
    let hasExistingWaypoints: Bool
    let onReplace: ([RouteCoordinate]) -> Void
    let onAppend: ([RouteCoordinate]) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $text)
                    .font(.body.monospaced())
                    .border(.quaternary)
                    .onChange(of: text) { _, value in parsePreview(value) }
                if parsedCount > 0 { Label(L10n.format("已辨識 %d 個航點", parsedCount), systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                Spacer()
            }
            .padding()
            .navigationTitle(L10n.text("貼上路線"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("取消")) { dismiss() } }
                ToolbarItemGroup(placement: .confirmationAction) {
                    if hasExistingWaypoints { Button(L10n.text("附加到目前路線")) { apply(append: true) } }
                    Button(L10n.text(hasExistingWaypoints ? "取代目前路線並預覽" : "取代並預覽")) { apply(append: false) }
                }
            }
        }
    }

    private func parsePreview(_ value: String) {
        do { parsedCount = try CoordinateImportParser.parseInline(value).count; error = nil }
        catch let parseError { parsedCount = 0; error = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : parseError.localizedDescription }
    }

    private func apply(append: Bool) {
        do {
            let values = try CoordinateImportParser.parseInline(text)
            if append { onAppend(values) } else { onReplace(values) }
            dismiss()
        } catch let parseError { error = parseError.localizedDescription }
    }
}
