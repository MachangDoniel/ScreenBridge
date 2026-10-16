#if !SCREENBRIDGE_STRIPPED
import Foundation

/// Versioning rules for `DebugReport` JSON.
///
/// - Readers accept any report with the same major version and ignore unknown fields,
///   so a 1.0 reader can read a 1.3 report.
/// - A different major version is rejected with `ReportSchemaError.incompatibleMajor`.
public enum ReportSchema {
    public static let major = 1
    public static let minor = 1
    public static var current: String { "\(major).\(minor)" }

    public static func parse(_ version: String) throws -> (major: Int, minor: Int) {
        let parts = version.split(separator: ".")
        guard parts.count == 2, let ma = Int(parts[0]), let mi = Int(parts[1]), ma >= 0, mi >= 0 else {
            throw ReportSchemaError.malformedVersion(version)
        }
        return (ma, mi)
    }
}

public enum ReportSchemaError: Error, Equatable, CustomStringConvertible {
    case missingVersion
    case malformedVersion(String)
    case incompatibleMajor(found: Int, supported: Int)
    case invalidReportID(String)

    public var description: String {
        switch self {
        case .missingVersion: return "Report has no schemaVersion."
        case .malformedVersion(let v): return "Report schemaVersion '\(v)' is malformed."
        case .incompatibleMajor(let f, let s): return "Report schema major version \(f) is not supported (expected \(s))."
        case .invalidReportID(let id): return "Report ID '\(id)' is not valid."
        }
    }
}

/// Report identifiers look like `SB-7F3A2C9104BE`: stable, human-typable, and safe
/// to use as a directory name (validated before any filesystem use).
public enum ReportID {
    public static func make() -> String {
        var bytes = [UInt8](repeating: 0, count: 6)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return "SB-" + bytes.map { String(format: "%02X", $0) }.joined()
    }

    public static func isValid(_ id: String) -> Bool {
        guard id.count == 15, id.hasPrefix("SB-") else { return false }
        return id.dropFirst(3).allSatisfy { ("0"..."9").contains($0) || ("A"..."F").contains($0) }
    }
}

public enum SourceEvidence: String, Codable, Sendable {
    /// Registered explicitly in code with `#filePath`/`#line` defaults.
    case registered
    /// Produced by a build-time index (reserved; not generated in v1).
    case generatedMapping
    /// Found by searching the repository. Not verified — may be wrong.
    case inferredCandidate
}

public enum SourcePathStatus: String, Codable, Sendable {
    /// `path` is relative to the registered project root.
    case repositoryRelative
    /// The file is outside the project root; `path` holds only its file name.
    case outsideProject
    /// No file is known (for example a related type that never registered itself).
    case unknown
}

/// A source location associated with UI at runtime.
///
/// A registration anchor marks where code *registered* the element or screen
/// (usually its definition or setup). It is not necessarily the line that causes a bug.
public struct SourceAnchor: Codable, Sendable, Hashable {
    public var symbol: String
    /// Free-form role such as `screen`, `view`, `cell`, `swiftui`, `viewModel`, `service`.
    public var role: String
    public var path: String?
    public var line: Int?
    public var pathStatus: SourcePathStatus
    public var evidence: SourceEvidence
    public var note: String?

    public init(symbol: String, role: String, path: String?, line: Int?, pathStatus: SourcePathStatus, evidence: SourceEvidence, note: String? = nil) {
        self.symbol = symbol
        self.role = role
        self.path = path
        self.line = line
        self.pathStatus = pathStatus
        self.evidence = evidence
        self.note = note
    }
}

public enum PathRelativizer {
    /// Converts an absolute `#filePath` into a repository-relative path when it lies
    /// under `root`. Paths outside the root are reduced to their file name so absolute
    /// Mac paths never leave the device in a report.
    public static func relativize(_ absolute: String, root: String?) -> (path: String, status: SourcePathStatus) {
        let fileName = (absolute as NSString).lastPathComponent
        guard absolute.hasPrefix("/") else {
            // Already relative (e.g. a generated mapping); keep it if it has no traversal.
            if absolute.split(separator: "/").contains("..") { return (fileName, .outsideProject) }
            return (absolute, .repositoryRelative)
        }
        guard let root, !root.isEmpty else { return (fileName, .outsideProject) }
        let normalizedRoot = root.hasSuffix("/") ? root : root + "/"
        let standardized = (absolute as NSString).standardizingPath
        guard standardized.hasPrefix(normalizedRoot) else { return (fileName, .outsideProject) }
        return (String(standardized.dropFirst(normalizedRoot.count)), .repositoryRelative)
    }
}

public struct ElementNode: Codable, Sendable, Equatable {
    public var className: String
    public var accessibilityIdentifier: String?
    public var registeredSymbol: String?

    public init(className: String, accessibilityIdentifier: String? = nil, registeredSymbol: String? = nil) {
        self.className = className
        self.accessibilityIdentifier = accessibilityIdentifier
        self.registeredSymbol = registeredSymbol
    }
}

public struct SelectedElement: Codable, Sendable, Equatable {
    public var className: String
    /// Registered symbol for the element when one exists, otherwise the class name.
    public var displayName: String
    public var accessibilityIdentifier: String?
    public var isSwiftUIMarker: Bool
    /// Element frame in screenshot pixels (top-left origin).
    public var frameInScreenshot: SBRect
    /// Root-to-element chain, capped in length.
    public var hierarchy: [ElementNode]
    /// Explanations such as ignored stale cell registrations.
    public var notes: [String]
    /// Safe runtime values; secure text inputs are omitted.
    public var properties: [String: String]?

    public init(className: String, displayName: String, accessibilityIdentifier: String?, isSwiftUIMarker: Bool, frameInScreenshot: SBRect, hierarchy: [ElementNode], notes: [String] = [], properties: [String: String]? = nil) {
        self.className = className
        self.displayName = displayName
        self.accessibilityIdentifier = accessibilityIdentifier
        self.isSwiftUIMarker = isSwiftUIMarker
        self.frameInScreenshot = frameInScreenshot
        self.hierarchy = hierarchy
        self.notes = notes
        self.properties = properties
    }
}

public struct ScreenContext: Codable, Sendable, Equatable {
    public var owningController: String
    /// From the owning controller up to the window's root controller.
    public var controllerChain: [String]
    public var navigationStack: [String]?
    public var navigationIndex: Int?
    public var tabSelectedIndex: Int?
    public var tabCount: Int?
    public var presentation: String?
    public var containment: [String]

    public init(owningController: String, controllerChain: [String], navigationStack: [String]? = nil, navigationIndex: Int? = nil, tabSelectedIndex: Int? = nil, tabCount: Int? = nil, presentation: String? = nil, containment: [String] = []) {
        self.owningController = owningController
        self.controllerChain = controllerChain
        self.navigationStack = navigationStack
        self.navigationIndex = navigationIndex
        self.tabSelectedIndex = tabSelectedIndex
        self.tabCount = tabCount
        self.presentation = presentation
        self.containment = containment
    }
}

public struct AppInfo: Codable, Sendable, Equatable {
    public var bundleIdentifier: String
    public var name: String
    public var version: String
    public var build: String

    public init(bundleIdentifier: String, name: String, version: String, build: String) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.version = version
        self.build = build
    }
}

public struct DeviceInfo: Codable, Sendable, Equatable {
    public var model: String
    public var systemName: String
    public var systemVersion: String
    public var isSimulator: Bool
    public var interfaceIdiom: String

    public init(model: String, systemName: String, systemVersion: String, isSimulator: Bool, interfaceIdiom: String) {
        self.model = model
        self.systemName = systemName
        self.systemVersion = systemVersion
        self.isSimulator = isSimulator
        self.interfaceIdiom = interfaceIdiom
    }
}

/// Build/source identity recorded by the build integration at build time.
public struct BuildInfo: Codable, Sendable, Equatable {
    public var buildID: String?
    public var configuration: String?
    public var projectID: String?
    public var projectName: String?
    public var gitCommit: String?
    public var gitBranch: String?
    /// `nil` means unknown (not a git repository or git failed).
    public var isDirty: Bool?
    /// Hash of the working-tree state (status + diff + untracked contents) at build time.
    public var workingTreeFingerprint: String?
    public var builtAt: Date?
    /// False when the app launched without a generated connection configuration.
    public var configured: Bool

    public init(buildID: String? = nil, configuration: String? = nil, projectID: String? = nil, projectName: String? = nil, gitCommit: String? = nil, gitBranch: String? = nil, isDirty: Bool? = nil, workingTreeFingerprint: String? = nil, builtAt: Date? = nil, configured: Bool) {
        self.buildID = buildID
        self.configuration = configuration
        self.projectID = projectID
        self.projectName = projectName
        self.gitCommit = gitCommit
        self.gitBranch = gitBranch
        self.isDirty = isDirty
        self.workingTreeFingerprint = workingTreeFingerprint
        self.builtAt = builtAt
        self.configured = configured
    }

    public static let unconfigured = BuildInfo(configured: false)
}

public struct LogEntry: Codable, Sendable, Equatable {
    public var timestamp: Date
    public var level: String
    public var category: String
    /// Already sanitized on device.
    public var message: String

    public init(timestamp: Date, level: String, category: String, message: String) {
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
    }
}

public enum ImageRole: String, Codable, Sendable {
    /// Screenshot without markup. When `redacted` is true, redactions were burned in.
    case original
    /// Screenshot with all annotations and redactions flattened.
    case annotated
}

public struct ImageAttachment: Codable, Sendable, Equatable {
    public var role: ImageRole
    public var fileName: String
    public var mimeType: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var byteCount: Int
    public var sha256: String
    public var redacted: Bool

    public init(role: ImageRole, fileName: String, mimeType: String = "image/png", pixelWidth: Int, pixelHeight: Int, byteCount: Int, sha256: String, redacted: Bool) {
        self.role = role
        self.fileName = fileName
        self.mimeType = mimeType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
        self.sha256 = sha256
        self.redacted = redacted
    }
}

public struct TransferMetadata: Codable, Sendable, Equatable {
    public var queuedAt: Date
    public var attempt: Int
    public var sentAt: Date?

    public init(queuedAt: Date, attempt: Int, sentAt: Date? = nil) {
        self.queuedAt = queuedAt
        self.attempt = attempt
        self.sentAt = sentAt
    }
}

public struct DebugReport: Codable, Sendable, Equatable {
    public var schemaVersion: String
    public var id: String
    public var createdAt: Date
    public var description: String
    public var screenshot: ScreenshotGeometry
    public var images: [ImageAttachment]
    public var annotations: [Annotation]
    public var redactionApplied: Bool
    public var selection: SelectedElement?
    public var screen: ScreenContext?
    public var sourceAnchors: [SourceAnchor]
    public var app: AppInfo
    public var device: DeviceInfo
    public var build: BuildInfo
    public var logs: [LogEntry]?
    public var transfer: TransferMetadata?
    public var claudeDestination: ClaudeDestination?
    /// Area selected in screenshot pixels; does not crop the screenshot.
    public var selectedRegion: SBRect?

    public init(id: String = ReportID.make(), createdAt: Date = Date(), description: String, screenshot: ScreenshotGeometry, images: [ImageAttachment], annotations: [Annotation], redactionApplied: Bool, selection: SelectedElement?, screen: ScreenContext?, sourceAnchors: [SourceAnchor], app: AppInfo, device: DeviceInfo, build: BuildInfo, logs: [LogEntry]?, transfer: TransferMetadata? = nil) {
        self.schemaVersion = ReportSchema.current
        self.id = id
        self.createdAt = createdAt
        self.description = description
        self.screenshot = screenshot
        self.images = images
        self.annotations = annotations
        self.redactionApplied = redactionApplied
        self.selection = selection
        self.screen = screen
        self.sourceAnchors = sourceAnchors
        self.app = app
        self.device = device
        self.build = build
        self.logs = logs
        self.transfer = transfer
    }

    public func image(_ role: ImageRole) -> ImageAttachment? { images.first { $0.role == role } }
}

public enum ReportCoding {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public static func encode(_ report: DebugReport, pretty: Bool = false) throws -> Data {
        try encoder(pretty: pretty).encode(report)
    }

    /// Decodes a report after checking that its schema major version is supported.
    public static func decode(_ data: Data) throws -> DebugReport {
        try validateVersion(of: data)
        let report = try decoder().decode(DebugReport.self, from: data)
        guard ReportID.isValid(report.id) else { throw ReportSchemaError.invalidReportID(report.id) }
        return report
    }

    public static func validateVersion(of data: Data) throws {
        struct Probe: Decodable { var schemaVersion: String? }
        let probe = try decoder().decode(Probe.self, from: data)
        guard let v = probe.schemaVersion else { throw ReportSchemaError.missingVersion }
        try validate(version: v)
    }

    public static func validate(version: String) throws {
        let parsed = try ReportSchema.parse(version)
        guard parsed.major == ReportSchema.major else {
            throw ReportSchemaError.incompatibleMajor(found: parsed.major, supported: ReportSchema.major)
        }
    }
}
#endif
