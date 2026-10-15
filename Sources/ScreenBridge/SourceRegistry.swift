#if SCREENBRIDGE_ENABLED
import Foundation
import ObjectiveC
import ScreenBridgeProtocol

/// A source registration captured from caller-site `#filePath`/`#line` defaults.
public struct SourceRegistration: Sendable, Hashable {
    public var symbol: String
    public var role: String
    /// Absolute path from `#filePath` (converted to repository-relative on export).
    public var file: String
    public var line: Int
    public var related: [SourceReference]

    public init(symbol: String, role: String, file: String, line: Int, related: [SourceReference] = []) {
        self.symbol = symbol
        self.role = role
        self.file = file
        self.line = line
        self.related = related
    }
}

/// Validity check for registrations on reusable cells. The registration records the
/// index path it was configured for; at inspection time it is valid only if the cell
/// still occupies that index path in the same container.
struct ReuseValidity {
    weak var container: AnyObject?
    let indexPath: IndexPath
    /// Returns the cell's current index path in `container`, or nil if not visible.
    let currentIndexPath: @MainActor (_ container: AnyObject, _ cell: AnyObject) -> IndexPath?
}

/// Associated-object payload. Holds only value data and a weak container reference,
/// so registering never retains the registered object or its container.
final class RegistrationBox: NSObject {
    let registration: SourceRegistration
    let reuse: ReuseValidity?

    init(_ registration: SourceRegistration, reuse: ReuseValidity?) {
        self.registration = registration
        self.reuse = reuse
    }
}

public enum RegistrationLookup: Equatable {
    case none
    case valid(SourceRegistration)
    /// Present but invalid, e.g. a reused cell now showing a different row.
    case stale(SourceRegistration, reason: String)
}

/// Process-wide registry. Type registrations are keyed by metatype identity; object
/// registrations live on the objects themselves via associated objects.
public final class SourceRegistry: @unchecked Sendable {
    public static let shared = SourceRegistry()

    private let lock = NSLock()
    private var typeRegistrations: [ObjectIdentifier: SourceRegistration] = [:]
    nonisolated(unsafe) private static var associationKey: UInt8 = 0

    init() {}

    // MARK: Types

    public func register(type: Any.Type, registration: SourceRegistration) {
        lock.lock(); defer { lock.unlock() }
        typeRegistrations[ObjectIdentifier(type)] = registration
    }

    public func registration(forType type: Any.Type) -> SourceRegistration? {
        lock.lock(); defer { lock.unlock() }
        return typeRegistrations[ObjectIdentifier(type)]
    }

    /// Looks up the class and then its superclasses.
    public func registration(forClassOf object: AnyObject) -> SourceRegistration? {
        var cls: AnyClass? = Swift.type(of: object)
        while let c = cls {
            if let r = registration(forType: c) { return r }
            cls = class_getSuperclass(c)
        }
        return nil
    }

    func registration(for identifier: ObjectIdentifier) -> SourceRegistration? {
        lock.lock(); defer { lock.unlock() }
        return typeRegistrations[identifier]
    }

    // MARK: Objects

    func attach(_ registration: SourceRegistration, to object: AnyObject, reuse: ReuseValidity? = nil) {
        objc_setAssociatedObject(object, &Self.associationKey, RegistrationBox(registration, reuse: reuse), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    func detach(from object: AnyObject) {
        objc_setAssociatedObject(object, &Self.associationKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// The registration attached to this specific object, validated for cell reuse.
    @MainActor
    func instanceRegistration(of object: AnyObject) -> RegistrationLookup {
        guard let box = objc_getAssociatedObject(object, &Self.associationKey) as? RegistrationBox else { return .none }
        guard let reuse = box.reuse else { return .valid(box.registration) }
        guard let container = reuse.container else {
            return .stale(box.registration, reason: "Its container no longer exists.")
        }
        guard let current = reuse.currentIndexPath(container, object) else {
            return .stale(box.registration, reason: "The cell is not currently displayed at a known index path.")
        }
        guard current == reuse.indexPath else {
            return .stale(box.registration, reason: "Registered for row \(Self.describe(reuse.indexPath)) but the reused cell now shows row \(Self.describe(current)).")
        }
        return .valid(box.registration)
    }

    /// Instance registration if valid, otherwise a type registration for the object's class.
    @MainActor
    func effectiveRegistration(of object: AnyObject) -> (registration: SourceRegistration?, staleNote: String?) {
        switch instanceRegistration(of: object) {
        case .valid(let r): return (r, nil)
        case .stale(let r, let reason):
            return (registration(forClassOf: object), "Ignored stale registration \(r.symbol): \(reason)")
        case .none:
            return (registration(forClassOf: object), nil)
        }
    }

    private static func describe(_ ip: IndexPath) -> String {
        ip.count == 2 ? "\(ip[0])/\(ip[1])" : ip.map(String.init).joined(separator: ".")
    }

    // MARK: Anchors

    /// Converts a registration into exported anchors (primary + related).
    public func anchors(for registration: SourceRegistration, projectRoot: String?, roleOverride: String? = nil, note: String? = nil) -> [SourceAnchor] {
        let (path, status) = PathRelativizer.relativize(registration.file, root: projectRoot)
        var out = [SourceAnchor(symbol: registration.symbol, role: roleOverride ?? registration.role, path: path, line: registration.line, pathStatus: status, evidence: .registered, note: note)]
        for ref in registration.related {
            out.append(anchor(for: ref, projectRoot: projectRoot))
        }
        return out
    }

    public func anchor(for reference: SourceReference, projectRoot: String?) -> SourceAnchor {
        switch reference.target {
        case .file(let p, let line):
            let (path, status) = PathRelativizer.relativize(p, root: projectRoot)
            return SourceAnchor(symbol: reference.symbol, role: reference.role, path: path, line: line, pathStatus: status, evidence: .registered)
        case .type(let id, let name):
            if let r = registration(for: id) {
                let (path, status) = PathRelativizer.relativize(r.file, root: projectRoot)
                return SourceAnchor(symbol: name, role: reference.role, path: path, line: r.line, pathStatus: status, evidence: .registered)
            }
            return SourceAnchor(symbol: name, role: reference.role, path: nil, line: nil, pathStatus: .unknown, evidence: .registered,
                                note: "Related type has no registered file. Call ScreenBridge.register(\(name).self) in its file to link it.")
        }
    }
}
#endif
