import Foundation
import Network
import Testing
@testable import ScreenBridgeProtocol
@testable import ScreenBridgeTransport

private func makeReport(id: String = ReportID.make()) -> DebugReport {
    DebugReport(
        id: id, description: "test",
        screenshot: ScreenshotGeometry(pixelWidth: 10, pixelHeight: 10, scale: 1, interfaceOrientation: "portrait"),
        images: [], annotations: [], redactionApplied: false, selection: nil, screen: nil, sourceAnchors: [],
        app: AppInfo(bundleIdentifier: "dev.test", name: "T", version: "1", build: "1"),
        device: DeviceInfo(model: "x", systemName: "iOS", systemVersion: "27", isSimulator: true, interfaceIdiom: "phone"),
        build: .unconfigured, logs: nil
    )
}

/// Thread-safe mutable credential set + received-report log for the fake receiver.
final class FakeReceiverState: @unchecked Sendable {
    private let lock = NSLock()
    private var _credentials: [TLSPSK.Credential]
    private var _received: [String] = []

    init(credentials: [TLSPSK.Credential]) { _credentials = credentials }

    var credentials: [TLSPSK.Credential] {
        get { lock.lock(); defer { lock.unlock() }; return _credentials }
        set { lock.lock(); _credentials = newValue; lock.unlock() }
    }

    /// Returns true if this report ID was already stored.
    func store(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if _received.contains(id) { return true }
        _received.append(id)
        return false
    }

    var received: [String] { lock.lock(); defer { lock.unlock() }; return _received }
}

private func makeListener(receiverID: String, state: FakeReceiverState, ackReceiverID: String? = nil) -> ReceiverListener {
    ReceiverListener(receiverID: receiverID, receiverName: "Test Mac", advertise: false, handlers: ReceiverHandlers(
        credentials: { state.credentials },
        hello: { hello, _ in
            let known = state.credentials.contains { $0.identity == hello.credentialID }
            let accepted = known && hello.receiverID == receiverID
            return HelloAck(accepted: accepted, receiverID: ackReceiverID ?? receiverID, receiverName: "Test Mac", reason: accepted ? nil : "unknown credential or receiver")
        },
        report: { report, parts, _ in
            let duplicate = state.store(report.id)
            _ = parts
            return .reportAck(ReportAck(reportID: report.id, duplicate: duplicate, receivedAt: Date()))
        },
        reveal: { req, _ in RevealResult(opened: false, message: "would open \(req.path)") }
    ))
}

private func config(receiverID: String, credential: TLSPSK.Credential) -> ConnectionConfig {
    ConnectionConfig(receiverID: receiverID, receiverName: "Test Mac", credentialID: credential.identity, pskBase64: credential.key.base64EncodedString(), projectID: "p1", projectName: "Proj", projectRoot: "/tmp/p", appBundleIdentifier: "dev.test", build: .unconfigured)
}

private func hello(_ c: ConnectionConfig) -> Hello {
    Hello(credentialID: c.credentialID, receiverID: c.receiverID, projectID: c.projectID, appBundleIdentifier: "dev.test", appName: "T", buildID: nil, deviceModel: "x", systemVersion: "27", isSimulator: true)
}

private func endpoint(_ port: UInt16) -> NWEndpoint {
    .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
}

@Suite(.serialized) struct AuthenticatedTransportTests {
    let goodCred = TLSPSK.Credential(identity: "cred-good", key: TLSPSK.randomKey())

    @Test func deliversReportAndDetectsDuplicate() async throws {
        let state = FakeReceiverState(credentials: [goodCred, .init(identity: "other", key: TLSPSK.randomKey())])
        let listener = makeListener(receiverID: "R1", state: state)
        try listener.start()
        defer { listener.stop() }
        let port = try await listener.waitUntilReady()

        let cfg = config(receiverID: "R1", credential: goodCred)
        let session = try await ReceiverSession.connect(to: endpoint(port), config: cfg, hello: hello(cfg))
        #expect(await session.receiverName == "Test Mac")
        let report = makeReport()
        let ack1 = try await session.sendReport(report, parts: [("annotated.png", Data(repeating: 7, count: 300_000))])
        #expect(ack1.reportID == report.id && !ack1.duplicate)
        let ack2 = try await session.sendReport(report, parts: [])
        #expect(ack2.duplicate)
        let reveal = try await session.reveal(RevealRequest(projectID: "p1", path: "A.swift", line: 3))
        #expect(reveal.message.contains("A.swift"))
        await session.close()
        #expect(state.received == [report.id])
    }

    @Test func wrongKeyFailsHandshake() async throws {
        let state = FakeReceiverState(credentials: [goodCred])
        let listener = makeListener(receiverID: "R1", state: state)
        try listener.start()
        defer { listener.stop() }
        let port = try await listener.waitUntilReady()

        let forged = TLSPSK.Credential(identity: goodCred.identity, key: TLSPSK.randomKey())
        let cfg = config(receiverID: "R1", credential: forged)
        await #expect(throws: TransportError.self) {
            _ = try await ReceiverSession.connect(to: endpoint(port), config: cfg, hello: hello(cfg), timeout: 5)
        }
        #expect(state.received.isEmpty)
    }

    @Test func revokedCredentialIsRejectedAfterRestart() async throws {
        let state = FakeReceiverState(credentials: [goodCred])
        let listener = makeListener(receiverID: "R1", state: state)
        try listener.start()
        defer { listener.stop() }
        _ = try await listener.waitUntilReady()

        state.credentials = [] // revoke
        try listener.restart()
        let port = try await listener.waitUntilReady()
        let cfg = config(receiverID: "R1", credential: goodCred)
        do {
            _ = try await ReceiverSession.connect(to: endpoint(port), config: cfg, hello: hello(cfg), timeout: 5)
            Issue.record("revoked credential connected")
        } catch let e as TransportError {
            #expect(e.isAuthenticationFailure || e == .connectionClosed || { if case .timedOut = e { return true }; return false }())
        }
    }

    @Test func receiverRejectsHelloForAnotherReceiver() async throws {
        let state = FakeReceiverState(credentials: [goodCred])
        let listener = makeListener(receiverID: "R1", state: state)
        try listener.start()
        defer { listener.stop() }
        let port = try await listener.waitUntilReady()

        // The app was built for receiver R2 but holds a key R1 accepts (e.g. copied config).
        let cfg = config(receiverID: "R2", credential: goodCred)
        await #expect(throws: TransportError.self) {
            _ = try await ReceiverSession.connect(to: endpoint(port), config: cfg, hello: hello(cfg), timeout: 5)
        }
    }

    @Test func clientRejectsAckFromUnexpectedReceiver() async throws {
        let state = FakeReceiverState(credentials: [goodCred])
        let listener = makeListener(receiverID: "R1", state: state, ackReceiverID: "IMPOSTOR")
        try listener.start()
        defer { listener.stop() }
        let port = try await listener.waitUntilReady()
        let cfg = config(receiverID: "R1", credential: goodCred)
        await #expect(throws: TransportError.wrongReceiver(expected: "R1", actual: "IMPOSTOR")) {
            _ = try await ReceiverSession.connect(to: endpoint(port), config: cfg, hello: hello(cfg), timeout: 5)
        }
    }

    @Test func bonjourMatchingRequiresExactReceiverID() {
        #expect(ReceiverBrowser.matches(txt: ["rid": "R1", "v": "1"], receiverID: "R1"))
        #expect(!ReceiverBrowser.matches(txt: ["rid": "R2", "v": "1"], receiverID: "R1"))
        #expect(!ReceiverBrowser.matches(txt: [:], receiverID: "R1"))
        #expect(!ReceiverBrowser.matches(txt: ["rid": "R1", "v": "99"], receiverID: "R1"))
    }
}

/// Scriptable sender for outbox tests.
final class FakeSender: ReportDelivering, @unchecked Sendable {
    enum Behavior { case fail, ack, ackDuplicate, ackWrongID }
    private let lock = NSLock()
    var behaviors: [Behavior]
    private(set) var deliveredIDs: [String] = []

    init(_ behaviors: [Behavior]) { self.behaviors = behaviors }

    func deliver(report: DebugReport, parts: [(name: String, data: Data)]) async throws -> ReportAck {
        let b: Behavior = lock.withLock {
            deliveredIDs.append(report.id)
            return behaviors.isEmpty ? .ack : behaviors.removeFirst()
        }
        switch b {
        case .fail: throw TransportError.connectionFailed("offline")
        case .ack: return ReportAck(reportID: report.id, duplicate: false, receivedAt: Date())
        case .ackDuplicate: return ReportAck(reportID: report.id, duplicate: true, receivedAt: Date())
        case .ackWrongID: return ReportAck(reportID: "SB-000000000000", duplicate: false, receivedAt: Date())
        }
    }
}

@Suite struct OutboxTests {
    func tempStore(capacity: Int = 20) -> OutboxStore {
        OutboxStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("sb-outbox-\(UUID().uuidString)"), capacity: capacity)
    }

    @Test func backoffIsExponentialAndBounded() {
        let p = RetryPolicy(baseDelay: 2, maxDelay: 300)
        #expect((1...10).map { p.delay(afterFailedAttempts: $0) } == [2, 4, 8, 16, 32, 64, 128, 256, 300, 300])
        #expect(p.delay(afterFailedAttempts: 10_000) == 300)
    }

    @Test func retriesUntilAcknowledgedThenRemoves() async throws {
        let store = tempStore()
        let report = makeReport()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        try store.enqueue(report: report, parts: [("annotated.png", Data([1, 2]))], now: t0)
        let processor = OutboxProcessor(store: store, policy: RetryPolicy(baseDelay: 2, maxDelay: 300))
        let sender = FakeSender([.fail, .fail, .ack])

        var outcomes = await processor.processDue(using: sender, now: t0)
        guard case .failed(_, _, let next1?) = outcomes.first else { Issue.record("expected failure"); return }
        #expect(next1 == t0.addingTimeInterval(2))

        // Not due yet: nothing is attempted.
        outcomes = await processor.processDue(using: sender, now: t0.addingTimeInterval(1))
        #expect(outcomes.isEmpty)

        outcomes = await processor.processDue(using: sender, now: next1)
        guard case .failed(_, _, let next2?) = outcomes.first else { Issue.record("expected failure"); return }
        #expect(next2 == next1.addingTimeInterval(4))

        outcomes = await processor.processDue(using: sender, now: next2)
        #expect(outcomes == [.acknowledged(reportID: report.id, duplicate: false)])
        #expect(store.items().isEmpty)
        #expect(sender.deliveredIDs == [report.id, report.id, report.id])
    }

    @Test func duplicateAckStillClearsAndWrongAckDoesNot() async throws {
        let store = tempStore()
        let a = makeReport(), b = makeReport()
        let t0 = Date()
        try store.enqueue(report: a, parts: [], now: t0)
        try store.enqueue(report: b, parts: [], now: t0.addingTimeInterval(1))
        let processor = OutboxProcessor(store: store)
        let outcomes = await processor.processDue(using: FakeSender([.ackDuplicate, .ackWrongID]), now: t0.addingTimeInterval(2))
        #expect(outcomes.first == .acknowledged(reportID: a.id, duplicate: true))
        if case .failed(let id, _, _) = outcomes.last { #expect(id == b.id) } else { Issue.record("wrong ack must not clear") }
        #expect(store.items().map(\.reportID) == [b.id])
    }

    @Test func enqueueIsIdempotentAndBounded() throws {
        let store = tempStore(capacity: 3)
        let r = makeReport()
        try store.enqueue(report: r, parts: [])
        try store.enqueue(report: r, parts: [])
        #expect(store.items().count == 1)
        var ids = [r.id]
        for i in 0..<4 {
            let x = makeReport()
            ids.append(x.id)
            try store.enqueue(report: x, parts: [], now: Date().addingTimeInterval(Double(i + 1)))
        }
        #expect(store.items().map(\.reportID) == Array(ids.suffix(3)))
    }

    @Test func expiresStaleReports() async throws {
        let store = tempStore()
        let r = makeReport()
        let t0 = Date(timeIntervalSince1970: 0)
        try store.enqueue(report: r, parts: [], now: t0)
        let processor = OutboxProcessor(store: store, policy: RetryPolicy(maxAge: 60))
        let outcomes = await processor.processDue(using: FakeSender([.ack]), now: t0.addingTimeInterval(120))
        #expect(outcomes == [.expired(reportID: r.id)])
    }
}
