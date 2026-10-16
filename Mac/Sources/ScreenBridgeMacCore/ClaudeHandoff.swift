import Foundation
import ScreenBridgeProtocol

/// Builds reviewable Claude handoffs. This type never submits a model request.
public enum ClaudeHandoff {
    public static func request(for reportID: String, description: String = "", reportURL: URL? = nil) -> String {
        let requested = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = requested.isEmpty ? "" : "Requested change:\n\(String(requested.prefix(4_000)))\n\n"
        let reference = reportURL.map { "ScreenBridge context: [\(reportID)](\($0.absoluteString))" }
            ?? "ScreenBridge report \(reportID)"
        return prefix + reference
    }

    public static func url(destination: ClaudeDestination, prompt: String, projectRoot: String?) -> URL? {
        if destination == .inbox || destination == .reference { return nil }
        // Keep report content out of browser URL/history. The portable prompt is copied locally.
        if destination == .browser { return URL(string: "https://claude.ai/new") }
        var components = URLComponents()
        components.scheme = "claude"
        components.host = destination == .code ? "code" : "claude.ai"
        components.path = "/new"
        components.queryItems = prompt.isEmpty ? [] : [URLQueryItem(name: "q", value: String(prompt.prefix(12_000)))]
        if destination == .code, let projectRoot {
            components.queryItems?.append(URLQueryItem(name: "folder", value: projectRoot))
        }
        return components.url
    }

    /// Portable evidence for browser chats, which cannot access a local stdio MCP server.
    /// Source reads use the same confinement and limits as MCP. Exports are replaced so
    /// previously exported evidence cannot survive a later choice to exclude it.
    public static func export(_ stored: StoredReport, projectRoot: String?, home: SBHome) throws -> URL {
        let report = stored.report
        guard ReportID.isValid(report.id) else { throw StoreError.invalid("Invalid report ID.") }
        let root = home.root.appendingPathComponent("Exports", isDirectory: true)
        let final = root.appendingPathComponent(report.id, isDirectory: true)
        let staging = root.appendingPathComponent(".export-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            var text = "# ScreenBridge \(report.id)\n\n## Requested change\n\(report.description)\n"
            if let selection = report.selection {
                text += "\n## Selected object\n\(selection.displayName) (\(selection.className))\n"
                for (key, value) in (selection.properties ?? [:]).sorted(by: { $0.key < $1.key }) {
                    text += "- \(key): \(value)\n"
                }
                text += "Hierarchy: \(selection.hierarchy.map(\.className).joined(separator: " > "))\n"
            }
            if let screen = report.screen { text += "\nScreen: \(screen.owningController)\n" }
            if let region = report.selectedRegion {
                text += "\nSelected area (pixels): x=\(region.x), y=\(region.y), width=\(region.width), height=\(region.height)\n"
            }
            if let logs = report.logs {
                text += "\n## App logs\n```text\n" + logs.map { "[\($0.level)] \($0.category): \($0.message)" }.joined(separator: "\n") + "\n```\n"
            }
            var seen = Set<String>()
            for anchor in report.sourceAnchors {
                text += "\n## Source: \(anchor.symbol) (\(anchor.role))\n"
                guard anchor.pathStatus == .repositoryRelative, let path = anchor.path, let projectRoot else {
                    text += "Unavailable: no registered repository file.\n"; continue
                }
                text += "\(path):\(anchor.line ?? 1) [\(anchor.evidence.rawValue)]\n"
                guard seen.count < 8, seen.insert(path).inserted else { continue }
                do {
                    let line = max(1, anchor.line ?? 1)
                    let excerpt = try SourceAccess(root: projectRoot).read(path, startLine: max(1, line - 30), endLine: line + 100)
                    text += "```swift\n\(excerpt.text)\n```\n"
                } catch { text += "Unavailable: \(error)\n" }
            }
            if !report.images.isEmpty {
                text += "\n## Screenshots\n"
                for image in report.images where ReportStore.allowedPartNames.contains(image.fileName) {
                    text += "![\(image.role.rawValue)](\(image.fileName))\n"
                }
            }
            for image in report.images {
                guard ReportStore.allowedPartNames.contains(image.fileName), let source = stored.imageURL(image.role) else { continue }
                try fm.copyItem(at: source, to: staging.appendingPathComponent(image.fileName))
            }
            try text.write(to: staging.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
            try ReportCoding.encode(report, pretty: true).write(to: staging.appendingPathComponent("report.json"))
            if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
            try fm.moveItem(at: staging, to: final)
            return final
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// Explicit setup action: merges ScreenBridge without overwriting unrelated settings.
    public static func configureDesktop(command: String, at url: URL) throws {
        let fm = FileManager.default
        var json: [String: Any] = [:]
        if fm.fileExists(atPath: url.path) {
            guard let existing = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                throw StoreError.invalid("Claude configuration is not a JSON object.")
            }
            json = existing
        }
        if let existing = json["mcpServers"], !(existing is [String: Any]) {
            throw StoreError.invalid("Claude mcpServers configuration is not a JSON object.")
        }
        var servers = json["mcpServers"] as? [String: Any] ?? [:]
        servers["screenbridge"] = ["command": command, "args": []] as [String: Any]
        json["mcpServers"] = servers
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
