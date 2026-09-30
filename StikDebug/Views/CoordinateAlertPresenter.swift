import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
        let field = UITextField()
        field.placeholder = "25.033964,121.564468"
        field.keyboardType = .numbersAndPunctuation
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.clearButtonMode = .whileEditing
        alert.addTextField { textField in
            textField.placeholder = field.placeholder
            textField.keyboardType = field.keyboardType
            textField.autocorrectionType = field.autocorrectionType
            textField.autocapitalizationType = field.autocapitalizationType
            textField.clearButtonMode = field.clearButtonMode

            // UIPasteControl is user initiated and preserves iOS paste privacy.
            let pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.plainText.identifier])
            textField.pasteConfiguration = pasteConfiguration
            let pasteControl = UIPasteControl(configuration: UIPasteControl.Configuration())
            pasteControl.target = textField
            pasteControl.accessibilityLabel = L10n.text("貼上座標")
            pasteControl.frame = CGRect(x: 0, y: 0, width: 34, height: 34)
            textField.rightView = pasteControl
            textField.rightViewMode = .always
        }

        alert.addAction(UIAlertAction(title: L10n.text("取消"), style: .cancel) { [weak self] _ in
            self?.finishAlert()
        })
        alert.addAction(UIAlertAction(title: L10n.text("地圖預覽"), style: .default) { [weak self, weak alert] _ in
            self?.submit(from: alert, simulateImmediately: false)
        })
        alert.addAction(UIAlertAction(title: L10n.text("立即模擬"), style: .default) { [weak self, weak alert] _ in
            self?.submit(from: alert, simulateImmediately: true)
        })

        activeAlert = alert
        present(alert, animated: true) { [weak alert] in
            alert?.textFields?.first?.becomeFirstResponder()
        }
    }

    func dismissCoordinateAlertIfNeeded() {
        guard let activeAlert else { return }
        activeAlert.dismiss(animated: true)
        self.activeAlert = nil
    }

    private func submit(from alert: UIAlertController?, simulateImmediately: Bool) {
        guard let alert, let rawValue = alert.textFields?.first?.text else { return }
        do {
            guard let coordinate = try CoordinateImportParser.parseInline(rawValue).first else {
                throw CoordinateImportError.noCoordinates
            }
            finishAlert()
            onSubmit?(coordinate, simulateImmediately)
        } catch {
            alert.message = error.localizedDescription
            // UIAlertAction handlers run after the alert has remained visible;
            // leave it open so the user can correct the input.
        }
    }

    private func finishAlert() {
        isPresented?.wrappedValue = false
        activeAlert?.dismiss(animated: true)
        activeAlert = nil
    }
}
