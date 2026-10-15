import Foundation
#if canImport(UIKit)
import UIKit
import SwiftUI
#endif

// Public API. Every entry point exists in all configurations so call sites compile
// unchanged, but outside debug builds (SCREENBRIDGE_ENABLED) the bodies are empty and
// none of the inspector, capture, credential or networking code is compiled.

/// A link from a registration to another type or file (view model, service, …).
public struct SourceReference: Sendable, Hashable {
    enum Target: Sendable, Hashable {
        case type(ObjectIdentifier, name: String)
        case file(path: String, line: Int?)
    }

    let target: Target
    public let symbol: String
    public let role: String

    /// A related type. Its file is known only if the type registered itself with
    /// `ScreenBridge.register(_:)`; otherwise the Mac may suggest unverified candidates.
    public static func type(_ type: Any.Type, role: String = "related") -> SourceReference {
        let name = String(describing: type)
        return SourceReference(target: .type(ObjectIdentifier(type), name: name), symbol: name, role: role)
    }

    /// A related file. Pass `#filePath` or a repository-relative path.
    public static func file(_ path: String, line: Int? = nil, symbol: String? = nil, role: String = "related") -> SourceReference {
        SourceReference(target: .file(path: path, line: line), symbol: symbol ?? (path as NSString).lastPathComponent, role: role)
    }
}

public enum ScreenBridge {
    public enum LogLevel: String, Sendable {
        case debug, info, notice, warning, error
    }

    public struct Options: Sendable {
        /// Show the floating inspector button in each foreground window scene.
        public var showsFloatingButton: Bool
        /// Maximum number of reports kept on device while the Mac is unreachable.
        public var outboxCapacity: Int
        /// Override the bundled connection configuration (tests and custom setups).
        public var connectionConfigurationURL: URL?

        public init(showsFloatingButton: Bool = true, outboxCapacity: Int = 20, connectionConfigurationURL: URL? = nil) {
            self.showsFloatingButton = showsFloatingButton
            self.outboxCapacity = outboxCapacity
            self.connectionConfigurationURL = connectionConfigurationURL
        }
    }

    /// True when the inspector is compiled into this build (debug builds only).
    public static var isAvailable: Bool {
        #if SCREENBRIDGE_ENABLED && canImport(UIKit)
        return true
        #else
        return false
        #endif
    }

    /// Starts ScreenBridge. Safe to call more than once and before any scene connects:
    /// a floating button is attached to every foreground `UIWindowScene` as it appears.
    ///
    /// Call from `application(_:didFinishLaunchingWithOptions:)`, your SwiftUI `App.init`,
    /// or `scene(_:willConnectTo:options:)`.
    @MainActor
    public static func start(_ options: Options = Options()) {
        #if SCREENBRIDGE_ENABLED && canImport(UIKit)
        ScreenBridgeRuntime.shared.start(options)
        #endif
    }

    /// Stops ScreenBridge and removes its windows.
    @MainActor
    public static func stop() {
        #if SCREENBRIDGE_ENABLED && canImport(UIKit)
        ScreenBridgeRuntime.shared.stop()
        #endif
    }

    /// Records a message in a bounded, sanitized in-memory log that the user may choose
    /// to attach to a report. ScreenBridge does not read the system console.
    public static func log(_ message: @autoclosure () -> String, level: LogLevel = .info, category: String = "app") {
        #if SCREENBRIDGE_ENABLED
        LogStore.shared.append(level: level.rawValue, category: category, message: message())
        #endif
    }

    /// Registers a type's source location. Call it from the type's own file — for example
    /// in `init` or `viewDidLoad` — so `#filePath` and `#line` point at that file.
    #if SCREENBRIDGE_ENABLED
    public static func register(_ type: Any.Type, role: String = "screen", related: [SourceReference] = [], file: String = #filePath, line: Int = #line) {
        SourceRegistry.shared.register(type: type, registration: SourceRegistration(symbol: String(describing: type), role: role, file: file, line: line, related: related))
    }
    #else
    // Inlinable no-op so release callers drop the `#filePath` literal entirely.
    @inlinable @inline(__always)
    public static func register(_ type: Any.Type, role: String = "screen", related: [SourceReference] = [], file: String = #filePath, line: Int = #line) {}
    #endif
}

#if canImport(UIKit)
#if SCREENBRIDGE_ENABLED
extension UIViewController {
    /// Registers this controller instance as a screen. Call in `viewDidLoad`.
    public func screenBridgeSource(_ symbol: String? = nil, role: String = "screen", related: [SourceReference] = [], file: String = #filePath, line: Int = #line) {
        SourceRegistry.shared.attach(SourceRegistration(symbol: symbol ?? String(describing: type(of: self)), role: role, file: file, line: line, related: related), to: self)
    }
}

extension UIView {
    /// Registers this view instance. Call where the view is created or configured.
    public func screenBridgeSource(_ symbol: String? = nil, role: String = "view", related: [SourceReference] = [], file: String = #filePath, line: Int = #line) {
        SourceRegistry.shared.attach(SourceRegistration(symbol: symbol ?? String(describing: type(of: self)), role: role, file: file, line: line, related: related), to: self)
    }
}

extension UITableViewCell {
    /// Registers a reusable cell for one index path. Call in `cellForRowAt` every time.
    /// The registration is ignored automatically once the cell is reused for another row.
    public func screenBridgeSource(_ symbol: String? = nil, at indexPath: IndexPath, in tableView: UITableView, related: [SourceReference] = [], file: String = #filePath, line: Int = #line) {
        let reg = SourceRegistration(symbol: symbol ?? String(describing: type(of: self)), role: "cell", file: file, line: line, related: related)
        SourceRegistry.shared.attach(reg, to: self, reuse: ReuseValidity(container: tableView, indexPath: indexPath, currentIndexPath: { container, cell in
            guard let tv = container as? UITableView, let c = cell as? UITableViewCell else { return nil }
            return tv.indexPath(for: c)
        }))
    }
}

extension UICollectionViewCell {
    /// Registers a reusable cell for one index path. Call in `cellForItemAt` (or the
    /// cell registration handler) every time.
    public func screenBridgeSource(_ symbol: String? = nil, at indexPath: IndexPath, in collectionView: UICollectionView, related: [SourceReference] = [], file: String = #filePath, line: Int = #line) {
        let reg = SourceRegistration(symbol: symbol ?? String(describing: type(of: self)), role: "cell", file: file, line: line, related: related)
        SourceRegistry.shared.attach(reg, to: self, reuse: ReuseValidity(container: collectionView, indexPath: indexPath, currentIndexPath: { container, cell in
            guard let cv = container as? UICollectionView, let c = cell as? UICollectionViewCell else { return nil }
            return cv.indexPath(for: c)
        }))
    }
}

extension View {
    /// Marks this SwiftUI view's frame with a source anchor (this call site by default).
    ///
    /// Implemented with a transparent background `UIViewRepresentable`; no private
    /// SwiftUI API is used. In release builds this returns the view unchanged.
    public func screenBridgeSource(_ symbol: String, role: String = "swiftui", related: [SourceReference] = [], file: String = #filePath, line: Int = #line) -> some View {
        background(SourceMarker(registration: SourceRegistration(symbol: symbol, role: role, file: file, line: line, related: related)))
    }
}
#else
// Release: inlinable no-ops, so call sites compile unchanged and the compiler drops
// their `#filePath` literals (no absolute Mac paths in distribution binaries).
extension UIViewController {
    @inlinable @inline(__always)
    public func screenBridgeSource(_ symbol: String? = nil, role: String = "screen", related: [SourceReference] = [], file: String = #filePath, line: Int = #line) {}
}

extension UIView {
    @inlinable @inline(__always)
    public func screenBridgeSource(_ symbol: String? = nil, role: String = "view", related: [SourceReference] = [], file: String = #filePath, line: Int = #line) {}
}

extension UITableViewCell {
    @inlinable @inline(__always)
    public func screenBridgeSource(_ symbol: String? = nil, at indexPath: IndexPath, in tableView: UITableView, related: [SourceReference] = [], file: String = #filePath, line: Int = #line) {}
}

extension UICollectionViewCell {
    @inlinable @inline(__always)
    public func screenBridgeSource(_ symbol: String? = nil, at indexPath: IndexPath, in collectionView: UICollectionView, related: [SourceReference] = [], file: String = #filePath, line: Int = #line) {}
}

extension View {
    @inlinable @inline(__always)
    public func screenBridgeSource(_ symbol: String, role: String = "swiftui", related: [SourceReference] = [], file: String = #filePath, line: Int = #line) -> Self { self }
}
#endif
#endif
