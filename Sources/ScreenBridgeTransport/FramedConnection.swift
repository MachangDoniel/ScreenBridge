#if !SCREENBRIDGE_STRIPPED
import Foundation
import Network
import ScreenBridgeProtocol

public enum TransportError: Error, Equatable, CustomStringConvertible {
    case timedOut(String)
    case handshakeFailed(String)
    case connectionClosed
    case connectionFailed(String)
    case receiverRejected(String)
    case wrongReceiver(expected: String, actual: String)
    case unexpectedMessage(String)
    case remoteError(code: String, message: String)
    case notConfigured(String)

    public var description: String {
        switch self {
        case .timedOut(let what): return "Timed out \(what)."
        case .handshakeFailed(let s): return "Secure handshake failed: \(s)"
        case .connectionClosed: return "Connection closed."
        case .connectionFailed(let s): return "Connection failed: \(s)"
        case .receiverRejected(let s): return "The Mac rejected this app: \(s)"
        case .wrongReceiver(let e, let a): return "Connected to the wrong receiver (expected \(e), got \(a))."
        case .unexpectedMessage(let s): return "Unexpected message: \(s)"
        case .remoteError(let c, let m): return "\(m) [\(c)]"
        case .notConfigured(let s): return s
        }
    }

    /// True when retrying with the same credential cannot succeed.
    public var isAuthenticationFailure: Bool {
        switch self {
        case .handshakeFailed, .receiverRejected, .wrongReceiver: return true
        default: return false
        }
    }
}

/// Frame-oriented wrapper around `NWConnection`. All mutable state is confined to `queue`.
public final class FramedConnection: @unchecked Sendable {
    public let connection: NWConnection
    private let queue: DispatchQueue
    private var decoder = FrameDecoder()
    private var pendingFrames: [Frame] = []
    private var receiveWaiters: [(id: UUID, continuation: CheckedContinuation<Frame, Error>)] = []
    private var terminalError: Error?
    private var readLoopStarted = false

    public init(connection: NWConnection, label: String = "ScreenBridge.FramedConnection") {
        self.connection = connection
        self.queue = DispatchQueue(label: label)
    }

    public var endpointDescription: String { "\(connection.endpoint)" }

    /// Starts the connection and waits for the TLS handshake. A `.waiting` state is
    /// treated as failure: for TLS-PSK it almost always means a key mismatch.
    public func start(timeout: TimeInterval = 10) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            let finish: @Sendable (Result<Void, Error>) -> Void = { result in
                guard once.claim() else { return }
                cont.resume(with: result)
            }
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    finish(.success(()))
                    self.startReadLoop()
                case .waiting(let error):
                    finish(.failure(Self.classify(error)))
                    self.connection.cancel()
                case .failed(let error):
                    finish(.failure(Self.classify(error)))
                    self.fail(Self.classify(error))
                case .cancelled:
                    finish(.failure(TransportError.connectionClosed))
                    self.fail(TransportError.connectionClosed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard !once.isClaimed else { return }
                finish(.failure(TransportError.timedOut("connecting to the receiver")))
                self?.connection.cancel()
            }
        }
    }

    public func startServerSide() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.startReadLoop()
            case .failed(let e): self.fail(Self.classify(e))
            case .waiting(let e): self.fail(Self.classify(e)); self.connection.cancel()
            case .cancelled: self.fail(TransportError.connectionClosed)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    public func send(_ frame: Frame) async throws {
        let data = try FrameCodec.encode(frame)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: Self.classify(error)) } else { cont.resume() }
            })
        }
    }

    public func receive(timeout: TimeInterval = 30) async throws -> Frame {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Frame, Error>) in
            queue.async { [self] in
                if !pendingFrames.isEmpty {
                    cont.resume(returning: pendingFrames.removeFirst())
                } else if let terminalError {
                    cont.resume(throwing: terminalError)
                } else {
                    let id = UUID()
                    receiveWaiters.append((id, cont))
                    queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                        guard let self, let i = self.receiveWaiters.firstIndex(where: { $0.id == id }) else { return }
                        self.receiveWaiters.remove(at: i).continuation.resume(throwing: TransportError.timedOut("waiting for a reply"))
                    }
                }
            }
        }
    }

    public func cancel() {
        connection.cancel()
    }

    // MARK: - Private (queue-confined)

    private func startReadLoop() {
        guard !readLoopStarted else { return }
        readLoopStarted = true
        readNext()
    }

    private func readNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    let frames = try self.decoder.append(data)
                    for f in frames { self.deliver(f) }
                } catch {
                    self.fail(error)
                    self.connection.cancel()
                    return
                }
            }
            if let error {
                self.fail(Self.classify(error))
                return
            }
            if isComplete {
                self.fail(TransportError.connectionClosed)
                return
            }
            self.readNext()
        }
    }

    private func deliver(_ frame: Frame) {
        if !receiveWaiters.isEmpty {
            receiveWaiters.removeFirst().continuation.resume(returning: frame)
        } else {
            pendingFrames.append(frame)
        }
    }

    private func fail(_ error: Error) {
        guard terminalError == nil else { return }
        terminalError = error
        let waiters = receiveWaiters
        receiveWaiters.removeAll()
        for w in waiters { w.continuation.resume(throwing: error) }
    }

    static func classify(_ error: NWError) -> TransportError {
        switch error {
        case .tls(let status):
            return .handshakeFailed("TLS status \(status)")
        case .posix(let code):
            return .connectionFailed("POSIX \(code.rawValue) \(code)")
        case .dns(let code):
            return .connectionFailed("DNS \(code)")
        default:
            return .connectionFailed("\(error)")
        }
    }
}

/// Thread-safe one-shot flag.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }

    var isClaimed: Bool {
        lock.lock(); defer { lock.unlock() }
        return claimed
    }
}
#endif
