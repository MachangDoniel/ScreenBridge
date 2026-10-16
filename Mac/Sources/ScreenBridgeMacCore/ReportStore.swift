import Foundation
import CoreGraphics
import ScreenBridgeProtocol

/// Mac-side metadata recorded when a report arrives.
public struct ReportReceipt: Codable, Sendable, Equatable {
    public var receivedAt: Date
    /// Project the sending credential belongs to (authoritative, not taken from the report).
    public var projectID: String
    public var credentialID: String
    public var deviceModel: String
    public var consistencyAtReceipt: SourceConsistency?
    /// Unverified candidates for related types with no registered file.
    public var inferredCandidates: [SourceAnchor]
}

public struct StoredReport: Sendable, Equatable, Identifiable {
    public var report: DebugReport
    public var receipt: ReportReceipt
    public var directory: URL
    public var id: String { report.id }

    public func imageURL(_ role: ImageRole) -> URL? {
        guard let a = report.image(role) else { return nil }
        let url = directory.appendingPathComponent(a.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

public enum ReportValidationError: Error, Equatable, CustomStringConvertible {
    case invalidID
    case schema(String)
    case unexpectedPart(String)
    case missingPart(String)
    case hashMismatch(String)
    case notAnImage(String)
    case dimensionsMismatch(String)

    public var description: String {
        switch self {
        case .invalidID: return "Invalid report ID."
        case .schema(let s): return s
        case .unexpectedPart(let p): return "Unexpected attachment \(p)."
        case .missingPart(let p): return "Missing attachment \(p)."
        case .hashMismatch(let p): return "Attachment \(p) failed its integrity check."
        case .notAnImage(let p): return "Attachment \(p) is not a valid PNG."
        case .dimensionsMismatch(let p): return "Attachment \(p) has unexpected dimensions."
        }
    }
}

/// Persistent report inbox with bounded retention.
public struct ReportStore: Sendable {
    public enum SaveResult: Equatable, Sendable {
        case stored
        case duplicate
    }

    public static let allowedPartNames: Set<String> = ["original.png", "annotated.png"]
    public static let maxImageDimension = 12_000

    public let home: SBHome
    public var maxReports = 200
    public var maxAge: TimeInterval = 30 * 24 * 3600

    public init(home: SBHome) {
        self.home = home
    }

    func directory(for id: String) -> URL {
        home.reportsDirectory.appendingPathComponent(id, isDirectory: true)
    }

    /// Validates the report and its attachments before anything touches the disk.
    public static func validate(_ report: DebugReport, parts: [String: Data]) throws {
        guard ReportID.isValid(report.id) else { throw ReportValidationError.invalidID }
        do { try ReportCoding.validate(version: report.schemaVersion) } catch { throw ReportValidationError.schema("\(error)") }
        for name in parts.keys where !allowedPartNames.contains(name) { throw ReportValidationError.unexpectedPart(name) }
        for a in report.images {
            guard allowedPartNames.contains(a.fileName) else { throw ReportValidationError.unexpectedPart(a.fileName) }
            guard let data = parts[a.fileName] else { throw ReportValidationError.missingPart(a.fileName) }
            guard Hashing.sha256Hex(data) == a.sha256 else { throw ReportValidationError.hashMismatch(a.fileName) }
            guard let img = try? AnnotationRenderer.decodeImage(data) else { throw ReportValidationError.notAnImage(a.fileName) }
            guard img.width == a.pixelWidth, img.height == a.pixelHeight, img.width <= maxImageDimension, img.height <= maxImageDimension else {
                throw ReportValidationError.dimensionsMismatch(a.fileName)
            }
        }
        if report.images.count != parts.count { throw ReportValidationError.unexpectedPart("count mismatch") }
    }

    /// Stores a report atomically. A report ID that already exists is a duplicate and is
    /// not overwritten, so retries are idempotent.
    public func save(_ report: DebugReport, parts: [String: Data], receipt: ReportReceipt) throws -> SaveResult {
        try Self.validate(report, parts: parts)
        try home.prepare()
        let fm = FileManager.default
        let final = directory(for: report.id)
        if fm.fileExists(atPath: final.appendingPathComponent("report.json").path) { return .duplicate }
        let tmp = home.reportsDirectory.appendingPathComponent(".incoming-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            for (name, data) in parts { try data.write(to: tmp.appendingPathComponent(name)) }
            try JSONFile.write(receipt, to: tmp.appendingPathComponent("receipt.json"))
            try ReportCoding.encode(report, pretty: true).write(to: tmp.appendingPathComponent("report.json"))
            do {
                try fm.moveItem(at: tmp, to: final)
            } catch {
                // Lost a race with a concurrent duplicate.
                try? fm.removeItem(at: tmp)
                if fm.fileExists(atPath: final.appendingPathComponent("report.json").path) { return .duplicate }
                throw error
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        applyRetention()
        return .stored
    }

    public func load(_ id: String) throws -> StoredReport {
        guard ReportID.isValid(id) else { throw StoreError.invalid("Invalid report ID \(id).") }
        let dir = directory(for: id)
        let reportURL = dir.appendingPathComponent("report.json")
        guard FileManager.default.fileExists(atPath: reportURL.path) else { throw StoreError.notFound("No report \(id).") }
        let report = try ReportCoding.decode(Data(contentsOf: reportURL))
        let receipt = try JSONFile.read(ReportReceipt.self, from: dir.appendingPathComponent("receipt.json"))
            ?? ReportReceipt(receivedAt: report.createdAt, projectID: report.build.projectID ?? "", credentialID: "", deviceModel: report.device.model, consistencyAtReceipt: nil, inferredCandidates: [])
        return StoredReport(report: report, receipt: receipt, directory: dir)
    }

    /// Newest first. Unreadable entries are skipped.
    public func list() -> [StoredReport] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: home.reportsDirectory.path) else { return [] }
        return names.filter(ReportID.isValid).compactMap { try? load($0) }.sorted { $0.receipt.receivedAt > $1.receipt.receivedAt }
    }

    /// Resolves "latest" or an ID (case-insensitive).
    public func resolve(_ idOrLatest: String) throws -> StoredReport {
        let key = idOrLatest.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.lowercased() == "latest" {
            guard let r = list().first else { throw StoreError.notFound("There are no reports yet.") }
            return r
        }
        return try load(key.uppercased())
    }

    public func delete(_ id: String) throws {
        guard ReportID.isValid(id) else { throw StoreError.invalid("Invalid report ID \(id).") }
        let fm = FileManager.default
        let export = home.root.appendingPathComponent("Exports", isDirectory: true).appendingPathComponent(id, isDirectory: true)
        // Remove exported evidence first. If cleanup fails, keep the inbox report so
        // deletion can be retried instead of orphaning a source/screenshot copy.
        for url in [export, directory(for: id)] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    public func applyRetention(now: Date = Date()) {
        let all = list()
        for (i, r) in all.enumerated() where i >= maxReports || now.timeIntervalSince(r.receipt.receivedAt) > maxAge {
            try? delete(r.id)
        }
    }
}
