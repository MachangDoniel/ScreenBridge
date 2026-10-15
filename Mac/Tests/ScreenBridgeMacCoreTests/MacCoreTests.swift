import Foundation
import CoreGraphics
import Network
import Testing
@testable import ScreenBridgeMacCore
import ScreenBridgeProtocol
import ScreenBridgeTransport

// MARK: - Fixtures

func tempDir(_ name: String = "sb") -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    // Canonicalize (/var → /private/var) so prefix checks are meaningful.
    return URL(fileURLWithPath: SourceAccess.realpath(url.path)!, isDirectory: true)
}

@discardableResult
func sh(_ args: [String], cwd: URL) -> String {
    let r = try! Subprocess.run("/usr/bin/git", args, cwd: cwd, env: ["GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"])
    return r.stdoutString
}

func makeRepo() -> URL {
    let root = tempDir("repo")
    sh(["init", "-q", "-b", "main"], cwd: root)
    try! FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
    try! "struct Profile {}\n".write(to: root.appendingPathComponent("Sources/Profile.swift"), atomically: true, encoding: .utf8)
    try! "struct Other {}\n".write(to: root.appendingPathComponent("Sources/Other.swift"), atomically: true, encoding: .utf8)
    sh(["add", "."], cwd: root)
    sh(["commit", "-q", "-m", "init"], cwd: root)
    return root
}

func solidPNG(width: Int = 30, height: Int = 20) -> Data {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try! AnnotationRenderer.pngData(ctx.makeImage()!)
}

func sampleReport(id: String = ReportID.make(), build: BuildInfo = .unconfigured, anchors: [SourceAnchor] = []) -> (DebugReport, [String: Data]) {
    let png = solidPNG()
    let exported = ExportedScreenshot(originalPNG: png, annotatedPNG: png, pixelWidth: 30, pixelHeight: 20, redactionApplied: false)
    let report = DebugReport(
        id: id, description: "Title is clipped",
        screenshot: ScreenshotGeometry(pixelWidth: 30, pixelHeight: 20, scale: 1, interfaceOrientation: "portrait"),
        images: exported.attachments(), annotations: [], redactionApplied: false,
        selection: nil, screen: ScreenContext(owningController: "ProfileViewController", controllerChain: ["ProfileViewController"]),
        sourceAnchors: anchors,
        app: AppInfo(bundleIdentifier: "dev.demo", name: "Demo", version: "1", build: "1"),
        device: DeviceInfo(model: "iPhone18,2", systemName: "iOS", systemVersion: "27.0", isSimulator: true, interfaceIdiom: "phone"),
        build: build, logs: nil
    )
    return (report, ["original.png": png, "annotated.png": png])
}

func receipt(_ projectID: String = "proj-x") -> ReportReceipt {
    ReportReceipt(receivedAt: Date(), projectID: projectID, credentialID: "cred-x", deviceModel: "iPhone", consistencyAtReceipt: nil, inferredCandidates: [])
}

// MARK: - Path confinement

@Suite struct PathConfinementTests {
    @Test func allowsFilesInsideRoot() throws {
        let root = makeRepo()
        let access = SourceAccess(root: root.path)
        let url = try access.resolve("Sources/Profile.swift")
        #expect(url.path == root.appendingPathComponent("Sources/Profile.swift").path)
        let excerpt = try access.read("Sources/Profile.swift")
        #expect(excerpt.text.contains("1  struct Profile {}"))
    }

    @Test func rejectsTraversalAbsoluteAndHomePaths() {
        let access = SourceAccess(root: makeRepo().path)
        #expect(throws: SourceAccessError.traversal) { try access.resolve("../etc/passwd") }
        #expect(throws: SourceAccessError.traversal) { try access.resolve("Sources/../../x") }
        #expect(throws: SourceAccessError.absolutePath) { try access.resolve("/etc/passwd") }
        #expect(throws: SourceAccessError.absolutePath) { try access.resolve("~/.ssh/id_rsa") }
        #expect(throws: SourceAccessError.emptyPath) { try access.resolve("  ") }
    }

    @Test func rejectsSymlinkEscapes() throws {
        let root = makeRepo()
        let outside = tempDir("outside")
        try "secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.txt"), withDestinationURL: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linkdir"), withDestinationURL: outside)
        let access = SourceAccess(root: root.path)
        #expect(throws: SourceAccessError.outsideRoot) { try access.resolve("link.txt") }
        #expect(throws: SourceAccessError.outsideRoot) { try access.resolve("linkdir/secret.txt") }
    }

    @Test func rejectsSiblingPrefixTrick() throws {
        // /tmp/x/repo vs /tmp/x/repo2 — a naive hasPrefix check would allow repo2.
        let parent = tempDir("parent")
        let repo = parent.appendingPathComponent("repo"), repo2 = parent.appendingPathComponent("repo2")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo2, withIntermediateDirectories: true)
        try "x".write(to: repo2.appendingPathComponent("f.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: repo.appendingPathComponent("f.swift"), withDestinationURL: repo2.appendingPathComponent("f.swift"))
        #expect(throws: SourceAccessError.outsideRoot) { try SourceAccess(root: repo.path).resolve("f.swift") }
    }

    @Test func symlinkedRootStillWorks() throws {
        let root = makeRepo()
        let alias = tempDir("alias").appendingPathComponent("root-link")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        #expect(try SourceAccess(root: alias.path).read("Sources/Other.swift").totalLines >= 1)
    }

    @Test func rejectsBinaryAndRespectsLineRange() throws {
        let root = makeRepo()
        try Data([0x89, 0x50, 0x00, 0x01]).write(to: root.appendingPathComponent("img.png"))
        #expect(throws: SourceAccessError.binary) { try SourceAccess(root: root.path).read("img.png") }
        try (1...50).map { "line \($0)" }.joined(separator: "\n").write(to: root.appendingPathComponent("long.swift"), atomically: true, encoding: .utf8)
        let e = try SourceAccess(root: root.path).read("long.swift", startLine: 10, endLine: 12)
        #expect(e.startLine == 10 && e.endLine == 12)
        #expect(e.text == "10  line 10\n11  line 11\n12  line 12")
    }
}

// MARK: - Git fingerprint & consistency

@Suite struct ConsistencyTests {
    @Test func distinguishesCommitAndWorkingTreeChanges() throws {
        let root = makeRepo()
        let clean = try #require(try GitInspector.state(of: root))
        #expect(!clean.isDirty)
        #expect(clean.swiftFileHashes["Sources/Profile.swift"] != nil)

        // Build from a dirty tree.
        try "struct Profile { var x = 1 }\n".write(to: root.appendingPathComponent("Sources/Profile.swift"), atomically: true, encoding: .utf8)
        let atBuild = try #require(try GitInspector.state(of: root))
        #expect(atBuild.isDirty && atBuild.commit == clean.commit)
        #expect(atBuild.fingerprint != clean.fingerprint)
        let build = BuildInfo(buildID: "b1", gitCommit: atBuild.commit, isDirty: true, workingTreeFingerprint: atBuild.fingerprint, configured: true)
        let snapshot = BuildSnapshot(buildID: "b1", projectID: "p", configuration: "Debug", appBundleIdentifier: "x", createdAt: Date(), git: atBuild)
        let paths = ["Sources/Profile.swift", "Sources/Other.swift"]

        // 1. Nothing changed since the build: exact match even though the tree is dirty.
        var c = SourceConsistency.evaluate(build: build, snapshot: snapshot, current: try GitInspector.state(of: root), anchorPaths: paths)
        #expect(c.overall == .exactMatch)
        #expect(c.files.allSatisfy { $0.status == .unchanged })

        // 2. Same commit, working tree edited after the build.
        try "struct Other { var y = 2 }\n".write(to: root.appendingPathComponent("Sources/Other.swift"), atomically: true, encoding: .utf8)
        c = SourceConsistency.evaluate(build: build, snapshot: snapshot, current: try GitInspector.state(of: root), anchorPaths: paths)
        #expect(c.overall == .sameCommitWorkingTreeChanged)
        #expect(c.files.first { $0.path == "Sources/Other.swift" }?.status == .changedSinceBuild)
        #expect(c.files.first { $0.path == "Sources/Profile.swift" }?.status == .unchanged)

        // 3. New commit.
        sh(["commit", "-qam", "next"], cwd: root)
        c = SourceConsistency.evaluate(build: build, snapshot: snapshot, current: try GitInspector.state(of: root), anchorPaths: paths)
        #expect(c.overall == .differentCommit)

        // 4. Deleted file.
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/Profile.swift"))
        c = SourceConsistency.evaluate(build: build, snapshot: snapshot, current: try GitInspector.state(of: root), anchorPaths: paths)
        #expect(c.files.first { $0.path == "Sources/Profile.swift" }?.status == .missing)
    }

    @Test func untrackedFilesChangeTheFingerprint() throws {
        let root = makeRepo()
        let before = try #require(try GitInspector.state(of: root))
        try "struct New {}\n".write(to: root.appendingPathComponent("Sources/New.swift"), atomically: true, encoding: .utf8)
        let after = try #require(try GitInspector.state(of: root))
        #expect(after.isDirty && before.fingerprint != after.fingerprint)
        #expect(after.swiftFileHashes["Sources/New.swift"] != nil)
        try "struct New { }\n".write(to: root.appendingPathComponent("Sources/New.swift"), atomically: true, encoding: .utf8)
        #expect(try GitInspector.state(of: root)?.fingerprint != after.fingerprint)
    }

    @Test func unknownWhenUnconfiguredOrNotGit() throws {
        let c1 = SourceConsistency.evaluate(build: .unconfigured, snapshot: nil, current: nil, anchorPaths: ["a.swift"])
        #expect(c1.overall == .unknown && c1.files.first?.status == .unknown)
        #expect(try GitInspector.state(of: tempDir("nogit")) == nil)
        let c2 = SourceConsistency.evaluate(build: BuildInfo(gitCommit: "abc", configured: true), snapshot: nil, current: nil, anchorPaths: [])
        #expect(c2.overall == .unknown)
    }
}

// MARK: - Report store

@Suite struct ReportStoreTests {
    @Test func storesOnceAndReportsDuplicates() throws {
        let store = ReportStore(home: SBHome(root: tempDir("home")))
        let (report, parts) = sampleReport()
        #expect(try store.save(report, parts: parts, receipt: receipt()) == .stored)
        #expect(try store.save(report, parts: parts, receipt: receipt()) == .duplicate)
        #expect(store.list().map(\.id) == [report.id])
        #expect(try store.resolve("latest").id == report.id)
        #expect(try store.resolve(report.id.lowercased()).id == report.id)
    }

    @Test func rejectsTamperedOrUnexpectedAttachments() throws {
        let store = ReportStore(home: SBHome(root: tempDir("home")))
        let (report, parts) = sampleReport()
        var tampered = parts
        tampered["annotated.png"] = solidPNG(width: 31)
        #expect(throws: ReportValidationError.hashMismatch("annotated.png")) { try store.save(report, parts: tampered, receipt: receipt()) }
        var extra = parts
        extra["../../evil.sh"] = Data("x".utf8)
        #expect(throws: ReportValidationError.self) { try store.save(report, parts: extra, receipt: receipt()) }
        var missing = parts
        missing.removeValue(forKey: "original.png")
        #expect(throws: ReportValidationError.missingPart("original.png")) { try store.save(report, parts: missing, receipt: receipt()) }
        #expect(store.list().isEmpty)
    }

    @Test func retentionBoundsCountAndAge() throws {
        var store = ReportStore(home: SBHome(root: tempDir("home")))
        store.maxReports = 2
        for _ in 0..<4 {
            let (r, p) = sampleReport()
            _ = try store.save(r, parts: p, receipt: receipt())
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(store.list().count == 2)
        store.applyRetention(now: Date().addingTimeInterval(40 * 24 * 3600))
        #expect(store.list().isEmpty)
    }
}

// MARK: - Build integration

@Suite struct BuildIntegrationTests {
    @Test func generatesConfigWithBuildIdentityForDebugOnly() throws {
        let home = SBHome(root: tempDir("home"))
        let repo = makeRepo()
        let products = tempDir("products")
        let env = [
            "CONFIGURATION": "Debug", "SRCROOT": repo.appendingPathComponent("Sources").path,
            "PRODUCT_BUNDLE_IDENTIFIER": "dev.demo", "TARGET_BUILD_DIR": products.path, "UNLOCALIZED_RESOURCES_FOLDER_PATH": "Demo.app",
        ]
        let out = BuildConfigurator.run(environment: env, home: home)
        let config = try #require(out.config)
        #expect(config.projectRoot == repo.path) // git root, not SRCROOT
        #expect(config.build.gitCommit != nil && config.build.isDirty == false && config.build.configured)
        #expect(Data(base64Encoded: config.pskBase64)?.count == 32)
        let written = try ConnectionConfig.decode(Data(contentsOf: products.appendingPathComponent("Demo.app/ScreenBridgeConnection.json")))
        #expect(written.credentialID == config.credentialID && written.build.buildID == config.build.buildID && written.pskBase64 == config.pskBase64)
        #expect(BuildSnapshotStore(home: home).load(config.build.buildID!)?.git?.commit == config.build.gitCommit)

        // Rebuilding reuses the credential; a Release build removes the file.
        let again = try #require(BuildConfigurator.run(environment: env, home: home).config)
        #expect(again.credentialID == config.credentialID && again.build.buildID != config.build.buildID)
        var release = env
        release["CONFIGURATION"] = "Release"
        _ = BuildConfigurator.run(environment: release, home: home)
        #expect(!FileManager.default.fileExists(atPath: products.appendingPathComponent("Demo.app/ScreenBridgeConnection.json").path))

        // Revocation issues a new credential on the next build.
        try CredentialStore(home: home).revoke(id: config.credentialID)
        #expect(try CredentialStore(home: home).credential(id: config.credentialID)?.keyBase64 == "")
        let rebuilt = try #require(BuildConfigurator.run(environment: env, home: home).config)
        #expect(rebuilt.credentialID != config.credentialID)
    }

    @Test func neverFailsWithoutRequiredEnvironment() {
        let out = BuildConfigurator.run(environment: ["CONFIGURATION": "Debug"], home: SBHome(root: tempDir("home")))
        #expect(out.config == nil)
        #expect(out.messages.contains { $0.hasPrefix("warning:") })
    }

    @Test func credentialsFileIsOwnerOnly() throws {
        let home = SBHome(root: tempDir("home"))
        _ = try CredentialStore(home: home).issue(projectID: "p", appBundleIdentifier: "b")
        let perms = try FileManager.default.attributesOfItem(atPath: home.credentialsFile.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }
}

// MARK: - Receiver end to end (real TLS-PSK over loopback)

@Suite(.serialized) struct ReceiverServiceTests {
    @Test func acceptsBuiltAppAndRejectsRevokedOrForeignApps() async throws {
        let home = SBHome(root: tempDir("home"))
        let repo = makeRepo()
        let products = tempDir("products")
        let env = ["CONFIGURATION": "Debug", "SRCROOT": repo.path, "PRODUCT_BUNDLE_IDENTIFIER": "dev.demo", "TARGET_BUILD_DIR": products.path, "UNLOCALIZED_RESOURCES_FOLDER_PATH": "Demo.app"]
        let config = try #require(BuildConfigurator.run(environment: env, home: home).config)

        let service = try ReceiverService(home: home)
        try service.start()
        defer { service.stop() }
        var port: UInt16 = 0
        for _ in 0..<100 where port == 0 {
            port = HelperStatus.load(home)?.port ?? 0
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: port)!)
        func hello(_ c: ConnectionConfig, bundle: String = "dev.demo") -> Hello {
            Hello(credentialID: c.credentialID, receiverID: c.receiverID, projectID: c.projectID, appBundleIdentifier: bundle, appName: "Demo", buildID: c.build.buildID, deviceModel: "iPhone", systemVersion: "27", isSimulator: true)
        }

        // Valid app: report stored and acknowledged, duplicate detected.
        let session = try await ReceiverSession.connect(to: endpoint, config: config, hello: hello(config))
        let (report, parts) = sampleReport(build: config.build, anchors: [SourceAnchor(symbol: "Profile", role: "screen", path: "Sources/Profile.swift", line: 1, pathStatus: .repositoryRelative, evidence: .registered)])
        let ack = try await session.sendReport(report, parts: parts.map { ($0.key, $0.value) })
        #expect(!ack.duplicate)
        #expect(try await session.sendReport(report, parts: parts.map { ($0.key, $0.value) }).duplicate)
        let stored = try ReportStore(home: home).load(report.id)
        #expect(stored.receipt.projectID == config.projectID)
        #expect(stored.receipt.consistencyAtReceipt?.overall == .exactMatch)

        // Reveal is confined to the project root.
        let refused = try await session.reveal(RevealRequest(projectID: config.projectID, path: "../../etc/hosts", line: 1))
        #expect(!refused.opened)
        await session.close()

        // Credential issued to a different bundle ID is rejected at hello.
        await #expect(throws: TransportError.self) {
            _ = try await ReceiverSession.connect(to: endpoint, config: config, hello: hello(config, bundle: "dev.other"), timeout: 5)
        }

        // An app configured for another receiver is rejected even with a valid key.
        var foreign = config
        foreign.receiverID = "another-receiver"
        await #expect(throws: TransportError.self) {
            _ = try await ReceiverSession.connect(to: endpoint, config: foreign, hello: hello(foreign), timeout: 5)
        }

        // Revoked credential fails the TLS handshake once the listener reloads.
        try CredentialStore(home: home).revoke(id: config.credentialID)
        service.reloadCredentials()
        try await Task.sleep(nanoseconds: 300_000_000)
        let newPort = HelperStatus.load(home)?.port ?? port
        await #expect(throws: TransportError.self) {
            _ = try await ReceiverSession.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: newPort)!), config: config, hello: hello(config), timeout: 5)
        }
    }
}

// MARK: - MCP

@Suite struct MCPServerTests {
    func call(_ server: MCPServer, _ method: String, _ params: [String: Any] = [:], id: Int = 1) throws -> [String: Any] {
        let req: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: req), as: UTF8.self)
        let response = try #require(server.handle(line: line))
        return try #require(try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    }

    func setup() throws -> (MCPServer, DebugReport, URL) {
        let home = SBHome(root: tempDir("home"))
        let repo = makeRepo()
        let project = try ProjectRegistry(home: home).register(root: repo)
        let (report, parts) = sampleReport(anchors: [SourceAnchor(symbol: "Profile", role: "screen", path: "Sources/Profile.swift", line: 1, pathStatus: .repositoryRelative, evidence: .registered)])
        _ = try ReportStore(home: home).save(report, parts: parts, receipt: receipt(project.id))
        return (MCPServer(home: home), report, repo)
    }

    @Test func initializeNegotiatesVersionAndListsTools() throws {
        let (server, _, _) = try setup()
        let initResult = try call(server, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]])["result"] as! [String: Any]
        #expect(initResult["protocolVersion"] as? String == "2025-06-18")
        let unknown = try call(server, "initialize", ["protocolVersion": "1999-01-01"])["result"] as! [String: Any]
        #expect(unknown["protocolVersion"] as? String == MCPServer.supportedProtocolVersions[0])
        #expect(server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        let tools = (try call(server, "tools/list")["result"] as! [String: Any])["tools"] as! [[String: Any]]
        #expect(Set(tools.compactMap { $0["name"] as? String }) == ["list_debug_reports", "get_debug_report", "get_report_images", "read_related_source"])
        #expect(try call(server, "nope")["error"] != nil)
    }

    @Test func getReportImagesReturnsDecodableImageContent() throws {
        let (server, report, _) = try setup()
        let result = try call(server, "tools/call", ["name": "get_report_images", "arguments": ["report_id": report.id, "variant": "both"]])["result"] as! [String: Any]
        #expect(result["isError"] == nil)
        let images = (result["content"] as! [[String: Any]]).filter { $0["type"] as? String == "image" }
        #expect(images.count == 2)
        for img in images {
            #expect(img["mimeType"] as? String == "image/png")
            let data = try #require(Data(base64Encoded: img["data"] as! String))
            let cg = try AnnotationRenderer.decodeImage(data)
            #expect(cg.width == 30 && cg.height == 20)
        }
    }

    @Test func reportAndSourceToolsWork() throws {
        let (server, report, _) = try setup()
        let list = try call(server, "tools/call", ["name": "list_debug_reports", "arguments": [:]])["result"] as! [String: Any]
        #expect(((list["content"] as! [[String: Any]])[0]["text"] as! String).contains(report.id))

        let got = try call(server, "tools/call", ["name": "get_debug_report", "arguments": ["report_id": "latest"]])["result"] as! [String: Any]
        let text = (got["content"] as! [[String: Any]]).compactMap { $0["text"] as? String }.joined()
        #expect(text.contains("Title is clipped") && text.contains("Sources/Profile.swift:1"))

        let src = try call(server, "tools/call", ["name": "read_related_source", "arguments": ["report_id": report.id, "path": "Sources/Profile.swift"]])["result"] as! [String: Any]
        #expect(((src["content"] as! [[String: Any]])[0]["text"] as! String).contains("struct Profile"))

        let escape = try call(server, "tools/call", ["name": "read_related_source", "arguments": ["report_id": report.id, "path": "../../../../etc/hosts"]])["result"] as! [String: Any]
        #expect(escape["isError"] as? Bool == true)
    }

    @Test func resourcesExposeImagesAsBlobs() throws {
        let (server, report, _) = try setup()
        let list = (try call(server, "resources/list")["result"] as! [String: Any])["resources"] as! [[String: Any]]
        #expect(list.contains { $0["uri"] as? String == "screenbridge://reports/\(report.id)/annotated.png" })
        let read = (try call(server, "resources/read", ["uri": "screenbridge://reports/\(report.id)/annotated.png"])["result"] as! [String: Any])["contents"] as! [[String: Any]]
        #expect(read.first?["blob"] is String)
        #expect(try call(server, "resources/read", ["uri": "screenbridge://reports/../x"])["error"] != nil)
    }

    @Test func stdioBinaryRespondsOverPipes() throws {
        // Exercise the real executable the way Claude Desktop does.
        let (_, report, _) = try setup()
        let binary = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/screenbridge-mcp")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return } // built by `swift build`
        _ = report
        let input = """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}
        {"jsonrpc":"2.0","method":"notifications/initialized"}
        {"jsonrpc":"2.0","id":2,"method":"tools/list"}

        """
        let r = try Subprocess.run(binary.path, [], stdin: Data(input.utf8), env: ["SCREENBRIDGE_HOME": tempDir("home").path], timeout: 20)
        let lines = r.stdoutString.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.contains("\"jsonrpc\":\"2.0\"") })
    }
}
