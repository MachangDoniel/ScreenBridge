import Foundation
import Testing
@testable import ScreenBridgeProtocol

func makeReport(id: String = ReportID.make(), description: String = "Button is misaligned") -> DebugReport {
    DebugReport(
        id: id,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        description: description,
        screenshot: ScreenshotGeometry(pixelWidth: 1179, pixelHeight: 2556, scale: 3, interfaceOrientation: "portrait"),
        images: [],
        annotations: [Annotation(tool: .ellipse, points: [SBPoint(x: 10, y: 10), SBPoint(x: 100, y: 60)])],
        redactionApplied: false,
        selection: nil,
        screen: ScreenContext(owningController: "ProfileViewController", controllerChain: ["ProfileViewController", "UINavigationController"]),
        sourceAnchors: [SourceAnchor(symbol: "ProfileViewController", role: "screen", path: "Sources/Profile.swift", line: 12, pathStatus: .repositoryRelative, evidence: .registered)],
        app: AppInfo(bundleIdentifier: "dev.example", name: "Example", version: "1.0", build: "1"),
        device: DeviceInfo(model: "iPhone17,1", systemName: "iOS", systemVersion: "27.0", isSimulator: false, interfaceIdiom: "phone"),
        build: BuildInfo(buildID: "b1", configuration: "Debug", gitCommit: "abc", isDirty: true, configured: true),
        logs: nil
    )
}

@Suite struct ReportSchemaTests {
    @Test func roundTripsReport() throws {
        let report = makeReport()
        let decoded = try ReportCoding.decode(ReportCoding.encode(report))
        #expect(decoded == report)
        #expect(decoded.schemaVersion == ReportSchema.current)
    }

    @Test func acceptsNewerMinorWithUnknownFields() throws {
        var json = try JSONSerialization.jsonObject(with: ReportCoding.encode(makeReport())) as! [String: Any]
        json["schemaVersion"] = "1.7"
        json["futureField"] = ["nested": true]
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try ReportCoding.decode(data)
        #expect(decoded.schemaVersion == "1.7")
    }

    @Test func acceptsOlderReportWithoutOptionalFields() throws {
        var json = try JSONSerialization.jsonObject(with: ReportCoding.encode(makeReport())) as! [String: Any]
        json.removeValue(forKey: "selection")
        json.removeValue(forKey: "logs")
        json.removeValue(forKey: "transfer")
        let decoded = try ReportCoding.decode(JSONSerialization.data(withJSONObject: json))
        #expect(decoded.selection == nil)
    }

    @Test func rejectsIncompatibleMajor() throws {
        var json = try JSONSerialization.jsonObject(with: ReportCoding.encode(makeReport())) as! [String: Any]
        json["schemaVersion"] = "2.0"
        #expect(throws: ReportSchemaError.incompatibleMajor(found: 2, supported: 1)) {
            try ReportCoding.decode(JSONSerialization.data(withJSONObject: json))
        }
    }

    @Test func rejectsMissingOrMalformedVersion() throws {
        var json = try JSONSerialization.jsonObject(with: ReportCoding.encode(makeReport())) as! [String: Any]
        json.removeValue(forKey: "schemaVersion")
        #expect(throws: ReportSchemaError.missingVersion) { try ReportCoding.decode(JSONSerialization.data(withJSONObject: json)) }
        json["schemaVersion"] = "one"
        #expect(throws: ReportSchemaError.malformedVersion("one")) { try ReportCoding.decode(JSONSerialization.data(withJSONObject: json)) }
    }

    @Test func rejectsPathLikeReportIDs() throws {
        for bad in ["../../etc", "SB-12345", "SB-ZZZZZZZZZZZZ", "SB-abcdefabcdef", "SB-0123456789AB/.."] {
            #expect(!ReportID.isValid(bad), "\(bad)")
        }
        #expect(ReportID.isValid(ReportID.make()))
        var json = try JSONSerialization.jsonObject(with: ReportCoding.encode(makeReport())) as! [String: Any]
        json["id"] = "../evil"
        #expect(throws: ReportSchemaError.invalidReportID("../evil")) { try ReportCoding.decode(JSONSerialization.data(withJSONObject: json)) }
    }

    @Test func relativizesPathsAndNeverLeaksAbsolutePaths() {
        let root = "/Users/me/Code/App"
        #expect(PathRelativizer.relativize("/Users/me/Code/App/Sources/A.swift", root: root) == ("Sources/A.swift", .repositoryRelative))
        #expect(PathRelativizer.relativize("/Users/me/Code/App2/B.swift", root: root) == ("B.swift", .outsideProject))
        #expect(PathRelativizer.relativize("/Users/me/Code/App/../Other/C.swift", root: root) == ("C.swift", .outsideProject))
        #expect(PathRelativizer.relativize("/abs/D.swift", root: nil) == ("D.swift", .outsideProject))
    }
}

@Suite struct FrameCodecTests {
    @Test func encodesAndDecodesSplitAcrossChunks() throws {
        let report = makeReport()
        let frame = Frame.report(report, parts: [("original.png", Data([1, 2, 3])), ("annotated.png", Data([4, 5]))])
        let bytes = try FrameCodec.encode(frame) + FrameCodec.encode(Frame(envelope: .error(code: "x", message: "y")))
        var decoder = FrameDecoder()
        var frames: [Frame] = []
        var i = bytes.startIndex
        while i < bytes.endIndex {
            let end = min(i + 7, bytes.endIndex)
            frames += try decoder.append(bytes.subdata(in: i..<end))
            i = end
        }
        #expect(frames.count == 2)
        #expect(frames[0].envelope.report == report)
        let parts = try frames[0].splitParts()
        #expect(parts["original.png"] == Data([1, 2, 3]))
        #expect(parts["annotated.png"] == Data([4, 5]))
        #expect(frames[1].envelope.error?.code == "x")
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test func rejectsOversizedHeaders() {
        var decoder = FrameDecoder()
        let bogus = Data([0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0])
        #expect(throws: FrameError.self) { try decoder.append(bogus) }
    }

    @Test func rejectsPartsThatDoNotMatchBody() {
        var frame = Frame.report(makeReport(), parts: [("a.png", Data([1, 2, 3]))])
        frame.body = Data([1])
        #expect(throws: FrameError.malformedParts) { try frame.splitParts() }
    }
}

@Suite struct LogSanitizerTests {
    @Test func removesSecretsAndIdentifiers() {
        let cases: [(String, String)] = [
            ("Authorization: Bearer abc.def-ghi", "abc.def-ghi"),
            ("token=s3cr3tValue&x=1", "s3cr3tValue"),
            ("{\"password\":\"hunter2\"}", "hunter2"),
            ("card 4111 1111 1111 1111 declined", "4111"),
            ("NID 1987654321098", "1987654321098"),
            ("mail jane.doe@example.com", "jane.doe@example.com"),
            ("jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc123", "eyJhbGci"),
            ("key a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6", "a1b2c3d4e5f6a1b2c3d4"),
        ]
        for (input, secret) in cases {
            let out = LogSanitizer.sanitize(input)
            #expect(!out.contains(secret), "\(input) → \(out)")
        }
    }

    @Test func keepsOrdinaryMessages() {
        #expect(LogSanitizer.sanitize("Loaded 12 accounts in 340 ms") == "Loaded 12 accounts in 340 ms")
    }

    @Test func ringBufferIsBounded() {
        var buffer = LogRingBuffer(capacity: 3)
        for i in 0..<10 { buffer.append(level: "info", category: "t", message: "m\(i)") }
        #expect(buffer.entries.map(\.message) == ["m7", "m8", "m9"])
        buffer.append(level: "info", category: "t", message: String(repeating: "x", count: 2000))
        #expect(buffer.entries.last!.message.count <= LogSanitizer.maxMessageLength + 1)
    }
}
