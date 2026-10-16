import Foundation
import Testing
@testable import ScreenBridgeMacCore
import ScreenBridgeProtocol

@Suite struct ClaudeHandoffTests {
    @Test func blankCodeChatDoesNotIncludePromptText() throws {
        let url = try #require(ClaudeHandoff.url(destination: .code, prompt: "", projectRoot: "/tmp/App"))
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(!query.contains { $0.name == "q" })
        #expect(query.contains { $0.name == "folder" && $0.value == "/tmp/App" })
    }

    @Test func codeReferenceIsOnlyAShortFileLink() {
        let url = URL(fileURLWithPath: "/tmp/ScreenBridge Reports/SB-123456789ABC/report.md")
        let prompt = ClaudeHandoff.request(for: "SB-123456789ABC", reportURL: url)
        #expect(prompt == "ScreenBridge context: [SB-123456789ABC](\(url.absoluteString))")
        #expect(!prompt.contains("get_debug_report"))
        #expect(ClaudeHandoff.request(for: "SB-123456789ABC") == "ScreenBridge report SB-123456789ABC")
    }

    @Test func writtenRequestIsIncludedInPreparedPrompt() {
        let prompt = ClaudeHandoff.request(for: "SB-123456789ABC", description: "  Fix the clipped title  ")
        #expect(prompt.hasPrefix("Requested change:\nFix the clipped title\n\n"))
        #expect(prompt.contains("SB-123456789ABC"))
        #expect(!ClaudeHandoff.request(for: "SB-123456789ABC").contains("Requested change:"))
    }

    @Test func desktopPrefillsReviewablePromptWithEncodedCharacters() throws {
        let url = try #require(ClaudeHandoff.url(destination: .desktop, prompt: "Read SB & check #1 + 日本語", projectRoot: nil))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "claude")
        #expect(components.host == "claude.ai")
        #expect(components.path == "/new")
        #expect(components.queryItems?.first { $0.name == "q" }?.value == "Read SB & check #1 + 日本語")
    }

    @Test func codeUsesAuthoritativeProjectFolderAndInboxDoesNotOpenAnything() throws {
        let url = try #require(ClaudeHandoff.url(destination: .code, prompt: "Read report", projectRoot: "/Users/me/App Folder"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "code" && components.path == "/new")
        #expect(components.queryItems?.first { $0.name == "folder" }?.value == "/Users/me/App Folder")
        #expect(ClaudeHandoff.url(destination: .inbox, prompt: "ignored", projectRoot: nil) == nil)
        #expect(ClaudeHandoff.url(destination: .reference, prompt: "ignored", projectRoot: nil) == nil)
        #expect(ClaudeHandoff.url(destination: .browser, prompt: "local details", projectRoot: nil)?.absoluteString == "https://claude.ai/new")
    }

    @Test func browserExportContainsOnlyChosenEvidenceAndConfinesSources() throws {
        let home = SBHome(root: tempDir("handoff"))
        let repo = makeRepo()
        var (report, parts) = sampleReport(anchors: [
            SourceAnchor(symbol: "Profile", role: "view", path: "Sources/Profile.swift", line: 1, pathStatus: .repositoryRelative, evidence: .registered),
            SourceAnchor(symbol: "Escape", role: "related", path: "../outside.swift", line: 1, pathStatus: .repositoryRelative, evidence: .registered)
        ])
        report.logs = [LogEntry(timestamp: Date(), level: "info", category: "test", message: "visible log")]
        let store = ReportStore(home: home)
        try store.save(report, parts: parts, receipt: receipt())
        let stored = try store.load(report.id)
        let folder = try ClaudeHandoff.export(stored, projectRoot: repo.path, home: home)
        let summary = try String(contentsOf: folder.appendingPathComponent("report.md"), encoding: .utf8)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("report.txt").path))
        #expect(summary.contains("Title is clipped"))
        #expect(summary.contains("visible log"))
        #expect(summary.contains("struct Profile"))
        #expect(summary.contains("Unavailable"))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("annotated.png").path))
        // A report without screenshots/logs/source must not export earlier attachments.
        report = ReportEvidenceOptions(logs: false, viewDetails: false, source: false, screenshots: false).applying(to: report)
        parts = [:]
        let filtered = StoredReport(report: report, receipt: receipt(), directory: stored.directory)
        let updated = try ClaudeHandoff.export(filtered, projectRoot: repo.path, home: home)
        let filteredText = try String(contentsOf: updated.appendingPathComponent("report.md"), encoding: .utf8)
        #expect(!filteredText.contains("visible log"))
        #expect(!filteredText.contains("struct Profile"))
        #expect(!FileManager.default.fileExists(atPath: updated.appendingPathComponent("annotated.png").path))
    }

    @Test func deletingOrPruningReportAlsoRemovesExportedEvidence() throws {
        let home = SBHome(root: tempDir("export-retention"))
        var store = ReportStore(home: home)
        for prune in [false, true] {
            let (report, parts) = sampleReport()
            try store.save(report, parts: parts, receipt: receipt())
            let folder = try ClaudeHandoff.export(store.load(report.id), projectRoot: nil, home: home)
            if prune {
                store.maxReports = 0
                store.applyRetention()
            } else { try store.delete(report.id) }
            #expect(!FileManager.default.fileExists(atPath: folder.path))
            #expect((try? store.load(report.id)) == nil)
        }
    }

    @Test func desktopConfigurationPreservesOtherServers() throws {
        let root = tempDir("claude-config")
        let url = root.appendingPathComponent("config.json")
        try Data(#"{"theme":"dark","mcpServers":{"other":{"command":"other-command"}}}"#.utf8).write(to: url)
        try ClaudeHandoff.configureDesktop(command: "/some path/screenbridge-mcp", at: url)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(json["theme"] as? String == "dark")
        let servers = try #require(json["mcpServers"] as? [String: [String: Any]])
        #expect(servers["other"]?["command"] as? String == "other-command")
        #expect(servers["screenbridge"]?["command"] as? String == "/some path/screenbridge-mcp")
    }
}
