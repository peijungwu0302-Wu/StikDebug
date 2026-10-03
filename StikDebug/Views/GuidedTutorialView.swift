import SwiftUI
import UIKit

/// UI navigation only. This object has no simulation, storage, or device service.
@MainActor
final class TutorialUIContext: ObservableObject {
    @Published var requestedFlow: TutorialFlow?
    @Published var coordinateEntryVisible = false
    @Published var editorVisible = false
    @Published var selectedFavoriteID: UUID?
    @Published var librarySection = "places"
    @Published var modalVisible = false

    func resetPresentation() {
        coordinateEntryVisible = false
        editorVisible = false
        modalVisible = false
        selectedFavoriteID = nil
    }
}

struct TutorialTargetPreference: PreferenceKey {
    static var defaultValue: [TutorialTarget: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TutorialTarget: Anchor<CGRect>], nextValue: () -> [TutorialTarget: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

extension View {
    func tutorialTarget(_ target: TutorialTarget) -> some View {
        transformAnchorPreference(key: TutorialTargetPreference.self, value: .bounds) { anchors, bounds in
            anchors[target] = bounds
        }
    }

    func tutorialSurface() -> some View { modifier(TutorialSurface()) }
}

private struct TutorialSurface: ViewModifier {
    @EnvironmentObject private var tutorial: GuidedTutorialCoordinator
    @EnvironmentObject private var context: TutorialUIContext
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(TutorialTargetPreference.self) { anchors in
            GeometryReader { proxy in
                if tutorial.isActive, !tutorial.isSuspended, !context.modalVisible, let step = tutorial.step {
                    let rect = anchors[step.target].map { proxy[$0] }
                    TutorialCoach(tutorial: tutorial, rect: rect, availableSize: proxy.size)
                }
            }
        }
    }
}

private struct TutorialCoach: View {
    @ObservedObject var tutorial: GuidedTutorialCoordinator
    let rect: CGRect?
    let availableSize: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var focusTitle: Bool

    var body: some View {
        ZStack {
            if let rect, rect.width > 0, rect.height > 0 {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: availableSize))
                    path.addRoundedRect(in: rect.insetBy(dx: -5, dy: -5), cornerSize: CGSize(width: 10, height: 10))
                }
                .fill(Color.black.opacity(0.22), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .frame(width: rect.width + 10, height: rect.height + 10)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            VStack {
                if (rect?.midY ?? availableSize.height) < availableSize.height / 2 { Spacer() }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L10n.text("tutorial.coach.title")).font(.headline)
                            .accessibilityFocused($focusTitle)
                        Spacer()
                        Button(L10n.text("tutorial.skip")) { tutorial.skip() }
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityIdentifier("tutorial.skip")
                    }
                    ScrollView {
                        Text(L10n.text(tutorial.step?.instructionKey ?? ""))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if rect == nil {
                            Text(L10n.text("tutorial.target.unavailable"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxHeight: 120)
                    Text(L10n.format("tutorial.progress", tutorial.stepIndex + 1, tutorial.steps.count))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 12).padding(.vertical, 12)
                if (rect?.midY ?? availableSize.height) >= availableSize.height / 2 { Spacer() }
            }
        }
        .onAppear { announce() }
        .onChange(of: tutorial.stepIndex) { _, _ in announce() }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: tutorial.stepIndex)
    }

    private func announce() {
        focusTitle = true
        UIAccessibility.post(notification: .announcement, argument: L10n.text(tutorial.step?.instructionKey ?? ""))
    }
}

/// Sheets keep a directly reachable exit while their native controls are in use.
struct TutorialSheetHint: View {
    @EnvironmentObject private var tutorial: GuidedTutorialCoordinator
    var body: some View {
        if tutorial.isActive {
            HStack(alignment: .top) {
                ScrollView {
                    Text(L10n.text(tutorial.step?.instructionKey ?? "")).font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxHeight: 100)
                Spacer()
                Button(L10n.text("tutorial.skip")) { tutorial.skip() }
                    .frame(minWidth: 44, minHeight: 44)
            }
            .padding(12).background(.regularMaterial)
        }
    }
}

struct TutorialCenterView: View {
    @EnvironmentObject private var context: TutorialUIContext
    var body: some View {
        List {
            Section {
                Text(L10n.text("tutorial.center.intro"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section(L10n.text("tutorial.section.quick")) {
                flow(.firstPoint); flow(.firstRoute); flow(.restore)
            }
            Section(L10n.text("tutorial.section.common")) {
                flow(.coordinates); flow(.favorite); flow(.savedRoute)
            }
            Section(L10n.text("tutorial.section.connection")) {
                flow(.interruption); flow(.cellular)
            }
        }
        .navigationTitle(L10n.text("tutorial.center.title"))
        .accessibilityIdentifier("tutorial.center")
    }

    private func flow(_ flow: TutorialFlow) -> some View {
        Button { context.requestedFlow = flow } label: {
            Label(L10n.text(flow.titleKey), systemImage: "hand.point.up.left")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        }
        .accessibilityIdentifier("tutorial.start.\(flow.rawValue)")
    }
}
