#if !SCREENBRIDGE_STRIPPED
import Foundation
import ScreenBridgeProtocol

/// Bounded exponential backoff.
public struct RetryPolicy: Sendable, Equatable {
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    /// Reports older than this are dropped instead of retried.
    public var maxAge: TimeInterval

    public init(baseDelay: TimeInterval = 2, maxDelay: TimeInterval = 300, maxAge: TimeInterval = 7 * 24 * 3600) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.maxAge = maxAge
    }

    /// Delay before the next attempt after `failedAttempts` consecutive failures (≥ 1).
    public func delay(afterFailedAttempts failedAttempts: Int) -> TimeInterval {
        let exponent = min(max(failedAttempts - 1, 0), 30)
        return min(maxDelay, baseDelay * pow(2, Double(exponent)))
    }
}

public struct OutboxItem: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case queued
        case failed
    }

    public var reportID: String
    public var queuedAt: Date
    public var attempts: Int
    public var nextAttemptAt: Date
    public var lastError: String?
    public var status: Status
    public var partNames: [String]
}

public enum OutboxError: Error, CustomStringConvertible {
    case invalidReportID(String)
    case missing(String)

    public var description: String {
        switch self {
        case .invalidReportID(let id): return "Invalid report ID \(id)."
        case .missing(let id): return "Report \(id) is not in the outbox."
        }
    }
}

/// File-backed queue of reports awaiting acknowledgment.
///
/// Layout: `<root>/<reportID>/{item.json, report.json, <part files>}`. Enqueueing the
/// same report ID twice is a no-op, so retries never create duplicates locally.
public final class OutboxStore: @unchecked Sendable {
    public let directory: URL
    public let capacity: Int
    private let lock = NSLock()
    private let fm = FileManager.default

    public init(directory: URL, capacity: Int = 20) {
        self.directory = directory
        self.capacity = max(1, capacity)
    }

    @discardableResult
    public func enqueue(report: DebugReport, parts: [(name: String, data: Data)], now: Date = Date()) throws -> OutboxItem {
        guard ReportID.isValid(report.id) else { throw OutboxError.invalidReportID(report.id) }
        lock.lock(); defer { lock.unlock() }
        if let existing = try? loadItemLocked(report.id) { return existing }

        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let tmp = directory.appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let item = OutboxItem(reportID: report.id, queuedAt: now, attempts: 0, nextAttemptAt: now, lastError: nil, status: .queued, partNames: parts.map(\.name))
        do {
            try ReportCoding.encode(report).write(to: tmp.appendingPathComponent("report.json"), options: .atomic)
            for p in parts {
                guard Self.isSafePartName(p.name) else { throw OutboxError.invalidReportID(p.name) }
                try p.data.write(to: tmp.appendingPathComponent(p.name), options: .atomic)
            }
            try ReportCoding.encoder().encode(item).write(to: tmp.appendingPathComponent("item.json"), options: .atomic)
            try fm.moveItem(at: tmp, to: directory.appendingPathComponent(report.id, isDirectory: true))
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        trimLocked()
        return item
    }

    public func items() -> [OutboxItem] {
        lock.lock(); defer { lock.unlock() }
        return itemsLocked()
    }

    public func dueItems(now: Date = Date()) -> [OutboxItem] {
        items().filter { $0.nextAttemptAt <= now }
    }

    public func load(_ reportID: String) throws -> (report: DebugReport, parts: [(name: String, data: Data)]) {
        guard ReportID.isValid(reportID) else { throw OutboxError.invalidReportID(reportID) }
        lock.lock(); defer { lock.unlock() }
        let dir = directory.appendingPathComponent(reportID, isDirectory: true)
        let item = try loadItemLocked(reportID)
        let report = try ReportCoding.decode(Data(contentsOf: dir.appendingPathComponent("report.json")))
        let parts = try item.partNames.map { ($0, try Data(contentsOf: dir.appendingPathComponent($0))) }
        return (report, parts)
    }

    public func recordFailure(_ reportID: String, error: String, policy: RetryPolicy, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard var item = try? loadItemLocked(reportID) else { return }
        item.attempts += 1
        item.lastError = error
        item.status = .failed
        item.nextAttemptAt = now.addingTimeInterval(policy.delay(afterFailedAttempts: item.attempts))
        try? saveItemLocked(item)
    }

    /// Makes every queued item due now (e.g. after the receiver becomes reachable).
    public func makeAllDue(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        for var item in itemsLocked() {
            item.nextAttemptAt = now
            try? saveItemLocked(item)
        }
    }

    public func remove(_ reportID: String) {
        guard ReportID.isValid(reportID) else { return }
        lock.lock(); defer { lock.unlock() }
        try? fm.removeItem(at: directory.appendingPathComponent(reportID, isDirectory: true))
    }

    // MARK: - Locked helpers

    static func isSafePartName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && !name.hasPrefix(".") && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
            && name != "item.json" && name != "report.json"
    }

    private func loadItemLocked(_ id: String) throws -> OutboxItem {
        let url = directory.appendingPathComponent(id, isDirectory: true).appendingPathComponent("item.json")
        guard fm.fileExists(atPath: url.path) else { throw OutboxError.missing(id) }
        return try ReportCoding.decoder().decode(OutboxItem.self, from: Data(contentsOf: url))
    }

    private func saveItemLocked(_ item: OutboxItem) throws {
        let url = directory.appendingPathComponent(item.reportID, isDirectory: true).appendingPathComponent("item.json")
        try ReportCoding.encoder().encode(item).write(to: url, options: .atomic)
    }

    private func itemsLocked() -> [OutboxItem] {
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.filter(ReportID.isValid).compactMap { try? loadItemLocked($0) }.sorted { $0.queuedAt < $1.queuedAt }
    }

    /// Drops the oldest reports beyond capacity so the outbox stays bounded.
    private func trimLocked() {
        let all = itemsLocked()
        guard all.count > capacity else { return }
        for item in all.prefix(all.count - capacity) {
            try? fm.removeItem(at: directory.appendingPathComponent(item.reportID, isDirectory: true))
        }
    }
}

public protocol ReportDelivering: Sendable {
    func deliver(report: DebugReport, parts: [(name: String, data: Data)]) async throws -> ReportAck
}

public enum DeliveryOutcome: Sendable, Equatable {
    case acknowledged(reportID: String, duplicate: Bool)
    case failed(reportID: String, error: String, nextAttemptAt: Date?)
    case expired(reportID: String)
}

/// Sends due outbox items one at a time and removes them only after a matching ack.
public actor OutboxProcessor {
    private let store: OutboxStore
    private let policy: RetryPolicy
    private var isProcessing = false

    public init(store: OutboxStore, policy: RetryPolicy = RetryPolicy()) {
        self.store = store
        self.policy = policy
    }

    public func processDue(using sender: ReportDelivering, now: Date = Date()) async -> [DeliveryOutcome] {
        guard !isProcessing else { return [] }
        isProcessing = true
        defer { isProcessing = false }
        var outcomes: [DeliveryOutcome] = []
        for item in store.dueItems(now: now) {
            if now.timeIntervalSince(item.queuedAt) > policy.maxAge {
                store.remove(item.reportID)
                outcomes.append(.expired(reportID: item.reportID))
                continue
            }
            outcomes.append(await deliver(item.reportID, using: sender, now: now))
        }
        return outcomes
    }

    public func deliver(_ reportID: String, using sender: ReportDelivering, now: Date = Date()) async -> DeliveryOutcome {
        do {
            var (report, parts) = try store.load(reportID)
            let attempt = (store.items().first { $0.reportID == reportID }?.attempts ?? 0) + 1
            report.transfer = TransferMetadata(queuedAt: report.transfer?.queuedAt ?? now, attempt: attempt, sentAt: now)
            let ack = try await sender.deliver(report: report, parts: parts)
            guard ack.reportID == reportID else {
                throw TransportError.unexpectedMessage("ack for \(ack.reportID)")
            }
            store.remove(reportID)
            return .acknowledged(reportID: reportID, duplicate: ack.duplicate)
        } catch {
            store.recordFailure(reportID, error: String(describing: error), policy: policy, now: now)
            let next = store.items().first { $0.reportID == reportID }?.nextAttemptAt
            return .failed(reportID: reportID, error: String(describing: error), nextAttemptAt: next)
        }
    }
}
#endif
