#if !SCREENBRIDGE_STRIPPED
import Foundation

/// Best-effort scrubbing for messages passed to `ScreenBridge.log`.
///
/// This is a safety net, not a guarantee: callers should still avoid logging secrets.
/// It removes common credential shapes, long digit runs (card, account and national ID
/// numbers), email addresses and long opaque tokens.
public enum LogSanitizer {
    public static let maxMessageLength = 500

    private static let rules: [(NSRegularExpression, String)] = {
        func re(_ p: String) -> NSRegularExpression {
            // Patterns are constants; a failure here is a programming error.
            try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
        }
        return [
            // Authorization headers / bearer tokens.
            (re(#"\b(bearer|basic)\s+[A-Za-z0-9\-._~+/]+=*"#), "$1 [REDACTED]"),
            // JWTs.
            (re(#"\beyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+"#), "[REDACTED-JWT]"),
            // key=value / key: value secrets, JSON-ish "key":"value" included.
            (re(#"("?\b(?:password|passwd|pwd|pin|otp|token|access_token|refresh_token|secret|api[_-]?key|authorization|cookie|session(?:id)?|nid|ssn)\b"?\s*[:=]\s*)("[^"]*"|[^\s,;&]+)"#), "$1[REDACTED]"),
            // Emails.
            (re(#"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#), "[REDACTED-EMAIL]"),
            // 9+ digits, optionally separated by spaces or dashes (cards, accounts, IDs, phones).
            (re(#"(?<![A-Za-z0-9])\d(?:[ \-]?\d){8,}(?![A-Za-z0-9])"#), "[REDACTED-NUMBER]"),
            // Long opaque tokens (hex/base64-ish, 32+ chars).
            (re(#"\b[A-Za-z0-9+/_\-]{32,}={0,2}"#), "[REDACTED-TOKEN]"),
        ]
    }()

    public static func sanitize(_ message: String) -> String {
        var s = message
        for (regex, template) in rules {
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: template)
        }
        if s.count > maxMessageLength {
            s = String(s.prefix(maxMessageLength)) + "…"
        }
        return s
    }
}

/// Fixed-capacity ring buffer of sanitized log entries.
public struct LogRingBuffer: Sendable {
    public let capacity: Int
    private var storage: [LogEntry] = []

    public init(capacity: Int = 200) {
        self.capacity = max(1, capacity)
    }

    public mutating func append(level: String, category: String, message: String, at date: Date = Date()) {
        let entry = LogEntry(timestamp: date, level: level, category: String(category.prefix(40)), message: LogSanitizer.sanitize(message))
        storage.append(entry)
        if storage.count > capacity { storage.removeFirst(storage.count - capacity) }
    }

    public var entries: [LogEntry] { storage }
    public var count: Int { storage.count }
}
#endif
