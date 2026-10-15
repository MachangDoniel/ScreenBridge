#if SCREENBRIDGE_ENABLED && canImport(UIKit)
import UIKit
import ScreenBridgeProtocol

/// Marker protocol for windows owned by ScreenBridge. They are excluded from element
/// picking and from screenshots.
protocol ScreenBridgeOwnedWindow: UIWindow {}

/// A screenshot of a scene's app windows taken before any inspector UI is shown.
struct CapturedScreen {
    let image: UIImage
    let cgImage: CGImage
    let pointSize: CGSize
    let scale: CGFloat
    let orientation: String
    let capturedAt: Date

    var geometry: ScreenshotGeometry {
        ScreenshotGeometry(pixelWidth: cgImage.width, pixelHeight: cgImage.height, scale: Double(scale), interfaceOrientation: orientation)
    }
}

@MainActor
enum ScreenCapture {
    /// App windows of the scene, bottom to top, excluding ScreenBridge's own windows.
    static func appWindows(in scene: UIWindowScene) -> [UIWindow] {
        scene.windows
            .filter { !($0 is any ScreenBridgeOwnedWindow) && !$0.isHidden && $0.alpha > 0.01 }
            .sorted { $0.windowLevel.rawValue < $1.windowLevel.rawValue }
    }

    /// Normal-level app windows (excludes keyboard, alert and other system-level windows).
    /// Used to find the visible screen; capture still includes every app window.
    static func contentWindows(in scene: UIWindowScene) -> [UIWindow] {
        let windows = appWindows(in: scene)
        let normal = windows.filter { $0.windowLevel == .normal && $0.rootViewController != nil }
        return normal.isEmpty ? windows.filter { $0.rootViewController != nil } : normal
    }

    static func capture(_ scene: UIWindowScene) -> CapturedScreen? {
        let windows = appWindows(in: scene)
        guard !windows.isEmpty else { return nil }
        let bounds = scene.coordinateSpace.bounds
        let scale = scene.traitCollection.displayScale > 0 ? scene.traitCollection.displayScale : 2
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { ctx in
            UIColor.systemBackground.resolvedColor(with: scene.traitCollection).setFill()
            ctx.fill(bounds)
            for w in windows {
                w.drawHierarchy(in: w.frame, afterScreenUpdates: false)
            }
        }
        guard let cg = image.cgImage else { return nil }
        return CapturedScreen(image: image, cgImage: cg, pointSize: bounds.size, scale: scale, orientation: orientationName(scene.interfaceOrientation), capturedAt: Date())
    }

    static func orientationName(_ o: UIInterfaceOrientation) -> String {
        switch o {
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "portraitUpsideDown"
        case .landscapeLeft: return "landscapeLeft"
        case .landscapeRight: return "landscapeRight"
        default: return "unknown"
        }
    }
}

/// Everything known about a selected element or screen, resolved at selection time.
struct ResolvedSelection {
    var element: SelectedElement?
    var screen: ScreenContext?
    var elementAnchors: [SourceAnchor]
    var screenAnchors: [SourceAnchor]
    var relatedAnchors: [SourceAnchor]
    /// Frame in scene coordinates (points), for highlighting.
    var frameInScene: CGRect
    var title: String
    var subtitle: String

    var allAnchors: [SourceAnchor] {
        var seen = Set<SourceAnchor>()
        return (elementAnchors + screenAnchors + relatedAnchors).filter { seen.insert($0).inserted }
    }

    /// The first anchor with a repository-relative file — the one "Reveal source" opens.
    var primaryRevealAnchor: SourceAnchor? {
        (elementAnchors + screenAnchors + relatedAnchors).first { $0.pathStatus == .repositoryRelative && $0.path != nil }
    }
}

@MainActor
enum ElementInspector {
    static let maxHierarchyDepth = 25

    // MARK: Hit testing

    /// Deepest visible app view at a point in scene coordinates. Unlike `hitTest`, this
    /// includes non-interactive views such as labels and image views.
    static func deepestView(at scenePoint: CGPoint, in scene: UIWindowScene) -> UIView? {
        for window in ScreenCapture.appWindows(in: scene).reversed() {
            let p = window.convert(scenePoint, from: scene.coordinateSpace)
            guard window.bounds.contains(p) else { continue }
            // UIKit's hit-testing skips transparent pass-through containers (for example
            // the floating tab bar's full-screen host). Then look inside the hit view for
            // non-interactive children such as labels and images.
            if let hit = window.hitTest(p, with: nil), hit !== window {
                return deepest(in: hit, at: hit.convert(p, from: window)) ?? hit
            }
            if let v = deepest(in: window, at: p), v !== window { return v }
        }
        return nil
    }

    private static func deepest(in view: UIView, at p: CGPoint) -> UIView? {
        if view.isHidden || view.alpha < 0.01 || view is SourceMarkerView { return nil }
        let inside = view.bounds.contains(p)
        if view.clipsToBounds && !inside { return nil }
        for sub in view.subviews.reversed() {
            if let hit = deepest(in: sub, at: sub.convert(p, from: view)) { return hit }
        }
        return inside ? view : nil
    }

    /// Smallest visible SwiftUI marker containing the point.
    static func marker(at scenePoint: CGPoint, in scene: UIWindowScene) -> SourceMarkerView? {
        var best: (SourceMarkerView, CGFloat)?
        for window in ScreenCapture.appWindows(in: scene) {
            for m in SourceMarkerRegistry.shared.markers(in: window) {
                let f = frameInScene(m, scene: scene)
                guard f.contains(scenePoint), f.width > 0, f.height > 0 else { continue }
                let area = f.width * f.height
                if best == nil || area < best!.1 { best = (m, area) }
            }
        }
        return best?.0
    }

    /// Chooses what a tap selects: a SwiftUI marker when it is at least as specific as
    /// the UIKit view under the finger, otherwise the nearest meaningful UIKit view.
    static func select(at scenePoint: CGPoint, in scene: UIWindowScene) -> UIView? {
        let deepest = deepestView(at: scenePoint, in: scene)
        let uikit = deepest.map(meaningfulAncestor)
        if let m = marker(at: scenePoint, in: scene) {
            guard let v = uikit else { return m }
            let mf = frameInScene(m, scene: scene), vf = frameInScene(v, scene: scene)
            if isSwiftUIInternal(v) || mf.width * mf.height <= vf.width * vf.height + 1 { return m }
        }
        return uikit
    }

    static func frameInScene(_ view: UIView, scene: UIWindowScene) -> CGRect {
        view.convert(view.bounds, to: scene.coordinateSpace)
    }

    /// Walks up past private/internal views to something a developer recognizes.
    static func meaningfulAncestor(_ view: UIView) -> UIView {
        var v: UIView? = view
        while let cur = v {
            if isMeaningful(cur) { return cur }
            v = cur.superview
        }
        return view
    }

    static func isMeaningful(_ view: UIView) -> Bool {
        if case .valid = SourceRegistry.shared.instanceRegistration(of: view) { return true }
        if let id = view.accessibilityIdentifier, !id.isEmpty { return true }
        let name = className(view)
        if name.hasPrefix("_") || isSwiftUIInternal(view) { return false }
        if name.hasSuffix("ContentView"), view.superview is UITableViewCell || view.superview is UICollectionViewCell { return false }
        return true
    }

    static func isSwiftUIInternal(_ view: UIView) -> Bool {
        let name = String(reflecting: type(of: view))
        return name.hasPrefix("SwiftUI.") || name.contains("_UIHostingView") || name.contains("PlatformViewHost")
    }

    /// Parent element for "Select parent".
    static func parent(of view: UIView, in scene: UIWindowScene) -> UIView? {
        if let marker = view as? SourceMarkerView {
            // Next larger marker that contains this one, else the hosting UIKit view.
            let f = frameInScene(marker, scene: scene)
            let center = CGPoint(x: f.midX, y: f.midY)
            if let window = marker.window {
                let containing = SourceMarkerRegistry.shared.markers(in: window)
                    .filter { $0 !== marker }
                    .map { ($0, frameInScene($0, scene: scene)) }
                    .filter { $0.1.contains(center) && $0.1.width * $0.1.height > f.width * f.height }
                    .min { $0.1.width * $0.1.height < $1.1.width * $1.1.height }
                if let c = containing { return c.0 }
            }
            return marker.superview.map(meaningfulAncestor)?.superview.map(meaningfulAncestor)
        }
        var v = view.superview
        while let cur = v, !(cur is UIWindow) {
            if isMeaningful(cur) { return cur }
            v = cur.superview
        }
        return nil
    }

    // MARK: Resolution

    static func className(_ object: AnyObject) -> String {
        let name = String(describing: type(of: object))
        return name.count > 120 ? String(name.prefix(117)) + "…" : name
    }

    static func owningController(of view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let r = responder {
            if let vc = r as? UIViewController { return vc }
            responder = r.next
        }
        return nil
    }

    static func resolveElement(_ view: UIView, scene: UIWindowScene, capture: CapturedScreen?, projectRoot: String?) -> ResolvedSelection {
        let registry = SourceRegistry.shared
        var notes: [String] = []
        var elementAnchors: [SourceAnchor] = []
        var related: [SourceAnchor] = []

        // Element's own registration (instance, then class).
        var displayName = className(view)
        if let marker = view as? SourceMarkerView, let reg = marker.registration {
            displayName = reg.symbol
            let anchors = registry.anchors(for: reg, projectRoot: projectRoot)
            elementAnchors.append(anchors[0])
            related += anchors.dropFirst()
        } else {
            let (reg, stale) = registry.effectiveRegistration(of: view)
            if let stale { notes.append(stale) }
            if let reg {
                displayName = reg.symbol
                let anchors = registry.anchors(for: reg, projectRoot: projectRoot)
                elementAnchors.append(anchors[0])
                related += anchors.dropFirst()
            }
        }

        // Nearest registered ancestor (e.g. the cell around a tapped label, or an
        // enclosing SwiftUI marker).
        if elementAnchors.isEmpty || view is SourceMarkerView {
            if let (anchor, rel, stale) = nearestRegisteredAncestor(of: view, scene: scene, projectRoot: projectRoot) {
                if let stale { notes.append(stale) }
                elementAnchors.append(anchor)
                related += rel
            }
        }

        let vc = owningController(of: view)
        let screen = vc.map(screenContext)
        let screenAnchors = vc.map { controllerAnchors($0, projectRoot: projectRoot, related: &related) } ?? []

        let frame = frameInScene(view, scene: scene)
        let pixelFrame = SBRect(x: frame.minX * (capture?.scale ?? 1), y: frame.minY * (capture?.scale ?? 1), width: frame.width * (capture?.scale ?? 1), height: frame.height * (capture?.scale ?? 1))
        let element = SelectedElement(
            className: view is SourceMarkerView ? "SwiftUI view" : className(view),
            displayName: displayName,
            accessibilityIdentifier: (view.accessibilityIdentifier?.isEmpty ?? true) ? nil : view.accessibilityIdentifier,
            isSwiftUIMarker: view is SourceMarkerView,
            frameInScreenshot: pixelFrame,
            hierarchy: hierarchy(of: view),
            notes: notes
        )
        return ResolvedSelection(
            element: element, screen: screen,
            elementAnchors: elementAnchors, screenAnchors: screenAnchors, relatedAnchors: dedupe(related),
            frameInScene: frame, title: displayName,
            subtitle: view is SourceMarkerView ? "SwiftUI view" : className(view)
        )
    }

    static func resolveScreen(in scene: UIWindowScene, projectRoot: String?) -> ResolvedSelection? {
        guard let window = ScreenCapture.contentWindows(in: scene).last(where: { $0.isKeyWindow }) ?? ScreenCapture.contentWindows(in: scene).last,
              let root = window.rootViewController else { return nil }
        let vc = visibleController(from: root)
        var related: [SourceAnchor] = []
        let anchors = controllerAnchors(vc, projectRoot: projectRoot, related: &related)
        // SwiftUI screens: markers with role "screen" inside the visible controller.
        var markerAnchors: [SourceAnchor] = []
        if anchorsAreEmpty(anchors) {
            for m in SourceMarkerRegistry.shared.markers(in: window) where m.registration?.role == "screen" && m.isDescendant(of: vc.view) {
                if let reg = m.registration {
                    let a = SourceRegistry.shared.anchors(for: reg, projectRoot: projectRoot)
                    markerAnchors.append(a[0])
                    related += a.dropFirst()
                }
            }
        }
        let frame = vc.view.convert(vc.view.bounds, to: scene.coordinateSpace)
        let name = (anchors.first ?? markerAnchors.first)?.symbol ?? className(vc)
        return ResolvedSelection(element: nil, screen: screenContext(vc), elementAnchors: [], screenAnchors: anchors + markerAnchors, relatedAnchors: dedupe(related), frameInScene: frame, title: name, subtitle: className(vc))
    }

    private static func anchorsAreEmpty(_ a: [SourceAnchor]) -> Bool { a.isEmpty }

    private static func dedupe(_ anchors: [SourceAnchor]) -> [SourceAnchor] {
        var seen = Set<SourceAnchor>()
        return anchors.filter { seen.insert($0).inserted }
    }

    private static func controllerAnchors(_ vc: UIViewController, projectRoot: String?, related: inout [SourceAnchor]) -> [SourceAnchor] {
        let (reg, _) = SourceRegistry.shared.effectiveRegistration(of: vc)
        guard let reg else { return [] }
        let anchors = SourceRegistry.shared.anchors(for: reg, projectRoot: projectRoot, roleOverride: "screen")
        related += anchors.dropFirst()
        return [anchors[0]]
    }

    private static func nearestRegisteredAncestor(of view: UIView, scene: UIWindowScene, projectRoot: String?) -> (SourceAnchor, [SourceAnchor], String?)? {
        var v = view.superview
        var stale: String?
        while let cur = v, !(cur is UIWindow) {
            if owningController(of: cur)?.view === cur { break } // stop at the screen's root view
            let (reg, s) = SourceRegistry.shared.effectiveRegistration(of: cur)
            if let s, stale == nil { stale = s }
            if let reg {
                let anchors = SourceRegistry.shared.anchors(for: reg, projectRoot: projectRoot, note: "Registered on enclosing \(className(cur)).")
                return (anchors[0], Array(anchors.dropFirst()), stale)
            }
            v = cur.superview
        }
        // Enclosing SwiftUI marker for UIKit views hosted in SwiftUI, or nested markers.
        if let window = view.window {
            let f = frameInScene(view, scene: scene)
            let enclosing = SourceMarkerRegistry.shared.markers(in: window)
                .filter { $0 !== view }
                .map { ($0, frameInScene($0, scene: scene)) }
                .filter { $0.1.contains(f) && $0.1 != f }
                .min { $0.1.width * $0.1.height < $1.1.width * $1.1.height }
            if let (m, _) = enclosing, let reg = m.registration {
                let anchors = SourceRegistry.shared.anchors(for: reg, projectRoot: projectRoot, note: "Enclosing SwiftUI view.")
                return (anchors[0], Array(anchors.dropFirst()), stale)
            }
        }
        return nil
    }

    static func hierarchy(of view: UIView) -> [ElementNode] {
        var chain: [ElementNode] = []
        var v: UIView? = view
        while let cur = v, chain.count < maxHierarchyDepth {
            let reg: String? = {
                if let m = cur as? SourceMarkerView { return m.registration?.symbol }
                if case .valid(let r) = SourceRegistry.shared.instanceRegistration(of: cur) { return r.symbol }
                return nil
            }()
            chain.append(ElementNode(className: cur is SourceMarkerView ? "SwiftUI view" : className(cur),
                                     accessibilityIdentifier: (cur.accessibilityIdentifier?.isEmpty ?? true) ? nil : cur.accessibilityIdentifier,
                                     registeredSymbol: reg))
            v = cur.superview
        }
        return chain.reversed()
    }

    static func visibleController(from root: UIViewController) -> UIViewController {
        var vc = root
        while true {
            if let presented = vc.presentedViewController, !presented.isBeingDismissed {
                vc = presented
            } else if let nav = vc as? UINavigationController, let top = nav.visibleViewController ?? nav.topViewController {
                if top === vc { return vc }
                vc = top
            } else if let tab = vc as? UITabBarController, let sel = tab.selectedViewController {
                vc = sel
            } else {
                return vc
            }
        }
    }

    static func screenContext(_ vc: UIViewController) -> ScreenContext {
        var chain: [String] = []
        var containment: [String] = []
        var cur: UIViewController? = vc
        var presentation: String?
        while let c = cur {
            chain.append(className(c))
            if let p = c.parent {
                if !(p is UINavigationController) && !(p is UITabBarController) && !(p is UISplitViewController) && !(p is UIPageViewController) {
                    containment.append("\(className(c)) is a child of \(className(p))")
                }
                cur = p
            } else {
                if let presenter = c.presentingViewController {
                    presentation = "\(className(c)) presented by \(className(presenter)) (\(presentationStyleName(c.modalPresentationStyle)))"
                }
                cur = nil
            }
        }
        var navStack: [String]?
        var navIndex: Int?
        if let nav = vc.navigationController {
            navStack = nav.viewControllers.map(className)
            navIndex = nav.viewControllers.firstIndex { $0 === vc || vc.isDescendant(of: $0) }
        }
        let tab = vc.tabBarController
        return ScreenContext(
            owningController: className(vc),
            controllerChain: chain,
            navigationStack: navStack,
            navigationIndex: navIndex,
            tabSelectedIndex: tab?.selectedIndex,
            tabCount: tab?.viewControllers?.count,
            presentation: presentation,
            containment: containment
        )
    }

    static func presentationStyleName(_ s: UIModalPresentationStyle) -> String {
        switch s {
        case .fullScreen: return "full screen"
        case .pageSheet: return "page sheet"
        case .formSheet: return "form sheet"
        case .overFullScreen: return "over full screen"
        case .popover: return "popover"
        case .custom: return "custom"
        case .automatic: return "automatic"
        default: return "other"
        }
    }
}

extension UIViewController {
    func isDescendant(of ancestor: UIViewController) -> Bool {
        var p = parent
        while let cur = p {
            if cur === ancestor { return true }
            p = cur.parent
        }
        return false
    }
}
#endif
