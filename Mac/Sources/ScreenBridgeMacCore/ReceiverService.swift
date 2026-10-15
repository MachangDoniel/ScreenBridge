import Foundation
import AppKit
import ScreenBridgeProtocol
import ScreenBridgeTransport

/// Opens files in Xcode after confining them to a registered project root.
public enum SourceRevealer {
    public static func reveal(projectID: String, path: String, line: Int?, home: SBHome) -> RevealResult {
        guard let project = try? ProjectRegistry(home: home).project(id: projectID) else {
            return RevealResult(opened: false, message: "Project \(projectID) is not registered on this Mac.")
        }
        let url: URL
        do { url = try SourceAccess(root: project.rootPath).resolve(path) } catch {
            return RevealResult(opened: false, message: "Refused to open \(path): \(error)")
        }
        return reveal(url: url, line: line, displayPath: path)
    }

    public static func reveal(url: URL, line: Int?, displayPath: String) -> RevealResult {
        let xed = "/usr/bin/xed"
        if FileManager.default.isExecutableFile(atPath: xed) {
            var args: [String] = []
            if let line, line > 0 { args += ["--line", String(line)] }
            args.append(url.path)
            if let r = try? Subprocess.run(xed, args, timeout: 20), r.status == 0 {
                return RevealResult(opened: true, message: "Opened \(displayPath)\(line.map { ":\($0)" } ?? "") in Xcode.")
            }
        }
        // Fallback: open with Xcode without line selection.
        let opened: Bool
        if let xcode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") {
            NSWorkspace.shared.open([url], withApplicationAt: xcode, configuration: NSWorkspace.OpenConfiguration())
            opened = true
        } else {
            opened = NSWorkspace.shared.open(url)
        }
        return opened
            ? RevealResult(opened: true, message: "Opened \(displayPath) (line selection not available without xed).")
            : RevealResult(opened: false, message: "Could not open \(displayPath).")
    }
}

/// A connected app session as shown in the Connection screen.
public struct AppSession: Sendable, Identifiable, Equatable {
    public var id: UUID
    public var hello: Hello
    public var connectedAt: Date
    public var lastActivity: Date
    public var projectName: String
}

/// The receiver: TLS-PSK listener + report storage + reveal handling.
public final class ReceiverService: @unchecked Sendable {
    public struct Events: Sendable {
        public var reportReceived: @Sendable (StoredReport) -> Void = { _ in }
        public var sessionsChanged: @Sendable ([AppSession]) -> Void = { _ in }
        public var statusChanged: @Sendable (ReceiverListener.Status) -> Void = { _ in }
        public init() {}
    }

    public let home: SBHome
    public let identity: ReceiverIdentity
    private let events: Events
    private var listener: ReceiverListener?
    private let lock = NSLock()
    private var sessions: [UUID: AppSession] = [:]
    private var credentialWatcher: DispatchSourceFileSystemObject?
    private var lastCredentialIDs: Set<String> = []

    public init(home: SBHome = .default(), events: Events = Events()) throws {
        self.home = home
        self.identity = try ReceiverIdentity.loadOrCreate(home)
        self.events = events
    }

    public func start() throws {
        let home = self.home
        let credentials = CredentialStore(home: home)
        lastCredentialIDs = Set(credentials.tlsCredentials().map(\.identity))
        let handlers = ReceiverHandlers(
            credentials: { credentials.tlsCredentials() },
            hello: { [weak self] hello, id in self?.handleHello(hello, id) ?? HelloAck(accepted: false, receiverID: "", receiverName: "", reason: "Shutting down") },
            report: { [weak self] report, parts, id in self?.handleReport(report, parts, id) ?? .error(code: "shutdown", message: "Receiver is shutting down.") },
            reveal: { [weak self] req, id in self?.handleReveal(req, id) ?? RevealResult(opened: false, message: "Receiver is shutting down.") },
            closed: { [weak self] id in self?.removeSession(id) },
            listenerState: { [events, identity, home] status in
                if case .ready(let port) = status {
                    HelperStatus(pid: getpid(), port: port, receiverID: identity.receiverID, updatedAt: Date()).write(home)
                }
                events.statusChanged(status)
            }
        )
        let l = ReceiverListener(receiverID: identity.receiverID, receiverName: identity.name, handlers: handlers)
        try l.start()
        listener = l
        watchCredentials()
        ReportStore(home: home).applyRetention()
    }

    public func stop() {
        listener?.stop()
        listener = nil
        credentialWatcher?.cancel()
        credentialWatcher = nil
        try? FileManager.default.removeItem(at: home.helperStatusFile)
    }

    /// Rebuilds the TLS key set (after a new build issues a credential, or a revocation).
    public func reloadCredentials() {
        let ids = Set(CredentialStore(home: home).tlsCredentials().map(\.identity))
        guard ids != lastCredentialIDs else { return }
        lastCredentialIDs = ids
        try? listener?.restart()
        lock.withLock { sessions.removeAll() }
        events.sessionsChanged([])
    }

    public var currentSessions: [AppSession] {
        lock.withLock { Array(sessions.values).sorted { $0.connectedAt < $1.connectedAt } }
    }

    private func watchCredentials() {
        try? home.prepare()
        let fd = open(home.root.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend], queue: .global())
        source.setEventHandler { [weak self] in self?.reloadCredentials() }
        source.setCancelHandler { close(fd) }
        source.resume()
        credentialWatcher = source
    }

    // MARK: Handlers

    func handleHello(_ hello: Hello, _ id: UUID) -> HelloAck {
        func reject(_ reason: String) -> HelloAck {
            HelloAck(accepted: false, receiverID: identity.receiverID, receiverName: identity.name, reason: reason)
        }
        guard hello.receiverID == identity.receiverID else { return reject("This app was built for a different ScreenBridge receiver.") }
        guard let cred = try? CredentialStore(home: home).credential(id: hello.credentialID), cred.isActive else {
            return reject("Unknown or revoked credential. Rebuild the app.")
        }
        guard cred.projectID == hello.projectID, cred.appBundleIdentifier == hello.appBundleIdentifier else {
            return reject("Credential does not belong to \(hello.appBundleIdentifier).")
        }
        let projectName = (try? ProjectRegistry(home: home).project(id: cred.projectID))?.name ?? cred.projectID
        CredentialStore(home: home).markUsed(id: cred.id)
        lock.withLock {
            sessions[id] = AppSession(id: id, hello: hello, connectedAt: Date(), lastActivity: Date(), projectName: projectName)
        }
        events.sessionsChanged(currentSessions)
        return HelloAck(accepted: true, receiverID: identity.receiverID, receiverName: identity.name)
    }

    func handleReport(_ report: DebugReport, _ parts: [String: Data], _ id: UUID) -> WireEnvelope {
        guard let session = lock.withLock({ sessions[id] }) else {
            return .error(code: "no-session", message: "Say hello first.")
        }
        touch(id)
        let store = ReportStore(home: home)
        let project = try? ProjectRegistry(home: home).project(id: session.hello.projectID)
        let receipt = ReportReceipt(
            receivedAt: Date(),
            projectID: session.hello.projectID,
            credentialID: session.hello.credentialID,
            deviceModel: session.hello.deviceModel,
            consistencyAtReceipt: project.map { Self.consistency(for: report, root: $0.rootPath, home: home) },
            inferredCandidates: project.map { Self.candidates(for: report, root: $0.rootPath) } ?? []
        )
        do {
            let result = try store.save(report, parts: parts, receipt: receipt)
            if result == .stored, let stored = try? store.load(report.id) {
                events.reportReceived(stored)
            }
            return .reportAck(ReportAck(reportID: report.id, duplicate: result == .duplicate, receivedAt: Date()))
        } catch {
            return .error(code: "rejected", message: "\(error)")
        }
    }

    func handleReveal(_ req: RevealRequest, _ id: UUID) -> RevealResult {
        guard let session = lock.withLock({ sessions[id] }) else { return RevealResult(opened: false, message: "No session.") }
        touch(id)
        // Only the session's own project may be revealed.
        guard req.projectID == session.hello.projectID else { return RevealResult(opened: false, message: "Project mismatch.") }
        return SourceRevealer.reveal(projectID: req.projectID, path: req.path, line: req.line, home: home)
    }

    private func touch(_ id: UUID) {
        lock.withLock { sessions[id]?.lastActivity = Date() }
    }

    private func removeSession(_ id: UUID) {
        let removed = lock.withLock { sessions.removeValue(forKey: id) != nil }
        if removed { events.sessionsChanged(currentSessions) }
    }

    // MARK: Analysis helpers (also used by MCP)

    public static func consistency(for report: DebugReport, root: String, home: SBHome) -> SourceConsistency {
        let snapshot = report.build.buildID.flatMap { BuildSnapshotStore(home: home).load($0) }
        let current = try? GitInspector.state(of: URL(fileURLWithPath: root, isDirectory: true))
        let paths = report.sourceAnchors.compactMap { $0.pathStatus == .repositoryRelative ? $0.path : nil }
        return SourceConsistency.evaluate(build: report.build, snapshot: snapshot, current: current, anchorPaths: paths)
    }

    public static func candidates(for report: DebugReport, root: String) -> [SourceAnchor] {
        let unresolved = Set(report.sourceAnchors.filter { $0.pathStatus == .unknown }.map(\.symbol))
        return unresolved.sorted().flatMap { CandidateFinder.candidates(forType: $0, root: root, maxResults: 3) }
    }
}
