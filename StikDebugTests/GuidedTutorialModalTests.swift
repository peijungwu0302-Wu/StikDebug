import Testing
import UIKit
@testable import RouteLocation

@MainActor
struct GuidedTutorialModalTests {
    @Test func endingClassicModalGuidanceCannotLeaveNextTourHidden() {
        let context = TutorialUIContext()
        context.coordinateEntryVisible = true
        context.editorVisible = true
        context.modalVisible = true
        context.selectedFavoriteID = UUID()
        // Root invokes this when guidance ends and before a new flow begins,
        // including when temporary standard-map UI is replaced by Classic.
        context.resetPresentation()
        #expect(!context.modalVisible && !context.coordinateEntryVisible && !context.editorVisible)
        #expect(context.selectedFavoriteID == nil)
        let tutorial = GuidedTutorialCoordinator()
        var state = GuidedTutorialSnapshot()
        state.coordinateEntryVisible = context.coordinateEntryVisible
        tutorial.start(.firstPoint, snapshot: state)
        state.coordinateEntryVisible = true
        tutorial.observe(state)
        #expect(tutorial.step?.id == .selectCoordinate)
    }
    @Test func demoFillAndSkipNeverSubmitOrCancelProductionInput() throws {
        var submissions = 0
        var cancellations = 0
        let tutorial = GuidedTutorialCoordinator()
        tutorial.start(.firstPoint, snapshot: GuidedTutorialSnapshot())
        let modal = CoordinateEntryModalViewController(
            onSubmit: { _, _ in submissions += 1 },
            onCancel: { cancellations += 1 }
        )
        modal.onSkipTutorial = { tutorial.skip() }
        modal.loadViewIfNeeded()
        let field = modal.coordinateTextField
        let demo = try #require(button(in: modal.view, id: "tutorial.demo.coordinate"))
        demo.sendActions(for: .touchUpInside)
        #expect(field.text == "25.033964, 121.564468")
        #expect(modal.previewButton.isEnabled && modal.simulateButton.isEnabled)
        #expect(submissions == 0 && cancellations == 0)
        let skip = try #require(button(in: modal.view, id: "tutorial.skip"))
        skip.sendActions(for: .touchUpInside)
        #expect(!tutorial.isActive)
        #expect(modal.coordinateTextField === field)
        #expect(field.text == "25.033964, 121.564468")
        #expect(submissions == 0 && cancellations == 0)
        #expect(button(in: modal.view, id: "tutorial.skip") == nil)
        modal.previewButton.sendActions(for: .touchUpInside)
        #expect(submissions == 1 && cancellations == 0)
    }

    @Test func ordinaryCoordinateModalHasNoTutorialControls() {
        let modal = CoordinateEntryModalViewController(onSubmit: { _, _ in }, onCancel: {})
        modal.loadViewIfNeeded()
        #expect(button(in: modal.view, id: "tutorial.skip") == nil)
        #expect(button(in: modal.view, id: "tutorial.demo.coordinate") == nil)
    }

    private func button(in view: UIView, id: String) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityIdentifier == id { return button }
        return view.subviews.lazy.compactMap { button(in: $0, id: id) }.first
    }
}
