import Foundation
import ScreenBridgeProtocol
import ScreenBridgeTransport

/// Location of all Mac-side state. Defaults to `~/Library/Application Support/ScreenBridge`;
/// `SCREENBRIDGE_HOME` overrides it (tests, multiple receivers on one Mac).
public struct SBHome: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func `default`() -> SBHome {
        if let override = ProcessInfo.processInfo.environment["SCREENBRIDGE_HOME"], !override.isEmpty {
            return SBHome(root: URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return SBHome(root: base.appendingPathComponent("ScreenBridge", isDirectory: true))
    }

    public var binDirectory: URL { root.appendingPathComponent("bin", isDirectory: true) }
    public var reportsDirectory: URL { root.appendingPathComponent("reports", isDirectory: true) }
    public var buildsDirectory: URL { root.appendingPathComponent("builds", isDirectory: true) }
    public var receiverFile: URL { root.appendingPathComponent("receiver.json") }
    public var credentialsFile: URL { root.appendingPathComponent("credentials.json") }
    public var projectsFile: URL { root.appendingPathComponent("projects.json") }
    public var helperStatusFile: URL { root.appendingPathComponent("helper-status.json") }
    public var lockFile: URL { root.appendingPathComponent(".lock") }

    /// Creates the directory tree with owner-only permissions.
    public func prepare() throws {
        let fm = FileManager.default
        for dir in [root, binDirectory, reportsDirectory, buildsDirectory] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }

    /// Runs `body` while holding an exclusive cross-process lock on the store.
    public func withLock<T>(_ body: () throws -> T) throws -> T {
        try prepare()
        let fd = open(lockFile.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw StoreError.io("Cannot open lock file \(lockFile.path)") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw StoreError.io("Cannot lock \(lockFile.path)") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

public enum StoreError: Error, CustomStringConvertible, Equatable {
    case io(String)
    case notFound(String)
    case invalid(String)

    public var description: String {
        switch self {
        case .io(let s), .notFound(let s), .invalid(let s): return s
        }
    }
}

enum JSONFile {
    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try ReportCoding.decoder().decode(T.self, from: Data(contentsOf: url))
    }

    /// Atomic write with explicit permissions (0600 for secrets).
    static func write<T: Encodable>(_ value: T, to url: URL, permissions: Int = 0o600) throws {
        let data = try ReportCoding.encoder(pretty: true).encode(value)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }
}

// MARK: - Receiver identity

public struct ReceiverIdentity: Codable, Sendable, Equatable {
    /// Public, non-secret identifier advertised in Bonjour TXT.
    public var receiverID: String
    public var name: String
    public var createdAt: Date

    public static func load(_ home: SBHome) throws -> ReceiverIdentity? {
        try JSONFile.read(ReceiverIdentity.self, from: home.receiverFile)
    }

    /// Loads or creates the identity. Name defaults to the Mac's user-visible name.
    public static func loadOrCreate(_ home: SBHome) throws -> ReceiverIdentity {
        try home.withLock {
            if let existing = try load(home) { return existing }
            let id = ReceiverIdentity(receiverID: UUID().uuidString.lowercased(), name: Host.current().localizedName ?? ProcessInfo.processInfo.hostName, createdAt: Date())
            try JSONFile.write(id, to: home.receiverFile, permissions: 0o644)
            return id
        }
    }
}

// MARK: - Projects

public struct RegisteredProject: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// Canonical (symlink-resolved) absolute path of the project root.
    public var rootPath: String
    public var registeredAt: Date
    public var lastBuildAt: Date?
}

public struct ProjectRegistry: Sendable {
    public let home: SBHome

    public init(home: SBHome) {
        self.home = home
    }

    public func all() throws -> [RegisteredProject] {
        try JSONFile.read([RegisteredProject].self, from: home.projectsFile) ?? []
    }

    public func project(id: String) throws -> RegisteredProject? {
        try all().first { $0.id == id }
    }

    /// Finds by ID, then by case-insensitive name.
    public func find(_ idOrName: String) throws -> RegisteredProject? {
        let projects = try all()
        return projects.first { $0.id == idOrName } ?? projects.first { $0.name.caseInsensitiveCompare(idOrName) == .orderedSame }
    }

    @discardableResult
    public func register(root: URL, name: String? = nil, buildAt: Date? = nil) throws -> RegisteredProject {
        // realpath, not URL.resolvingSymlinksInPath (which rewrites /private/var to /var).
        let canonical = SourceAccess.realpath(root.path) ?? root.standardizedFileURL.path
        return try home.withLock {
            var projects = try all()
            if let i = projects.firstIndex(where: { $0.rootPath == canonical }) {
                if let buildAt { projects[i].lastBuildAt = buildAt }
                try JSONFile.write(projects, to: home.projectsFile, permissions: 0o644)
                return projects[i]
            }
            let p = RegisteredProject(id: "proj-" + UUID().uuidString.lowercased().prefix(8), name: name ?? (canonical as NSString).lastPathComponent, rootPath: canonical, registeredAt: Date(), lastBuildAt: buildAt)
            projects.append(p)
            try JSONFile.write(projects, to: home.projectsFile, permissions: 0o644)
            return p
        }
    }

    public func remove(id: String) throws {
        try home.withLock {
            let projects = try all().filter { $0.id != id }
            try JSONFile.write(projects, to: home.projectsFile, permissions: 0o644)
        }
    }
}

// MARK: - Credentials

public struct StoredCredential: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var projectID: String
    public var appBundleIdentifier: String
    public var keyBase64: String
    public var createdAt: Date
    public var revokedAt: Date?
    public var lastUsedAt: Date?

    public var isActive: Bool { revokedAt == nil }
}

/// Development credentials, one active per (project, app bundle ID). Stored 0600.
public struct CredentialStore: Sendable {
    public let home: SBHome

    public init(home: SBHome) {
        self.home = home
    }

    public func all() throws -> [StoredCredential] {
        try JSONFile.read([StoredCredential].self, from: home.credentialsFile) ?? []
    }

    public func active() throws -> [StoredCredential] {
        try all().filter(\.isActive)
    }

    /// PSKs for the TLS listener.
    public func tlsCredentials() -> [TLSPSK.Credential] {
        ((try? active()) ?? []).compactMap { c in
            Data(base64Encoded: c.keyBase64).map { TLSPSK.Credential(identity: c.id, key: $0) }
        }
    }

    public func credential(id: String) throws -> StoredCredential? {
        try all().first { $0.id == id }
    }

    /// Returns the active credential for this project/app, creating one if needed.
    public func issue(projectID: String, appBundleIdentifier: String) throws -> StoredCredential {
        try home.withLock {
            var creds = try all()
            if let c = creds.first(where: { $0.isActive && $0.projectID == projectID && $0.appBundleIdentifier == appBundleIdentifier }) {
                return c
            }
            let c = StoredCredential(id: "cred-" + TLSPSK.randomKey(byteCount: 8).map { String(format: "%02x", $0) }.joined(),
                                     projectID: projectID, appBundleIdentifier: appBundleIdentifier,
                                     keyBase64: TLSPSK.randomKey().base64EncodedString(), createdAt: Date())
            creds.append(c)
            try JSONFile.write(creds, to: home.credentialsFile, permissions: 0o600)
            return c
        }
    }

    /// Revokes a credential. The next build issues a fresh one; the running helper must
    /// restart its listener (it watches this file) for revocation to take effect.
    public func revoke(id: String) throws {
        try home.withLock {
            var creds = try all()
            guard let i = creds.firstIndex(where: { $0.id == id }) else { throw StoreError.notFound("No credential \(id).") }
            creds[i].revokedAt = Date()
            // Drop the key material of revoked credentials.
            creds[i].keyBase64 = ""
            try JSONFile.write(creds, to: home.credentialsFile, permissions: 0o600)
        }
    }

    public func markUsed(id: String) {
        try? home.withLock {
            var creds = try all()
            guard let i = creds.firstIndex(where: { $0.id == id }) else { return }
            creds[i].lastUsedAt = Date()
            try JSONFile.write(creds, to: home.credentialsFile, permissions: 0o600)
        }
    }
}

// MARK: - Helper status heartbeat

public struct HelperStatus: Codable, Sendable {
    public var pid: Int32
    public var port: UInt16?
    public var receiverID: String
    public var updatedAt: Date

    public static func load(_ home: SBHome) -> HelperStatus? {
        try? JSONFile.read(HelperStatus.self, from: home.helperStatusFile)
    }

    public func write(_ home: SBHome) {
        try? JSONFile.write(self, to: home.helperStatusFile, permissions: 0o644)
    }

    /// True if the recorded process is alive.
    public var isRunning: Bool { kill(pid, 0) == 0 }
}
