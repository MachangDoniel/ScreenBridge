import Foundation
import ScreenBridgeProtocol

public enum SourceAccessError: Error, Equatable, CustomStringConvertible {
    case emptyPath
    case absolutePath
    case traversal
    case outsideRoot
    case notFound(String)
    case notAFile
    case tooLarge(Int)
    case binary

    public var description: String {
        switch self {
        case .emptyPath: return "Path is empty."
        case .absolutePath: return "Absolute paths are not allowed; use a path relative to the project root."
        case .traversal: return "Paths may not contain '..' components."
        case .outsideRoot: return "Path resolves outside the registered project root."
        case .notFound(let p): return "File not found: \(p)"
        case .notAFile: return "Path is not a regular file."
        case .tooLarge(let n): return "File is too large (\(n) bytes)."
        case .binary: return "File appears to be binary."
        }
    }
}

/// Read-only access to files under a registered project root.
///
/// Rules: relative paths only, no `..` components, symlinks resolved on both the root
/// and the target, and the resolved target must lie strictly inside the resolved root.
public struct SourceAccess: Sendable {
    public let root: URL
    public var maxBytes = 2 * 1024 * 1024

    public init(root: String) {
        self.root = URL(fileURLWithPath: root, isDirectory: true)
    }

    public func resolve(_ relativePath: String) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SourceAccessError.emptyPath }
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else { throw SourceAccessError.absolutePath }
        guard !trimmed.contains("\0") else { throw SourceAccessError.traversal }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains("..") else { throw SourceAccessError.traversal }

        let realRoot = Self.realpath(root.path) ?? root.standardizedFileURL.path
        let candidate = URL(fileURLWithPath: realRoot, isDirectory: true).appendingPathComponent(trimmed)
        guard let realTarget = Self.realpath(candidate.path) else { throw SourceAccessError.notFound(trimmed) }
        let prefix = realRoot.hasSuffix("/") ? realRoot : realRoot + "/"
        guard realTarget.hasPrefix(prefix) else { throw SourceAccessError.outsideRoot }
        return URL(fileURLWithPath: realTarget)
    }

    public struct Excerpt: Sendable, Equatable {
        public var path: String
        public var startLine: Int
        public var endLine: Int
        public var totalLines: Int
        public var text: String
    }

    /// Reads a line range (1-based, inclusive) with line numbers prefixed.
    public func read(_ relativePath: String, startLine: Int? = nil, endLine: Int? = nil, maxLines: Int = 400) throws -> Excerpt {
        let url = try resolve(relativePath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { throw SourceAccessError.notAFile }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maxBytes else { throw SourceAccessError.tooLarge(size) }
        let data = try Data(contentsOf: url)
        guard !data.prefix(8192).contains(0) else { throw SourceAccessError.binary }
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        let total = lines.count
        let start = max(1, min(startLine ?? 1, max(total, 1)))
        let requestedEnd = endLine ?? (start + maxLines - 1)
        let end = max(start, min(total, requestedEnd, start + maxLines - 1))
        let width = String(end).count
        let body = (start...end).map { n in
            let num = String(n)
            return String(repeating: " ", count: width - num.count) + num + "  " + lines[n - 1]
        }.joined(separator: "\n")
        return Excerpt(path: relativePath, startLine: start, endLine: end, totalLines: total, text: body)
    }

    static func realpath(_ path: String) -> String? {
        guard let p = Darwin.realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }
}

/// Unverified repository search for types that have no registered file.
public enum CandidateFinder {
    static let skippedDirectories: Set<String> = [".git", ".build", "DerivedData", "Pods", "Carthage", "node_modules", "build", ".swiftpm"]

    public static func candidates(forType name: String, root: String, maxFiles: Int = 5000, maxResults: Int = 5) -> [SourceAnchor] {
        guard name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else { return [] }
        let pattern = try? NSRegularExpression(pattern: #"^\s*(?:(?:public|internal|private|fileprivate|open|final|@MainActor|@Observable)\s+)*(?:class|struct|enum|actor|protocol|extension)\s+"# + name + #"\b"#, options: [.anchorsMatchLines])
        guard let pattern else { return [] }
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard let e = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var results: [SourceAnchor] = []
        var scanned = 0
        while let url = e.nextObject() as? URL {
            if skippedDirectories.contains(url.lastPathComponent) { e.skipDescendants(); continue }
            guard url.pathExtension == "swift" else { continue }
            scanned += 1
            if scanned > maxFiles { break }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            guard let m = pattern.firstMatch(in: text, range: range), let r = Range(m.range, in: text) else { continue }
            let line = text[..<r.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            let rel = String(url.standardizedFileURL.path.dropFirst(rootURL.standardizedFileURL.path.count + 1))
            results.append(SourceAnchor(symbol: name, role: "candidate", path: rel, line: line, pathStatus: .repositoryRelative, evidence: .inferredCandidate, note: "Found by searching the repository for a declaration of \(name). Not verified."))
            if results.count >= maxResults { break }
        }
        return results
    }
}
