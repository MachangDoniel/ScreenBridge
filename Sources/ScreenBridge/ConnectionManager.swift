#if SCREENBRIDGE_ENABLED && canImport(UIKit)
import UIKit
import Network
import ScreenBridgeProtocol
import ScreenBridgeTransport

/// Owns discovery of the build-configured Mac, the authenticated session and the outbox.
@MainActor
final class ConnectionManager: ObservableObject {
    enum Status: Equatable {
        case notConfigured(String)
        case searching(mac: String)
        case connecting(mac: String)
        case connected(mac: String)
        case unavailable(String)
        case authenticationFailed(String)
        case permissionDenied(String)

        var isConnected: Bool { if case .connected = self { return true }; return false }

        var shortText: String {
            switch self {
            case .notConfigured: return "Not set up for this build"
            case .searching(let mac): return "Looking for \(mac)…"
            case .connecting(let mac): return "Connecting to \(mac)…"
            case .connected(let mac): return "Connected to \(mac)"
            case .unavailable: return "Mac unavailable"
            case .authenticationFailed: return "Mac rejected this build"
            case .permissionDenied: return "Local Network access needed"
            }
        }

        var detail: String? {
            switch self {
            case .notConfigured(let s), .unavailable(let s), .authenticationFailed(let s), .permissionDenied(let s): return s
            case .searching: return "Make sure the ScreenBridge helper is running on your Mac and both devices are on the same network."
            default: return nil
            }
        }
    }

    enum SendState: Equatable {
        case sending
        case acknowledged(reportID: String, duplicate: Bool)
        case queued(reportID: String, reason: String)
        case failed(reportID: String, error: String)
    }

    @Published private(set) var status: Status {
        didSet {
            guard status != oldValue else { return }
            ScreenBridge.log(status.shortText + (status.detail.map { ": " + $0 } ?? ""), category: "connection")
        }
    }
    @Published private(set) var queuedCount = 0
    @Published private(set) var lastDelivery: SendState?

    let config: ConnectionConfig?
    let configProblem: String?
    let outbox: OutboxStore
    private let processor: OutboxProcessor
    private let policy = RetryPolicy()
    private var browser: ReceiverBrowser?
    private var endpoints: [NWEndpoint] = []
    private var session: ReceiverSession?
    private var connectTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var reconnectFailures = 0
    private var authFailed = false

    init(config: ConnectionConfig?, configProblem: String?, outboxCapacity: Int) {
        self.config = config
        self.configProblem = configProblem
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        outbox = OutboxStore(directory: dir.appendingPathComponent("ScreenBridge/Outbox", isDirectory: true), capacity: outboxCapacity)
        processor = OutboxProcessor(store: outbox, policy: policy)
        if let config {
            status = .searching(mac: config.receiverName)
        } else {
            status = .notConfigured(configProblem ?? "No connection configuration.")
        }
        queuedCount = outbox.items().count
    }

    var macName: String { config?.receiverName ?? "your Mac" }

    func start() {
        guard let config, browser == nil else { return }
        authFailed = false
        let b = ReceiverBrowser(receiverID: config.receiverID, serviceType: config.serviceType)
        browser = b
        b.start { [weak self] endpoints, state in
            Task { @MainActor in self?.browserChanged(endpoints, state) }
        }
    }

    func stop() {
        browser?.stop()
        browser = nil
        connectTask?.cancel()
        retryTask?.cancel()
        if let session { Task { await session.close() } }
        session = nil
        if let config { status = .searching(mac: config.receiverName) }
    }

    /// Called when the app returns to the foreground: rediscover and flush the outbox.
    func resume() {
        stop()
        outbox.makeAllDue()
        start()
    }

    private func browserChanged(_ endpoints: [NWEndpoint], _ state: ReceiverBrowser.State) {
        self.endpoints = endpoints
        switch state {
        case .permissionDenied(let msg):
            status = .permissionDenied(msg)
            return
        case .failed(let msg) where endpoints.isEmpty:
            status = .unavailable("Bonjour browsing failed: \(msg)")
            return
        default: break
        }
        if session == nil && !authFailed {
            if endpoints.isEmpty {
                status = .searching(mac: macName)
            } else {
                connectIfNeeded()
            }
        }
    }

    private func connectIfNeeded() {
        guard session == nil, connectTask == nil, let config, let endpoint = endpoints.first, !authFailed else { return }
        status = .connecting(mac: config.receiverName)
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                let s = try await ReceiverSession.connect(to: endpoint, config: config, hello: self.makeHello(config))
                self.session = s
                self.reconnectFailures = 0
                self.status = .connected(mac: await s.receiverName)
                self.connectTask = nil
                await self.flushOutbox()
            } catch let e as TransportError where e.isAuthenticationFailure {
                self.connectTask = nil
                self.authFailed = true
                self.status = .authenticationFailed("\(e.description) Rebuild and run the app from Xcode so the build phase refreshes its credential. If you revoked it in the ScreenBridge helper, rebuilding issues a new one.")
            } catch {
                self.connectTask = nil
                self.reconnectFailures += 1
                self.status = .unavailable("\(error)")
                self.scheduleReconnect()
            }
        }
    }

    private func scheduleReconnect() {
        retryTask?.cancel()
        let delay = policy.delay(afterFailedAttempts: reconnectFailures)
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            if self.session == nil { self.connectIfNeeded() }
        }
    }

    private func dropSession() {
        if let session { Task { await session.close() } }
        session = nil
        if !authFailed, let config { status = endpoints.isEmpty ? .searching(mac: config.receiverName) : .connecting(mac: config.receiverName) }
    }

    private func makeHello(_ config: ConnectionConfig) -> Hello {
        let device = DeviceMetadata.current()
        let app = DeviceMetadata.app()
        return Hello(credentialID: config.credentialID, receiverID: config.receiverID, projectID: config.projectID, appBundleIdentifier: app.bundleIdentifier, appName: app.name, buildID: config.build.buildID, deviceModel: device.model, systemVersion: device.systemVersion, isSimulator: device.isSimulator)
    }

    // MARK: Sending

    func enqueueAndSend(report: DebugReport, parts: [(name: String, data: Data)]) async -> SendState {
        ScreenBridge.log("Sending report \(report.id) to \(macName)", category: "transfer")
        do {
            try outbox.enqueue(report: report, parts: parts)
        } catch {
            return .failed(reportID: report.id, error: "Could not save the report: \(error)")
        }
        queuedCount = outbox.items().count
        guard config != nil else {
            return .queued(reportID: report.id, reason: "This build is not connected to a Mac. The report is saved on this device.")
        }
        guard let session else {
            connectIfNeeded()
            return .queued(reportID: report.id, reason: "Saved on this device. It will send automatically when \(macName) is reachable.")
        }
        let outcome = await processor.deliver(report.id, using: SessionSender(session: session))
        queuedCount = outbox.items().count
        switch outcome {
        case .acknowledged(let id, let dup):
            ScreenBridge.log("Mac acknowledged report \(id)", category: "transfer")
            return .acknowledged(reportID: id, duplicate: dup)
        case .failed(let id, let err, _):
            dropSession()
            connectIfNeeded()
            scheduleFlush()
            return .queued(reportID: id, reason: "Couldn't reach \(macName) (\(err)). The report is saved and will be retried automatically.")
        case .expired(let id):
            return .failed(reportID: id, error: "The report expired before it could be sent.")
        }
    }

    func retry(reportID: String) async -> SendState {
        guard let session else {
            connectIfNeeded()
            return .queued(reportID: reportID, reason: "Still waiting for \(macName).")
        }
        let outcome = await processor.deliver(reportID, using: SessionSender(session: session))
        queuedCount = outbox.items().count
        switch outcome {
        case .acknowledged(let id, let dup): return .acknowledged(reportID: id, duplicate: dup)
        case .failed(let id, let err, _): dropSession(); connectIfNeeded(); return .queued(reportID: id, reason: err)
        case .expired(let id): return .failed(reportID: id, error: "Expired.")
        }
    }

    private func flushOutbox() async {
        guard let session else { return }
        let outcomes = await processor.processDue(using: SessionSender(session: session))
        queuedCount = outbox.items().count
        for outcome in outcomes {
            switch outcome {
            case .acknowledged(let id, let duplicate):
                lastDelivery = .acknowledged(reportID: id, duplicate: duplicate)
                ScreenBridge.log("Mac acknowledged queued report \(id)", category: "transfer")
            case .expired(let id): lastDelivery = .failed(reportID: id, error: "The report expired before it could be sent.")
            case .failed: break // The outbox retains it for retry.
            }
        }
        if outcomes.contains(where: { if case .failed = $0 { return true }; return false }) {
            dropSession()
            connectIfNeeded()
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard let next = outbox.items().map(\.nextAttemptAt).min() else { return }
        let delay = max(1, next.timeIntervalSinceNow)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self else { return }
            if self.session != nil { await self.flushOutbox() } else { self.connectIfNeeded() }
        }
    }

    // MARK: Reveal

    func reveal(_ anchor: SourceAnchor) async -> RevealResult {
        guard let config else { return RevealResult(opened: false, message: "This build has no ScreenBridge connection.") }
        guard anchor.pathStatus == .repositoryRelative, let path = anchor.path else {
            return RevealResult(opened: false, message: "No repository file is registered for \(anchor.symbol).")
        }
        guard let session else {
            return RevealResult(opened: false, message: "Not connected to \(macName).")
        }
        do {
            return try await session.reveal(RevealRequest(projectID: config.projectID, path: path, line: anchor.line))
        } catch {
            dropSession()
            connectIfNeeded()
            return RevealResult(opened: false, message: "Couldn't reach \(macName): \(error)")
        }
    }
}

struct SessionSender: ReportDelivering {
    let session: ReceiverSession

    func deliver(report: DebugReport, parts: [(name: String, data: Data)]) async throws -> ReportAck {
        try await session.sendReport(report, parts: parts)
    }
}

@MainActor
enum DeviceMetadata {
    static func current() -> DeviceInfo {
        var sys = utsname()
        uname(&sys)
        var model = withUnsafeBytes(of: &sys.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        #if targetEnvironment(simulator)
        let isSimulator = true
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { model = sim }
        #else
        let isSimulator = false
        #endif
        let idiom: String
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: idiom = "phone"
        case .pad: idiom = "pad"
        case .mac: idiom = "mac"
        default: idiom = "other"
        }
        return DeviceInfo(model: model, systemName: UIDevice.current.systemName, systemVersion: UIDevice.current.systemVersion, isSimulator: isSimulator, interfaceIdiom: idiom)
    }

    static func app() -> AppInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        return AppInfo(
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            name: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? "App",
            version: (info["CFBundleShortVersionString"] as? String) ?? "?",
            build: (info["CFBundleVersion"] as? String) ?? "?"
        )
    }
}
#endif
