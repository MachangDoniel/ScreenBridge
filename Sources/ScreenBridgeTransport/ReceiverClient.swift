#if !SCREENBRIDGE_STRIPPED
import Foundation
import Network
import ScreenBridgeProtocol

/// Finds the Bonjour service of one specific receiver.
///
/// Every ScreenBridge Mac on the network advertises `_screenbridge._tcp`; only the
/// one whose TXT `rid` equals the build-configured receiver ID is considered.
public final class ReceiverBrowser: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case searching
        case found
        case failed(String)
        /// iOS Local Network permission denied, or the Bonjour type is missing from Info.plist.
        case permissionDenied(String)
    }

    private let receiverID: String
    private let serviceType: String
    private let queue = DispatchQueue(label: "ScreenBridge.ReceiverBrowser")
    private var browser: NWBrowser?
    private var endpoints: [NWEndpoint] = []

    public init(receiverID: String, serviceType: String = WireProtocol.serviceType) {
        self.receiverID = receiverID
        self.serviceType = serviceType
    }

    /// Pure matching rule, exposed for tests.
    public static func matches(txt: [String: String], receiverID: String) -> Bool {
        guard let rid = txt[WireProtocol.txtReceiverIDKey] else { return false }
        if let v = txt[WireProtocol.txtVersionKey], let n = Int(v), n != WireProtocol.version { return false }
        return rid == receiverID
    }

    public func start(onChange: @escaping @Sendable ([NWEndpoint], State) -> Void) {
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: params)
        let rid = receiverID
        b.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let e):
                onChange([], Self.state(for: e))
            case .waiting(let e):
                onChange(self.endpoints, Self.state(for: e))
            case .ready:
                onChange(self.endpoints, self.endpoints.isEmpty ? .searching : .found)
            default: break
            }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let matching = results.compactMap { r -> NWEndpoint? in
                guard case .bonjour(let record) = r.metadata else { return nil }
                return Self.matches(txt: record.dictionary, receiverID: rid) ? r.endpoint : nil
            }
            self.endpoints = matching
            onChange(matching, matching.isEmpty ? .searching : .found)
        }
        browser = b
        b.start(queue: queue)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }

    private static func state(for error: NWError) -> State {
        if case .dns(let code) = error, code == -65570 /* kDNSServiceErr_PolicyDenied */ {
            return .permissionDenied("Local Network access is off for this app, or NSBonjourServices lacks \(WireProtocol.serviceType). Enable it in Settings › Privacy & Security › Local Network.")
        }
        return .failed("\(error)")
    }
}

/// An authenticated session with the receiver: TLS-PSK handshake plus hello exchange.
/// Requests are serialized; one request is in flight at a time.
public actor ReceiverSession {
    public let receiverName: String
    private let connection: FramedConnection

    private init(connection: FramedConnection, receiverName: String) {
        self.connection = connection
        self.receiverName = receiverName
    }

    public static func connect(to endpoint: NWEndpoint, config: ConnectionConfig, hello: Hello, timeout: TimeInterval = 10) async throws -> ReceiverSession {
        guard let key = config.psk, key.count >= 16 else {
            throw TransportError.notConfigured("The connection configuration has no usable key.")
        }
        let params = TLSPSK.clientParameters(.init(identity: config.credentialID, key: key))
        let conn = FramedConnection(connection: NWConnection(to: endpoint, using: params))
        do {
            try await conn.start(timeout: timeout)
            try await conn.send(Frame(envelope: .hello(hello)))
            let reply = try await conn.receive(timeout: timeout)
            guard reply.envelope.type == .helloAck, let ack = reply.envelope.helloAck else {
                if let e = reply.envelope.error { throw TransportError.remoteError(code: e.code, message: e.message) }
                throw TransportError.unexpectedMessage(reply.envelope.type.rawValue)
            }
            guard ack.receiverID == config.receiverID else {
                throw TransportError.wrongReceiver(expected: config.receiverID, actual: ack.receiverID)
            }
            guard ack.accepted else { throw TransportError.receiverRejected(ack.reason ?? "no reason given") }
            return ReceiverSession(connection: conn, receiverName: ack.receiverName)
        } catch {
            conn.cancel()
            throw error
        }
    }

    public func sendReport(_ report: DebugReport, parts: [(name: String, data: Data)], timeout: TimeInterval = 60) async throws -> ReportAck {
        try await connection.send(.report(report, parts: parts))
        let reply = try await connection.receive(timeout: timeout)
        switch reply.envelope.type {
        case .reportAck:
            guard let ack = reply.envelope.reportAck else { throw TransportError.unexpectedMessage("empty ack") }
            guard ack.reportID == report.id else { throw TransportError.unexpectedMessage("ack for \(ack.reportID), expected \(report.id)") }
            return ack
        case .error:
            let e = reply.envelope.error
            throw TransportError.remoteError(code: e?.code ?? "unknown", message: e?.message ?? "Receiver error")
        default:
            throw TransportError.unexpectedMessage(reply.envelope.type.rawValue)
        }
    }

    public func reveal(_ request: RevealRequest, timeout: TimeInterval = 15) async throws -> RevealResult {
        try await connection.send(Frame(envelope: .reveal(request)))
        let reply = try await connection.receive(timeout: timeout)
        if let r = reply.envelope.revealResult { return r }
        if let e = reply.envelope.error { throw TransportError.remoteError(code: e.code, message: e.message) }
        throw TransportError.unexpectedMessage(reply.envelope.type.rawValue)
    }

    public func close() {
        connection.cancel()
    }
}
#endif
