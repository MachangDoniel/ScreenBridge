#if SCREENBRIDGE_ENABLED && canImport(UIKit)
import UIKit
import SwiftUI
import Combine
import ScreenBridgeProtocol

/// Window above the app that only claims touches on ScreenBridge's own controls.
final class ScreenBridgeWindow: UIWindow, ScreenBridgeOwnedWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        // The transparent root view passes touches through to the app below.
        if hit === rootViewController?.view { return nil }
        return hit
    }
}

/// One per window scene. Owns the overlay window and drives the inspector flows.
@MainActor
final class OverlayWindowController {
    private weak var scene: UIWindowScene?
    private let window: ScreenBridgeWindow
    private let root: OverlayRootViewController

    init(scene: UIWindowScene, connection: ConnectionManager) {
        self.scene = scene
        window = ScreenBridgeWindow(windowScene: scene)
        root = OverlayRootViewController(scene: scene, connection: connection)
        window.rootViewController = root
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue - 10)
        window.backgroundColor = .clear
        window.accessibilityViewIsModal = false
        // Visible without becoming key so the app keeps keyboard focus.
        window.isHidden = false
    }

    func tearDown() {
        root.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
    }
}

private struct ButtonPosition: Codable {
    var onLeft: Bool
    /// 0 = top of the allowed area, 1 = bottom.
    var verticalFraction: CGFloat

    static let key = "ScreenBridge.floatingButtonPosition"
    static let `default` = ButtonPosition(onLeft: false, verticalFraction: 0.72)

    static func load() -> ButtonPosition {
        guard let data = UserDefaults.standard.data(forKey: key), let p = try? JSONDecoder().decode(ButtonPosition.self, from: data) else { return .default }
        return p
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

@MainActor
final class OverlayRootViewController: UIViewController, UIAdaptivePresentationControllerDelegate {
    private weak var scene: UIWindowScene?
    let connection: ConnectionManager
    private let button = FloatingButton()
    private var position = ButtonPosition.load()
    private var keyboardTop: CGFloat?
    private var dragStart: CGPoint = .zero
    private var pickerView: PickerOverlayView?
    private let highlight = HighlightView()
    private weak var previousKeyWindow: UIWindow?
    private var statusCancellable: AnyCancellable?
    private var workspaceModel: InspectorModel?
    private var workspaceHost: UIHostingController<DebugWorkspaceView>?

    init(scene: UIWindowScene, connection: ConnectionManager) {
        self.scene = scene
        self.connection = connection
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        highlight.isHidden = true
        view.addSubview(highlight)
        view.addSubview(button)
        button.addTarget(self, action: #selector(buttonTapped), for: .touchUpInside)
        button.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))
        button.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Move to other side") { [weak self] _ in
                self?.position.onLeft.toggle()
                self?.position.save()
                self?.layoutButton(animated: true)
                return true
            },
        ]
        statusCancellable = connection.$status.sink { [weak self] status in
            self?.button.update(status: status)
        }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        nc.addObserver(self, selector: #selector(keyboardHidden(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if pickerView == nil { layoutButton(animated: false) }
        pickerView?.frame = view.bounds
        workspaceHost?.view.frame = view.bounds
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in self.layoutButton(animated: false) })
        closeWorkspace()
    }

    // Defer status bar appearance and orientations to the app's visible controller.
    // Only normal-level windows are consulted (never the keyboard's window, whose
    // controller can query back into the window stack), with a re-entrancy guard.
    private var resolvingAppController = false
    private var appVisibleController: UIViewController? {
        guard !resolvingAppController, let scene else { return nil }
        resolvingAppController = true
        defer { resolvingAppController = false }
        guard let r = ScreenCapture.contentWindows(in: scene).last?.rootViewController else { return nil }
        return ElementInspector.visibleController(from: r)
    }
    override var preferredStatusBarStyle: UIStatusBarStyle { appVisibleController?.preferredStatusBarStyle ?? .default }
    override var prefersStatusBarHidden: Bool { appVisibleController?.prefersStatusBarHidden ?? false }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        appVisibleController?.supportedInterfaceOrientations ?? .all
    }

    // MARK: Floating button layout

    private var allowedRect: CGRect {
        var r = view.bounds.inset(by: view.safeAreaInsets).insetBy(dx: 10, dy: 10)
        if let kt = keyboardTop { r.size.height = max(FloatingButton.size, min(r.height, kt - r.minY - 10)) }
        return r
    }

    private func layoutButton(animated: Bool) {
        let s = FloatingButton.size
        let r = allowedRect
        let x = position.onLeft ? r.minX : r.maxX - s
        let y = r.minY + max(0, min(1, position.verticalFraction)) * max(0, r.height - s)
        let frame = CGRect(x: x, y: y, width: s, height: s)
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.4) { self.button.frame = frame }
        } else {
            button.frame = frame
        }
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            dragStart = button.center
        case .changed:
            let t = g.translation(in: view)
            button.center = CGPoint(x: dragStart.x + t.x, y: dragStart.y + t.y)
        case .ended, .cancelled:
            let r = allowedRect
            position.onLeft = button.center.x < view.bounds.midX
            let usable = max(1, r.height - FloatingButton.size)
            position.verticalFraction = max(0, min(1, (button.frame.minY - r.minY) / usable))
            position.save()
            layoutButton(animated: true)
        default: break
        }
    }

    @objc private func keyboardChanged(_ n: Notification) {
        guard let end = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue, let screen = view.window?.screen else { return }
        let local = view.convert(end, from: screen.coordinateSpace)
        keyboardTop = local.minY < view.bounds.maxY ? local.minY : nil
        layoutButton(animated: true)
    }

    @objc private func keyboardHidden(_ n: Notification) {
        keyboardTop = nil
        layoutButton(animated: true)
    }

    // MARK: Flows

    @objc private func buttonTapped() {
        guard presentedViewController == nil, workspaceHost == nil, let scene else { return }
        let capture = ScreenCapture.capture(scene)
        let screen = ElementInspector.resolveScreen(in: scene, projectRoot: ScreenBridgeRuntime.shared.projectRoot)
        let model = InspectorModel(connection: connection, capture: capture, screen: screen)
        workspaceModel = model
        model.onExit = { [weak self] in self?.closeWorkspace() }
        model.onSelectPoint = { [weak self, weak model] point in
            guard let self, let model, let capture = model.capture else { return }
            let scenePoint = CGPoint(x: point.x / Double(capture.scale), y: point.y / Double(capture.scale))
            guard let element = ElementInspector.select(at: scenePoint, in: scene) else { return }
            self.select(element, model: model, scene: scene)
        }
        model.onSelectParent = { [weak self, weak model] in
            guard let self, let model, let current = model.selectedView,
                  let parent = ElementInspector.parent(of: current, in: scene) else { return }
            self.select(parent, model: model, scene: scene)
        }
        model.canSelectParent = { [weak model] in
            guard let current = model?.selectedView else { return false }
            return ElementInspector.parent(of: current, in: scene) != nil
        }
        model.onInspectElement = { [weak self, weak model] in
            model?.workspaceMode = .inspect
            self?.closeAll()
        }
        let workspace = DebugWorkspaceView(model: model, onMore: { [weak self, weak model] in
            guard let self, let model else { return }
            model.path = []
            self.presentSheet(InspectorHomeView(model: model), model: model, detents: [.medium(), .large()])
        }, onSend: { [weak self, weak model] destination in
            guard let self, let model else { return }
            model.destination = destination
            model.path = []
            model.beginReport(annotateSelection: false)
            self.presentSheet(InspectorHomeView(model: model), model: model, detents: [.large()])
        })
        let host = UIHostingController(rootView: workspace)
        host.view.backgroundColor = .clear
        host.view.accessibilityViewIsModal = true
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        workspaceHost = host
        button.isHidden = true
        ScreenBridge.log("Opened debug tools for \(screen?.title ?? "screen")", category: "inspector")
    }

    private func select(_ element: UIView, model: InspectorModel, scene: UIWindowScene) {
        let resolved = ElementInspector.resolveElement(element, scene: scene, capture: model.capture,
                                                       projectRoot: ScreenBridgeRuntime.shared.projectRoot)
        model.select(resolved, view: element)
    }

    private func closeWorkspace() {
        if presentedViewController != nil { dismiss(animated: false) }
        workspaceHost?.willMove(toParent: nil)
        workspaceHost?.view.removeFromSuperview()
        workspaceHost?.removeFromParent()
        workspaceHost = nil
        workspaceModel = nil
        restoreAfterSheet()
    }

    private func presentSheet<V: View>(_ rootView: V, model: InspectorModel, detents: [UISheetPresentationController.Detent]) {
        let host = UIHostingController(rootView: rootView)
        host.modalPresentationStyle = .pageSheet
        if let sheet = host.sheetPresentationController {
            sheet.detents = detents
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        }
        host.presentationController?.delegate = self
        model.onClose = { [weak self] in self?.closeAll() }
        if let w = view.window, !w.isKeyWindow {
            previousKeyWindow = scene?.windows.first { $0.isKeyWindow }
            w.makeKey()
        }
        button.isHidden = true
        workspaceHost?.view.accessibilityElementsHidden = true
        present(host, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        restoreAfterSheet()
    }

    private func closeAll() {
        dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { [weak self] in self?.restoreAfterSheet() }
    }

    private func restoreAfterSheet() {
        workspaceHost?.view.accessibilityElementsHidden = false
        clearHighlight()
        button.isHidden = workspaceHost != nil
        previousKeyWindow?.makeKey()
        previousKeyWindow = nil
    }

    private func showHighlight(_ frameInScene: CGRect) {
        guard let scene else { return }
        highlight.frame = view.convert(frameInScene, from: scene.coordinateSpace).insetBy(dx: -2, dy: -2)
        highlight.isHidden = false
        view.bringSubviewToFront(highlight)
    }

    private func clearHighlight() {
        highlight.isHidden = true
    }
}

// MARK: - Views

final class FloatingButton: UIControl {
    static let size: CGFloat = 52

    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    private let icon = UIImageView(image: UIImage(systemName: "viewfinder", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)))
    private let dot = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 3)
        blur.isUserInteractionEnabled = false
        blur.layer.cornerRadius = 16
        blur.layer.cornerCurve = .continuous
        blur.clipsToBounds = true
        addSubview(blur)
        icon.tintColor = .systemBlue
        icon.contentMode = .center
        addSubview(icon)
        dot.layer.cornerRadius = 5
        dot.layer.borderWidth = 2
        dot.layer.borderColor = UIColor.systemBackground.cgColor
        addSubview(dot)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "ScreenBridge inspector"
        accessibilityHint = "Opens floating debug tools. Drag to move."
        accessibilityIdentifier = "screenbridge.icon"
        largeContentTitle = "ScreenBridge"
        largeContentImage = UIImage(systemName: "viewfinder")
        showsLargeContentViewer = true
        addInteraction(UILargeContentViewerInteraction())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        blur.frame = bounds
        icon.frame = bounds
        dot.frame = CGRect(x: bounds.maxX - 14, y: 4, width: 10, height: 10)
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 16).cgPath
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        dot.layer.borderColor = UIColor.systemBackground.resolvedColor(with: traitCollection).cgColor
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.7 : 1 }
    }

    func update(status: ConnectionManager.Status) {
        switch status {
        case .connected: dot.backgroundColor = .systemGreen
        case .searching, .connecting: dot.backgroundColor = .systemOrange
        case .notConfigured: dot.backgroundColor = .systemGray
        case .unavailable, .authenticationFailed, .permissionDenied: dot.backgroundColor = .systemRed
        }
        accessibilityValue = status.shortText
    }
}

final class HighlightView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.borderColor = UIColor.systemBlue.cgColor
        layer.borderWidth = 2
        layer.cornerRadius = 6
        backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Full-screen tap catcher used only while the user is choosing an element.
final class PickerOverlayView: UIView {
    var onTap: ((CGPoint) -> Void)?
    var onCancel: (() -> Void)?
    let banner = UIView()
    private let label = UILabel()
    private let cancel = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.systemBlue.withAlphaComponent(0.04)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.layer.cornerRadius = 14
        blur.layer.cornerCurve = .continuous
        blur.clipsToBounds = true
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(blur)
        addSubview(banner)

        let icon = UIImageView(image: UIImage(systemName: "hand.tap"))
        icon.tintColor = .systemBlue
        icon.setContentHuggingPriority(.required, for: .horizontal)
        label.text = "Tap an element to find its source."
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        var config = UIButton.Configuration.plain()
        config.title = "Cancel"
        cancel.configuration = config
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        cancel.setContentHuggingPriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [icon, label, cancel])
        stack.spacing = 10
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(stack)
        banner.isAccessibilityElement = false
        label.accessibilityTraits = .header

        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
            banner.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 16),
            banner.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
            blur.topAnchor.constraint(equalTo: banner.topAnchor),
            blur.bottomAnchor.constraint(equalTo: banner.bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: banner.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: banner.trailingAnchor),
            stack.topAnchor.constraint(equalTo: banner.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -8),
            cancel.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        accessibilityViewIsModal = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        if banner.frame.contains(p) { return }
        onTap?(p)
    }

    @objc private func cancelTapped() { onCancel?() }

    func flash(message: String) {
        label.text = message
        UIAccessibility.post(notification: .announcement, argument: message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.label.text = "Tap an element to find its source."
        }
    }

    // VoiceOver users can't "tap an element" on a pass-through layer; expose a hint.
    override func accessibilityPerformEscape() -> Bool {
        onCancel?()
        return true
    }
}
#endif
