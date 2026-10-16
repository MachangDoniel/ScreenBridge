#if !SCREENBRIDGE_STRIPPED
import Foundation

public enum ClaudeDestination: String, Codable, Sendable, CaseIterable, Identifiable {
    case desktop, code, browser, inbox, reference
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .desktop: return "Claude Desktop"
        case .code: return "Claude Code"
        case .browser: return "Claude in browser"
        case .inbox: return "Mac inbox only"
        case .reference: return "Paste into focused AI tool"
        }
    }
}

/// Applied before encoding so excluded evidence never enters the outbox or transport.
public struct ReportEvidenceOptions: Sendable {
    public var logs: Bool
    public var viewDetails: Bool
    public var source: Bool
    public var screenshots: Bool

    public init(logs: Bool = false, viewDetails: Bool = true, source: Bool = true, screenshots: Bool = true) {
        self.logs = logs
        self.viewDetails = viewDetails
        self.source = source
        self.screenshots = screenshots
    }

    public func applying(to input: DebugReport) -> DebugReport {
        var report = input
        if !logs { report.logs = nil }
        if !viewDetails { report.selection = nil; report.screen = nil }
        if !source { report.sourceAnchors = [] }
        if !screenshots {
            report.images = []
            report.annotations = []
            report.selectedRegion = nil
        }
        return report
    }
}
#endif
