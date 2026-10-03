import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Pure validation shared by the coordinate-entry UI and its deterministic tests.
enum CoordinateAlertInputValidation {
    static func coordinate(in text: String) -> RouteCoordinate? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return try? CoordinateImportParser.parseInline(text).first
    }

    static func actionsEnabled(for text: String) -> Bool {
        coordinate(in: text) != nil
    }
}

/// Builds Apple's privacy-preserving paste control as a sibling of the field.
/// It never inspects UIPasteboard; UIKit performs the paste only after a tap.
enum CoordinateAlertPasteControl {
    @MainActor
    static func makeSibling(for textField: UITextField) -> UIPasteControl {
        textField.pasteConfiguration = UIPasteConfiguration(
            acceptableTypeIdentifiers: [UTType.plainText.identifier]
        )

        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconAndLabel
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = .systemBlue
        configuration.baseBackgroundColor = .tertiarySystemFill

        let pasteControl = UIPasteControl(configuration: configuration)
        pasteControl.target = textField
        pasteControl.accessibilityLabel = L10n.text("貼上座標")
        pasteControl.setContentHuggingPriority(.required, for: .horizontal)
        pasteControl.setContentCompressionResistancePriority(.required, for: .horizontal)
        return pasteControl
    }
}

/// Hosts a compact, alert-like coordinate modal without asking UITextField to
/// lay out the paste control inside its editable text region.
struct CoordinateAlertPresenter: UIViewControllerRepresentable {
    @EnvironmentObject private var tutorial: GuidedTutorialCoordinator
    @Binding var isPresented: Bool
    let onSubmit: (RouteCoordinate, Bool) -> Void

    func makeUIViewController(context: Context) -> CoordinateAlertHostController {
        CoordinateAlertHostController()
    }

    func updateUIViewController(_ controller: CoordinateAlertHostController, context: Context) {
        controller.isPresented = $isPresented
        controller.onSubmit = onSubmit
        controller.tutorial = tutorial
        if isPresented {
            controller.presentCoordinateModalIfNeeded()
        } else {
            controller.dismissCoordinateModalIfNeeded()
        }
    }
}

final class CoordinateAlertHostController: UIViewController {
    var isPresented: Binding<Bool>?
    var onSubmit: ((RouteCoordinate, Bool) -> Void)?
    weak var tutorial: GuidedTutorialCoordinator?
    private weak var activeModal: CoordinateEntryModalViewController?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
    }

    func presentCoordinateModalIfNeeded() {
        guard activeModal == nil, presentedViewController == nil else { return }

        let modal = CoordinateEntryModalViewController(onSubmit: { [weak self] coordinate, simulateImmediately in
            self?.finishPresentation()
            self?.onSubmit?(coordinate, simulateImmediately)
        }, onCancel: { [weak self] in
            self?.tutorial?.skip()
            self?.finishPresentation()
        })
        if tutorial?.isActive == true {
            modal.onSkipTutorial = { [weak self] in self?.tutorial?.skip() }
        }
        modal.modalPresentationStyle = .overFullScreen
        modal.modalTransitionStyle = .crossDissolve
        modal.isModalInPresentation = true
        activeModal = modal
        present(modal, animated: true) { [weak modal] in
            modal?.requestInitialFocus()
        }
    }

    func dismissCoordinateModalIfNeeded() {
        guard let activeModal else { return }
        self.activeModal = nil
        activeModal.dismiss(animated: true)
    }

    private func finishPresentation() {
        isPresented?.wrappedValue = false
        activeModal = nil
    }
}

/// A small UIKit card gives the text field and native paste control independent,
/// predictable layout while keeping the existing preview/simulate callbacks.
@MainActor
final class CoordinateEntryModalViewController: UIViewController {
    private(set) var coordinateTextField = UITextField()
    private(set) var pasteControl: UIPasteControl?
    private(set) var pasteControlContainer = UIView()
    private(set) var inputRowStack = UIStackView()
    private(set) var previewButton = UIButton(type: .system)
    private(set) var simulateButton = UIButton(type: .system)
    private(set) var cancelButton = UIButton(type: .system)
    private(set) var initialFocusWasRequested = false
    private(set) var cardCenterYConstraint: NSLayoutConstraint?

    private let cardView = UIView()
    private let cardStack = UIStackView()
    private let actionRow = UIStackView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private var pasteControlConstraints: [NSLayoutConstraint] = []
    private var hasFinished = false

    var onSubmit: (RouteCoordinate, Bool) -> Void
    var onCancel: () -> Void
    // Optional, UI-only tutorial actions. Neither action invokes simulation.
    var onSkipTutorial: (() -> Void)?
    private var tutorialControls: UIStackView?

    init(
        onSubmit: @escaping (RouteCoordinate, Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildInterface()
        configureTutorialControlsIfNeeded()
        updateActionAvailability()
        observePasteControlAvailabilityChanges()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func requestInitialFocus() {
        guard !initialFocusWasRequested else { return }
        initialFocusWasRequested = true
        coordinateTextField.becomeFirstResponder()
    }

    private func configureTutorialControlsIfNeeded() {
        guard onSkipTutorial != nil else { return }
        let demo = UIButton(type: .system)
        demo.setTitle(L10n.text("tutorial.demo.coordinate"), for: .normal)
        demo.accessibilityIdentifier = "tutorial.demo.coordinate"
        demo.addAction(UIAction { [weak self] _ in
            // Public demo text only; preview and simulation still require the
            // user's existing production buttons and normal validation.
            self?.coordinateTextField.text = "25.033964, 121.564468"
            self?.updateActionAvailability()
        }, for: .touchUpInside)
        let skip = UIButton(type: .system)
        skip.setTitle(L10n.text("tutorial.skip"), for: .normal)
        skip.accessibilityIdentifier = "tutorial.skip"
        skip.addAction(UIAction { [weak self] _ in
            self?.onSkipTutorial?()
            self?.tutorialControls?.removeFromSuperview()
            self?.tutorialControls = nil
            self?.onSkipTutorial = nil
        }, for: .touchUpInside)
        let controls = UIStackView(arrangedSubviews: [demo, skip])
        controls.axis = .horizontal
        controls.distribution = .fillEqually
        controls.backgroundColor = .secondarySystemBackground
        controls.layer.cornerRadius = 12
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            controls.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            controls.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            controls.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        tutorialControls = controls
    }

    private func buildInterface() {
        view.backgroundColor = .clear
        view.accessibilityViewIsModal = true

        let dimmingView = UIView()
        dimmingView.translatesAutoresizingMaskIntoConstraints = false
        dimmingView.backgroundColor = UIColor.black.withAlphaComponent(0.42)
        view.addSubview(dimmingView)

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.backgroundColor = .systemBackground
        cardView.layer.cornerRadius = 18
        cardView.layer.cornerCurve = .continuous
        cardView.layer.shadowColor = UIColor.black.cgColor
        cardView.layer.shadowOpacity = 0.16
        cardView.layer.shadowRadius = 22
        cardView.layer.shadowOffset = CGSize(width: 0, height: 8)
        view.addSubview(cardView)

        let preferredCardWidth = cardView.widthAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.widthAnchor,
            multiplier: 0.9
        )
        preferredCardWidth.priority = .defaultHigh
        let centerYConstraint = cardView.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor)
        centerYConstraint.priority = .defaultHigh
        cardCenterYConstraint = centerYConstraint
        NSLayoutConstraint.activate([
            dimmingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimmingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimmingView.topAnchor.constraint(equalTo: view.topAnchor),
            dimmingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            cardView.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            cardView.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            cardView.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            cardView.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            cardView.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            centerYConstraint,
            preferredCardWidth,
            cardView.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        ])

        configureHeader()
        configureInputRow()
        configureButtons()

        cardStack.axis = .vertical
        cardStack.alignment = .fill
        cardStack.distribution = .fill
        cardStack.spacing = 12
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        cardStack.isLayoutMarginsRelativeArrangement = true
        cardStack.layoutMargins = UIEdgeInsets(top: 18, left: 18, bottom: 14, right: 18)
        cardStack.addArrangedSubview(titleLabel)
        cardStack.addArrangedSubview(subtitleLabel)
        cardStack.addArrangedSubview(inputRowStack)
        cardStack.addArrangedSubview(actionRow)
        cardStack.addArrangedSubview(cancelButton)
        cardView.addSubview(cardStack)

        NSLayoutConstraint.activate([
            cardStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            cardStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            cardStack.topAnchor.constraint(equalTo: cardView.topAnchor),
            cardStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),
            inputRowStack.heightAnchor.constraint(equalToConstant: 48),
            actionRow.heightAnchor.constraint(equalToConstant: 48),
            cancelButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    private func configureHeader() {
        titleLabel.text = L10n.text("輸入位置")
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.accessibilityTraits = .header

        subtitleLabel.text = L10n.text("支援座標或 Google Maps 連結")
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 2
    }

    private func configureInputRow() {
        coordinateTextField.translatesAutoresizingMaskIntoConstraints = false
        coordinateTextField.borderStyle = .roundedRect
        coordinateTextField.backgroundColor = .secondarySystemFill
        coordinateTextField.textColor = .label
        coordinateTextField.tintColor = .systemBlue
        coordinateTextField.font = .preferredFont(forTextStyle: .body)
        coordinateTextField.adjustsFontForContentSizeCategory = true
        coordinateTextField.attributedPlaceholder = NSAttributedString(
            string: "25.033964, 121.564468",
            attributes: [.foregroundColor: UIColor.placeholderText]
        )
        coordinateTextField.keyboardType = .numbersAndPunctuation
        coordinateTextField.autocorrectionType = .no
        coordinateTextField.autocapitalizationType = .none
        coordinateTextField.spellCheckingType = .no
        coordinateTextField.clearButtonMode = .never
        coordinateTextField.accessibilityLabel = L10n.text("座標或 Google Maps 連結")
        coordinateTextField.returnKeyType = .done
        coordinateTextField.addTarget(self, action: #selector(coordinateTextDidChange(_:)), for: .editingChanged)

        pasteControlContainer.translatesAutoresizingMaskIntoConstraints = false
        inputRowStack.axis = .horizontal
        inputRowStack.alignment = .fill
        inputRowStack.distribution = .fill
        inputRowStack.spacing = 8
        inputRowStack.addArrangedSubview(coordinateTextField)
        inputRowStack.addArrangedSubview(pasteControlContainer)
        coordinateTextField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        coordinateTextField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            coordinateTextField.heightAnchor.constraint(equalToConstant: 48),
            pasteControlContainer.widthAnchor.constraint(equalToConstant: 92),
            pasteControlContainer.heightAnchor.constraint(equalToConstant: 48)
        ])
        refreshPasteControl()
    }

    /// Recreates the native control without inspecting pasteboard contents or
    /// changing the text field that UIKit targets for the user-initiated paste.
    func refreshPasteControl() {
        guard isViewLoaded else { return }

        NSLayoutConstraint.deactivate(pasteControlConstraints)
        pasteControlConstraints.removeAll()
        pasteControl?.removeFromSuperview()
        let replacement = CoordinateAlertPasteControl.makeSibling(for: coordinateTextField)
        replacement.translatesAutoresizingMaskIntoConstraints = false
        pasteControlContainer.addSubview(replacement)
        pasteControlConstraints = [
            replacement.leadingAnchor.constraint(equalTo: pasteControlContainer.leadingAnchor),
            replacement.trailingAnchor.constraint(equalTo: pasteControlContainer.trailingAnchor),
            replacement.topAnchor.constraint(equalTo: pasteControlContainer.topAnchor),
            replacement.bottomAnchor.constraint(equalTo: pasteControlContainer.bottomAnchor)
        ]
        NSLayoutConstraint.activate(pasteControlConstraints)
        pasteControl = replacement
    }

    private func observePasteControlAvailabilityChanges() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(pasteboardAvailabilityDidChange(_:)),
            name: UIPasteboard.changedNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(pasteboardAvailabilityDidChange(_:)),
            name: UIPasteboard.removedNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(pasteboardAvailabilityDidChange(_:)),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func pasteboardAvailabilityDidChange(_ notification: Notification) {
        refreshPasteControl()
    }

    private func configureButtons() {
        var previewConfiguration = UIButton.Configuration.bordered()
        previewConfiguration.title = L10n.text("地圖預覽")
        previewConfiguration.baseForegroundColor = .systemBlue
        previewButton.configuration = previewConfiguration
        previewButton.accessibilityLabel = L10n.text("地圖預覽")
        previewButton.addTarget(self, action: #selector(previewPressed), for: .touchUpInside)

        var simulateConfiguration = UIButton.Configuration.filled()
        simulateConfiguration.title = L10n.text("立即模擬")
        simulateConfiguration.baseBackgroundColor = .systemBlue
        simulateConfiguration.baseForegroundColor = .white
        simulateButton.configuration = simulateConfiguration
        simulateButton.accessibilityLabel = L10n.text("立即模擬")
        simulateButton.addTarget(self, action: #selector(simulatePressed), for: .touchUpInside)

        var cancelConfiguration = UIButton.Configuration.plain()
        cancelConfiguration.title = L10n.text("取消")
        cancelButton.configuration = cancelConfiguration
        cancelButton.accessibilityLabel = L10n.text("取消")
        cancelButton.addTarget(self, action: #selector(cancelPressed), for: .touchUpInside)

        actionRow.axis = .horizontal
        actionRow.alignment = .fill
        actionRow.distribution = .fillEqually
        actionRow.spacing = 10
        actionRow.addArrangedSubview(previewButton)
        actionRow.addArrangedSubview(simulateButton)
    }

    @objc private func coordinateTextDidChange(_ textField: UITextField) {
        updateActionAvailability()
    }

    private func updateActionAvailability() {
        let enabled = CoordinateAlertInputValidation.actionsEnabled(for: coordinateTextField.text ?? "")
        previewButton.isEnabled = enabled
        simulateButton.isEnabled = enabled
    }

    @objc private func previewPressed() {
        submit(simulateImmediately: false)
    }

    @objc private func simulatePressed() {
        submit(simulateImmediately: true)
    }

    @objc private func cancelPressed() {
        finish { [onCancel] in onCancel() }
    }

    private func submit(simulateImmediately: Bool) {
        guard let coordinate = CoordinateAlertInputValidation.coordinate(in: coordinateTextField.text ?? "") else {
            updateActionAvailability()
            return
        }
        finish { [onSubmit] in onSubmit(coordinate, simulateImmediately) }
    }

    private func finish(completion: @escaping () -> Void) {
        guard !hasFinished else { return }
        hasFinished = true
        coordinateTextField.resignFirstResponder()
        if presentingViewController != nil {
            dismiss(animated: true, completion: completion)
        } else {
            completion()
        }
    }
}
