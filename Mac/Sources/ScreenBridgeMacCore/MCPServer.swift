import Foundation
import ScreenBridgeProtocol

/// Minimal, dependency-free MCP server (JSON-RPC 2.0 over newline-delimited stdio).
///
/// Read-only. Images are returned as MCP `image` content (base64 PNG) so the model can
/// actually see them; source reads are confined to registered project roots.
public final class MCPServer {
    public static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    public static let serverVersion = "0.1.0"

    let home: SBHome
    var reports: ReportStore { ReportStore(home: home) }
    var projects: ProjectRegistry { ProjectRegistry(home: home) }

    public init(home: SBHome = .default()) {
        self.home = home
    }

    // MARK: Stdio loop

    public static func runStdio(home: SBHome = .default()) -> Never {
        let server = MCPServer(home: home)
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let response = server.handle(line: line) {
                FileHandle.standardOutput.write(Data((response + "\n").utf8))
            }
        }
        exit(0)
    }

    /// Handles one JSON-RPC message; returns the response line, or nil for notifications.
    public func handle(line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        if let batch = obj as? [[String: Any]] {
            let responses = batch.compactMap { handle(message: $0) }
            return responses.isEmpty ? nil : encode(responses)
        }
        guard let msg = obj as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Invalid Request"]])
        }
        return handle(message: msg).map(encode)
    }

    func handle(message msg: [String: Any]) -> [String: Any]? {
        let id = msg["id"]
        guard let method = msg["method"] as? String else {
            guard let id else { return nil }
            return error(id, -32600, "Invalid Request")
        }
        let params = msg["params"] as? [String: Any] ?? [:]
        // Notifications (no id) never get a response.
        guard let id else { return nil }

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil } ?? Self.supportedProtocolVersions[0]
            return result(id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false], "resources": ["listChanged": false, "subscribe": false]],
                "serverInfo": ["name": "screenbridge", "title": "ScreenBridge", "version": Self.serverVersion],
                "instructions": "ScreenBridge provides debug reports sent from an iOS app: an annotated screenshot, the user's description, registered source anchors (repository-relative paths) and build/source consistency. Typical flow: get_debug_report → get_report_images → read_related_source, then propose a fix. Registration anchors mark where UI was registered, not necessarily the buggy line. Evidence 'inferredCandidate' is an unverified search result.",
            ])
        case "ping":
            return result(id, [:])
        case "tools/list":
            return result(id, ["tools": Self.toolDefinitions])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            return result(id, callTool(name, args))
        case "resources/list":
            return result(id, ["resources": resourceList()])
        case "resources/templates/list":
            return result(id, ["resourceTemplates": [
                ["uriTemplate": "screenbridge://reports/{id}", "name": "ScreenBridge report", "mimeType": "application/json"],
                ["uriTemplate": "screenbridge://reports/{id}/annotated.png", "name": "Annotated screenshot", "mimeType": "image/png"],
            ]])
        case "resources/read":
            guard let uri = params["uri"] as? String else { return error(id, -32602, "Missing uri") }
            do { return result(id, ["contents": try readResource(uri)]) } catch {
                return self.error(id, -32002, "\(error)")
            }
        case "prompts/list":
            return result(id, ["prompts": []])
        default:
            return error(id, -32601, "Method not found: \(method)")
        }
    }

    // MARK: Tools

    static var toolDefinitions: [[String: Any]] { [
        [
            "name": "list_debug_reports",
            "title": "List ScreenBridge reports",
            "description": "List recent ScreenBridge debug reports sent from iOS apps (newest first) with ID, time, description, project, selected element and source consistency.",
            "inputSchema": ["type": "object", "properties": [
                "limit": ["type": "integer", "minimum": 1, "maximum": 100, "description": "Maximum reports to return (default 20)."],
                "project": ["type": "string", "description": "Optional project ID or name filter."],
            ], "additionalProperties": false],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "get_debug_report",
            "title": "Get a ScreenBridge report",
            "description": "Full details of one report: description, selected element, screen/navigation context, registered source anchors (repository-relative), unverified candidates, build metadata, current source consistency, annotations and optional sanitized logs. Use 'latest' for the newest report.",
            "inputSchema": ["type": "object", "properties": [
                "report_id": ["type": "string", "description": "Report ID such as SB-7F3A2C9104BE, or 'latest'."],
            ], "required": ["report_id"], "additionalProperties": false],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "get_report_images",
            "title": "Get report screenshots",
            "description": "Returns the report's screenshot(s) as images. 'annotated' includes the user's markup; 'original' has no markup. If the report used redaction, both have the redacted pixels removed.",
            "inputSchema": ["type": "object", "properties": [
                "report_id": ["type": "string", "description": "Report ID or 'latest'."],
                "variant": ["type": "string", "enum": ["annotated", "original", "both"], "description": "Which image(s) to return (default both)."],
                "max_dimension": ["type": "integer", "minimum": 256, "maximum": 4096, "description": "Downscale so the longest edge is at most this many pixels (default 1568)."],
            ], "required": ["report_id"], "additionalProperties": false],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "read_related_source",
            "title": "Read source linked from a report",
            "description": "Read a file inside the report's registered project root (repository-relative path), with line numbers. Paths outside the project root, absolute paths, '..' and symlink escapes are rejected.",
            "inputSchema": ["type": "object", "properties": [
                "report_id": ["type": "string", "description": "Report whose project root to use (or 'latest'). Optional if 'project' is given or only one project is registered."],
                "project": ["type": "string", "description": "Project ID or name (alternative to report_id)."],
                "path": ["type": "string", "description": "Repository-relative path, e.g. Sources/Profile/ProfileViewController.swift."],
                "start_line": ["type": "integer", "minimum": 1],
                "end_line": ["type": "integer", "minimum": 1],
            ], "required": ["path"], "additionalProperties": false],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
    ] }

    func callTool(_ name: String, _ args: [String: Any]) -> [String: Any] {
        do {
            switch name {
            case "list_debug_reports": return try listReports(args)
            case "get_debug_report": return try getReport(args)
            case "get_report_images": return try getImages(args)
            case "read_related_source": return try readSource(args)
            default: return toolError("Unknown tool \(name).")
            }
        } catch {
            return toolError("\(error)")
        }
    }

    private func toolError(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    private func text(_ s: String) -> [String: Any] { ["type": "text", "text": s] }

    func listReports(_ args: [String: Any]) throws -> [String: Any] {
        let limit = min(100, max(1, (args["limit"] as? Int) ?? 20))
        var all = reports.list()
        if let p = args["project"] as? String, let project = try projects.find(p) {
            all = all.filter { $0.receipt.projectID == project.id }
        }
        let names = Dictionary(uniqueKeysWithValues: ((try? projects.all()) ?? []).map { ($0.id, $0.name) })
        guard !all.isEmpty else {
            return ["content": [text("No ScreenBridge reports yet. Send one from the iPhone with the ScreenBridge inspector → Report a change → Send to Mac.")]]
        }
        let iso = ISO8601DateFormatter()
        let lines = all.prefix(limit).map { r -> String in
            let desc = r.report.description.split(separator: "\n").first.map(String.init) ?? "(no description)"
            let element = r.report.selection?.displayName ?? r.report.screen?.owningController ?? "screen"
            let consistency = r.receipt.consistencyAtReceipt?.overall.rawValue ?? "unknown"
            return "- \(r.id) · \(iso.string(from: r.receipt.receivedAt)) · \(names[r.receipt.projectID] ?? r.receipt.projectID) · \(element) · source: \(consistency)\n  \(desc)"
        }
        return ["content": [text("\(min(limit, all.count)) of \(all.count) report(s):\n" + lines.joined(separator: "\n"))]]
    }

    func getReport(_ args: [String: Any]) throws -> [String: Any] {
        guard let id = args["report_id"] as? String else { throw StoreError.invalid("report_id is required.") }
        let stored = try reports.resolve(id)
        let project = try projects.project(id: stored.receipt.projectID)
        let current = project.map { ReceiverService.consistency(for: stored.report, root: $0.rootPath, home: home) }

        var summary = "ScreenBridge report \(stored.id)\n"
        summary += "Description: \(stored.report.description.isEmpty ? "(none)" : stored.report.description)\n"
        if let p = project { summary += "Project: \(p.name) (\(p.id)); paths below are relative to the project root.\n" }
        else { summary += "Project \(stored.receipt.projectID) is not registered on this Mac; source cannot be read.\n" }
        if let el = stored.report.selection {
            summary += "Selected element: \(el.displayName) [\(el.className)]" + (el.accessibilityIdentifier.map { " id=\($0)" } ?? "") + "\n"
        }
        if let s = stored.report.screen { summary += "Screen: \(s.owningController) — \(s.controllerChain.joined(separator: " › "))\n" }
        summary += "Source anchors (registration anchors, not necessarily the buggy line):\n"
        for a in stored.report.sourceAnchors {
            summary += "  • [\(a.evidence.rawValue)] \(a.role) \(a.symbol): \(a.path ?? "no file")\(a.line.map { ":\($0)" } ?? "")\(a.note.map { " — \($0)" } ?? "")\n"
        }
        if !stored.receipt.inferredCandidates.isEmpty {
            summary += "Unverified candidates (repository search; may be wrong):\n"
            for a in stored.receipt.inferredCandidates { summary += "  • \(a.symbol): \(a.path ?? "?"):\(a.line ?? 0)\n" }
        }
        if let c = current {
            summary += "Source consistency now: \(c.overall.rawValue) — \(c.summary)\n"
            for f in c.files { summary += "  • \(f.path): \(f.status.rawValue)\(f.note.map { " (\($0))" } ?? "")\n" }
        }
        summary += "Images: \(stored.report.images.map { "\($0.role.rawValue)\($0.redacted ? " (redacted)" : "")" }.joined(separator: ", ")). Use get_report_images to view them.\n"

        var payload: [String: Any] = [:]
        if let obj = try? JSONSerialization.jsonObject(with: ReportCoding.encode(stored.report)) { payload["report"] = obj }
        if let obj = try? JSONSerialization.jsonObject(with: ReportCoding.encoder().encode(stored.receipt)) { payload["receipt"] = obj }
        if let c = current, let obj = try? JSONSerialization.jsonObject(with: ReportCoding.encoder().encode(c)) { payload["currentConsistency"] = obj }
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data(), as: UTF8.self)
        return ["content": [text(summary), text("Full report JSON:\n" + json)]]
    }

    func getImages(_ args: [String: Any]) throws -> [String: Any] {
        guard let id = args["report_id"] as? String else { throw StoreError.invalid("report_id is required.") }
        let stored = try reports.resolve(id)
        let variant = (args["variant"] as? String) ?? "both"
        let maxDim = min(4096, max(256, (args["max_dimension"] as? Int) ?? 1568))
        let roles: [ImageRole] = variant == "annotated" ? [.annotated] : variant == "original" ? [.original] : [.annotated, .original]
        var content: [[String: Any]] = []
        for role in roles {
            guard let url = stored.imageURL(role), let data = try? Data(contentsOf: url) else { continue }
            let image = try AnnotationRenderer.downscaled(AnnotationRenderer.decodeImage(data), maxDimension: maxDim)
            let png = try AnnotationRenderer.pngData(image)
            let attachment = stored.report.image(role)
            content.append(text("\(role == .annotated ? "Annotated screenshot (user markup)" : "Screenshot without markup")\(attachment?.redacted == true ? ", redactions applied" : "") — \(image.width)×\(image.height) px (original \(attachment?.pixelWidth ?? 0)×\(attachment?.pixelHeight ?? 0), scale \(stored.report.screenshot.scale)x)."))
            content.append(["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"])
        }
        guard !content.isEmpty else { return toolError("Report \(stored.id) has no stored images.") }
        return ["content": content]
    }

    func readSource(_ args: [String: Any]) throws -> [String: Any] {
        guard let path = args["path"] as? String else { throw StoreError.invalid("path is required.") }
        let project: RegisteredProject
        if let rid = args["report_id"] as? String {
            let stored = try reports.resolve(rid)
            guard let p = try projects.project(id: stored.receipt.projectID) else { throw StoreError.notFound("The report's project is not registered on this Mac.") }
            project = p
        } else if let name = args["project"] as? String {
            guard let p = try projects.find(name) else { throw StoreError.notFound("No registered project \(name).") }
            project = p
        } else {
            let all = try projects.all()
            guard all.count == 1, let only = all.first else {
                throw StoreError.invalid("Specify report_id or project (\(all.count) projects are registered).")
            }
            project = only
        }
        let excerpt = try SourceAccess(root: project.rootPath).read(path, startLine: args["start_line"] as? Int, endLine: args["end_line"] as? Int)
        let header = "\(excerpt.path) — lines \(excerpt.startLine)–\(excerpt.endLine) of \(excerpt.totalLines) (project \(project.name))"
        return ["content": [text(header + "\n" + excerpt.text)]]
    }

    // MARK: Resources

    func resourceList() -> [[String: Any]] {
        reports.list().prefix(50).flatMap { r -> [[String: Any]] in
            var items: [[String: Any]] = [[
                "uri": "screenbridge://reports/\(r.id)", "name": r.id,
                "title": "\(r.id): \(r.report.description.prefix(60))", "mimeType": "application/json",
            ]]
            if r.imageURL(.annotated) != nil {
                items.append(["uri": "screenbridge://reports/\(r.id)/annotated.png", "name": "\(r.id) annotated", "mimeType": "image/png"])
            }
            return items
        }
    }

    func readResource(_ uri: String) throws -> [[String: Any]] {
        let prefix = "screenbridge://reports/"
        guard uri.hasPrefix(prefix) else { throw StoreError.notFound("Unknown resource \(uri)") }
        let rest = uri.dropFirst(prefix.count).split(separator: "/").map(String.init)
        guard let id = rest.first else { throw StoreError.notFound("Unknown resource \(uri)") }
        let stored = try reports.load(id)
        if rest.count == 1 {
            return [["uri": uri, "mimeType": "application/json", "text": String(decoding: try ReportCoding.encode(stored.report, pretty: true), as: UTF8.self)]]
        }
        let role: ImageRole = rest[1] == "original.png" ? .original : .annotated
        guard rest.count == 2, ["annotated.png", "original.png"].contains(rest[1]), let url = stored.imageURL(role) else {
            throw StoreError.notFound("Unknown resource \(uri)")
        }
        return [["uri": uri, "mimeType": "image/png", "blob": try Data(contentsOf: url).base64EncodedString()]]
    }

    // MARK: JSON-RPC helpers

    private func result(_ id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func error(_ id: Any, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private func encode(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}
