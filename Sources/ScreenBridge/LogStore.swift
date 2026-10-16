#if SCREENBRIDGE_ENABLED
import Foundation
import ScreenBridgeProtocol

/// Thread-safe holder for the sanitized app log ring buffer.
final class LogStore: @unchecked Sendable {
    static let shared = LogStore()

    private let lock = NSLock()
    private var buffer = LogRingBuffer(capacity: 200)

    func append(level: String, category: String, message: String) {
        lock.lock()
        buffer.append(level: LogSanitizer.sanitize(level), category: LogSanitizer.sanitize(category), message: message)
        let entry = buffer.entries.last
        lock.unlock()
        if let entry {
            print("[ScreenBridge][\(entry.level)][\(entry.category)] \(entry.message)")
        }
    }

    func recent(limit: Int = 100) -> [LogEntry] {
        lock.lock(); defer { lock.unlock() }
        return Array(buffer.entries.suffix(limit))
    }
}
#endif
