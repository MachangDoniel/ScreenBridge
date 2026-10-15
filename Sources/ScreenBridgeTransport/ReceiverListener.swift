#if !SCREENBRIDGE_STRIPPED
import Foundation
import Network
import ScreenBridgeProtocol

/// Callbacks invoked by `ReceiverListener`. All run off the main thread.
public struct ReceiverHandlers: Sendable {
    public var credentials: @Sendable () -> [TLSPSK.Credential]
    public var hello: @Sendable (_ hello: Hello, _ connectionID: UUID) async -> HelloAck
    public var report: @Sendable (_ report: DebugReport, _ parts: [String: Data], _ connectionID: UUID) async -> WireEnvelope
    public var reveal: @Sendable (_ request: RevealRequest, _ connectionID: UUID) async -> RevealResult
    public var closed: @Sendable (_ connectionID: UUID) -> Void
    public var listenerState: @Sendable (_ state: ReceiverListener.Status) -> Void

    public init(
        credentials: @escaping @Sendable () -> [TLSPSK.Credential],
        hello: @escaping @Sendable (Hello, UUID) async -> HelloAck,
        report: @escaping @Sendable (DebugReport, [String: Data], UUID) async -> WireEnvelope,
        reveal: @escaping @Sendable (RevealRequest, UUID) async -> RevealResult,
        closed: @escaping @Sendable (UUID) -> Void = { _ in },
        listenerState: @escaping @Sendable (ReceiverListener.Status) -> Void = { _ in }
    ) {
        self.credentials = credentials
        self.hello = hello
        self.report = report
        self.reveal = reveal
        self.closed = closed
        self.listenerState = listenerState
    }
}

/// TLS-PSK listener advertised over Bonjour with only the public receiver ID in TXT.
///
/// Credential changes (new project, revocation) require `restart()`, which rebuilds the
/// TLS key set and drops existing connections; clients reconnect automatically.
public final class ReceiverListener: @unchecked Sendable {
    public enum Status: Sendable, Equatable {
        case stopped
        case starting
        case ready(port: UInt16)
        case failed(String)
    }

    public let receiverID: String
    public let receiverName: String
    private let handlers: ReceiverHandlers
    private let advertise: Bool
    private let queue = DispatchQueue(label: "ScreenBridge.ReceiverListener")
    private var listener: NWListener?
    private var connections: [UUID: FramedConnection] = [:]
    private var requestedPort: NWEndpoint.Port = .any

    public init(receiverID: String, receiverName: String, advertise: Bool = true, handlers: ReceiverHandlers) {
        self.receiverID = receiverID
        self.receiverName = receiverName
        self.advertise = advertise
        self.handlers = handlers
    }

    public var port: UInt16? { queue.sync { listener?.port?.rawValue } }

    public func start(port: NWEndpoint.Port = .any) throws {
        try queue.sync {
            requestedPort = port
            try startLocked()
        }
    }

    public func restart() throws {
        try queue.sync {
            stopLocked()
            try startLocked()
        }
    }

    public func stop() {
        queue.sync { stopLocked() }
        handlers.listenerState(.stopped)
    }

    /// Waits until the listener reports a port (useful for tests).
    public func waitUntilReady(timeout: TimeInterval = 5) async throws -> UInt16 {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let p = port, p != 0 { return p }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw TransportError.timedOut("starting the listener")
    }

    private func startLocked() throws {
        let params = TLSPSK.serverParameters(handlers.credentials())
        let l = try NWListener(using: params, on: requestedPort)
        if advertise {
            var txt = NWTXTRecord()
            txt[WireProtocol.txtReceiverIDKey] = receiverID
            txt[WireProtocol.txtVersionKey] = String(WireProtocol.version)
            let shortID = String(receiverID.prefix(8))
            l.service = NWListener.Service(name: "ScreenBridge \(shortID)", type: WireProtocol.serviceType, domain: nil, txtRecord: txt)
        }
        let handlers = self.handlers
        l.stateUpdateHandler = { [weak l] state in
            switch state {
            case .ready: handlers.listenerState(.ready(port: l?.port?.rawValue ?? 0))
            case .failed(let e): handlers.listenerState(.failed("\(e)"))
            case .setup, .waiting: handlers.listenerState(.starting)
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] nw in self?.accept(nw) }
        listener = l
        l.start(queue: queue)
    }

    private func stopLocked() {
        listener?.cancel()
        listener = nil
        for (_, c) in connections { c.cancel() }
        connections.removeAll()
    }

    // Called on `queue`.
    private func accept(_ nw: NWConnection) {
        let id = UUID()
        let conn = FramedConnection(connection: nw, label: "ScreenBridge.Server.\(id.uuidString.prefix(8))")
        connections[id] = conn
        conn.startServerSide()
        let handlers = self.handlers
        let receiverID = self.receiverID
        let receiverName = self.receiverName
        let queue = self.queue
        Task { [weak self] in
            await Self.serve(conn, id: id, handlers: handlers, receiverID: receiverID, receiverName: receiverName)
            conn.cancel()
            queue.async { [weak self] in self?.connections[id] = nil }
            handlers.closed(id)
        }
    }

    private static func serve(_ conn: FramedConnection, id: UUID, handlers: ReceiverHandlers, receiverID: String, receiverName: String) async {
        // The first frame must be a hello; idle sessions are closed after 10 minutes.
        guard let first = try? await conn.receive(timeout: 15), first.envelope.type == .hello, let hello = first.envelope.hello else {
            try? await conn.send(Frame(envelope: .error(code: "expected-hello", message: "Send hello first.")))
            return
        }
        guard first.envelope.protocolVersion == WireProtocol.version else {
            try? await conn.send(Frame(envelope: .helloAck(HelloAck(accepted: false, receiverID: receiverID, receiverName: receiverName, reason: "Unsupported protocol version \(first.envelope.protocolVersion)."))))
            return
        }
        let ack = await handlers.hello(hello, id)
        try? await conn.send(Frame(envelope: .helloAck(ack)))
        guard ack.accepted else { return }

        while true {
            guard let frame = try? await conn.receive(timeout: 600) else { return }
            switch frame.envelope.type {
            case .report:
                guard let report = frame.envelope.report else {
                    try? await conn.send(Frame(envelope: .error(code: "malformed", message: "Report frame has no report.")))
                    continue
                }
                let parts: [String: Data]
                do { parts = try frame.splitParts() } catch {
                    try? await conn.send(Frame(envelope: .error(code: "malformed-parts", message: "\(error)")))
                    continue
                }
                let reply = await handlers.report(report, parts, id)
                try? await conn.send(Frame(envelope: reply))
            case .revealSource:
                guard let req = frame.envelope.reveal else { continue }
                let result = await handlers.reveal(req, id)
                try? await conn.send(Frame(envelope: .revealResult(result)))
            default:
                try? await conn.send(Frame(envelope: .error(code: "unexpected", message: "Unexpected \(frame.envelope.type.rawValue).")))
            }
        }
    }
}
#endif
