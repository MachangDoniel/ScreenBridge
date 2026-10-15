#if SCREENBRIDGE_ENABLED && canImport(UIKit)
import UIKit
import SwiftUI

/// Transparent, non-interactive UIView placed behind a SwiftUI view to record its
/// frame and registration. Tracked weakly; never retained by ScreenBridge.
final class SourceMarkerView: UIView {
    var registration: SourceRegistration?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { SourceMarkerRegistry.shared.add(self) } else { SourceMarkerRegistry.shared.remove(self) }
    }
}

@MainActor
final class SourceMarkerRegistry {
    static let shared = SourceMarkerRegistry()
    private let markers = NSHashTable<SourceMarkerView>.weakObjects()

    func add(_ m: SourceMarkerView) { markers.add(m) }
    func remove(_ m: SourceMarkerView) { markers.remove(m) }

    /// Live, visible markers in `window`.
    func markers(in window: UIWindow) -> [SourceMarkerView] {
        markers.allObjects.filter { $0.window === window && !$0.isHiddenInHierarchy && $0.registration != nil }
    }
}

extension UIView {
    var isHiddenInHierarchy: Bool {
        var v: UIView? = self
        while let cur = v {
            if cur.isHidden || cur.alpha < 0.01 { return true }
            v = cur.superview
        }
        return false
    }
}

struct SourceMarker: UIViewRepresentable {
    let registration: SourceRegistration

    func makeUIView(context: Context) -> SourceMarkerView {
        let v = SourceMarkerView()
        v.registration = registration
        return v
    }

    func updateUIView(_ uiView: SourceMarkerView, context: Context) {
        uiView.registration = registration
    }
}
#endif
