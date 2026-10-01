import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Pure validation used by the native coordinate alert and its deterministic
/// tests.  The alert keeps its submission actions disabled until this helper
/// can produce a real coordinate, so tapping an invalid action can never
/// dismiss the native controller first.
enum CoordinateAlertInputValidation {
    static func coordinate(in text: String) -> RouteCoordinate? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return try? CoordinateImportParser.parseInline(text).first
    }
}

/// Builds a stable trailing accessory for the system paste control. Its
/// explicit frame lets UIKit display it before the alert text field is edited.
enum CoordinateAlertPasteControl {
    static let trailingContainerSize = CGSize(width: 46, height: 36)

    @MainActor
    @discardableResult
    static func install(on textField: UITextField) -> UIPasteControl {
        // UITextField treats rightView as a frame-based accessory rather than
        // an Auto Layout child. Give it a real initial size so UIKit can lay it
        // out before editing begins; constraints position only the paste UI
        // inside that fixed accessory area.
        let container = UIView(frame: CGRect(origin: .zero, size: trailingContainerSize))

        let pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.plainText.identifier])
        textField.pasteConfiguration = pasteConfiguration
        let pasteControl = UIPasteControl(configuration: UIPasteControl.Configuration())
        pasteControl.translatesAutoresizingMaskIntoConstraints = false
        pasteControl.target = textField
        pasteControl.accessibilityLabel = L10n.text("貼上座標")
        container.addSubview(pasteControl)
        NSLayoutConstraint.activate([
            pasteControl.widthAnchor.constraint(equalToConstant: 36),
            pasteControl.heightAnchor.constraint(equalToConstant: 32),
            pasteControl.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            pasteControl.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        textField.rightView = container
        textField.rightViewMode = .always
        textField.setNeedsLayout()
        textField.layoutIfNeeded()
        // UIAlertController can configure its text field before that field
        // has a non-zero frame. UITextField then lays out rightView using the
        // current zero-sized field bounds, so restore the explicit accessory
        // size afterward; the alert's next layout pass positions it normally.
        container.frame = CGRect(origin: container.frame.origin, size: trailingContainerSize)
        container.setNeedsLayout()
        container.layoutIfNeeded()
        return pasteControl
    }
}

/// Presents coordinate entry using the native alert presentation style while
/// keeping a real system UIPasteControl in the text-field row.  The control
/// never reads UIPasteboard on presentation; the user must explicitly tap it.
struct CoordinateAlertPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onSubmit: (RouteCoordinate, Bool) -> Void

    func makeUIViewController(context: Context) -> CoordinateAlertHostController {
        CoordinateAlertHostController()
    }

    func updateUIViewController(_ controller: CoordinateAlertHostController, context: Context) {
        controller.isPresented = $isPresented
        controller.onSubmit = onSubmit
        if isPresented {
            controller.presentCoordinateAlertIfNeeded()
        } else {
            controller.dismissCoordinateAlertIfNeeded()
        }
    }
}

final class CoordinateAlertHostController: UIViewController {
    var isPresented: Binding<Bool>?
    var onSubmit: ((RouteCoordinate, Bool) -> Void)?
    private weak var activeAlert: UIAlertController?
    private weak var previewAction: UIAlertAction?
    private weak var simulateAction: UIAlertAction?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
    }

    func presentCoordinateAlertIfNeeded() {
        guard activeAlert == nil, presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: L10n.text("輸入位置"),
            message: L10n.text("支援座標或 Google Maps 連結"),
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.placeholder = "25.033964,121.564468"
            textField.keyboardType = .numbersAndPunctuation
            textField.autocorrectionType = .no
            textField.autocapitalizationType = .none
            // Use one fixed right-side control area; a separate clear button
            // would compete for the same trailing position in an alert field.
            textField.clearButtonMode = .never
            CoordinateAlertPasteControl.install(on: textField)
            textField.addTarget(self, action: #selector(self.coordinateTextDidChange(_:)), for: .editingChanged)
        }

        alert.addAction(UIAlertAction(title: L10n.text("取消"), style: .cancel) { [weak self] _ in
            self?.finishAlert()
        })
        let previewAction = UIAlertAction(title: L10n.text("地圖預覽"), style: .default) { [weak self, weak alert] _ in
            self?.submit(from: alert, simulateImmediately: false)
        }
        previewAction.isEnabled = false
        let simulateAction = UIAlertAction(title: L10n.text("立即模擬"), style: .default) { [weak self, weak alert] _ in
            self?.submit(from: alert, simulateImmediately: true)
        }
        simulateAction.isEnabled = false
        alert.addAction(previewAction)
        alert.addAction(simulateAction)

        activeAlert = alert
        self.previewAction = previewAction
        self.simulateAction = simulateAction
        present(alert, animated: true) { [weak alert] in
            alert?.textFields?.first?.becomeFirstResponder()
        }
    }

    @objc private func coordinateTextDidChange(_ textField: UITextField) {
        let isValid = CoordinateAlertInputValidation.coordinate(in: textField.text ?? "") != nil
        previewAction?.isEnabled = isValid
        simulateAction?.isEnabled = isValid
    }

    func dismissCoordinateAlertIfNeeded() {
        guard let activeAlert else { return }
        activeAlert.dismiss(animated: true)
        self.activeAlert = nil
        previewAction = nil
        simulateAction = nil
    }

    private func submit(from alert: UIAlertController?, simulateImmediately: Bool) {
        guard let alert, let rawValue = alert.textFields?.first?.text else { return }
        guard let coordinate = CoordinateAlertInputValidation.coordinate(in: rawValue) else {
            // An action should be disabled for this state.  If UIKit still
            // invokes it due to a presentation race, reset the binding and
            // controller together so SwiftUI can present a fresh alert.
            resetAfterUnexpectedInvalidSubmission()
            return
        }
        finishAlert()
        onSubmit?(coordinate, simulateImmediately)
    }

    private func resetAfterUnexpectedInvalidSubmission() {
        isPresented?.wrappedValue = false
        activeAlert?.dismiss(animated: true)
        activeAlert = nil
        previewAction = nil
        simulateAction = nil
    }

    private func finishAlert() {
        isPresented?.wrappedValue = false
        activeAlert?.dismiss(animated: true)
        activeAlert = nil
        previewAction = nil
        simulateAction = nil
    }
}
