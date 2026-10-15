import Foundation
import ScreenBridgeProtocol

/// Runs a subprocess and captures stdout. Never uses a shell.
enum Subprocess {
    struct Result {
        var status: Int32
        var stdout: Data
        var stderr: Data
        var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    }

    static func run(_ executable: String, _ args: [String], cwd: URL? = nil, stdin: Data? = nil, env: [String: String] = [:], timeout: TimeInterval = 30) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        var environment = ProcessInfo.processInfo.environment
        for (k, v) in env { environment[k] = v }
        p.environment = environment
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let inPipe = Pipe()
        p.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe
        try p.run()
        if let stdin {
            inPipe.fileHandleForWriting.write(stdin)
            try? inPipe.fileHandleForWriting.close()
        }
        // Drain both pipes on dedicated threads (not the GCD pool, which blocking reads
        // can starve when many subprocesses run at once) to avoid pipe-buffer deadlocks.
        let collector = OutputCollector()
        let done = DispatchSemaphore(value: 0)
        let outReader = Thread {
            collector.out = out.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        let errReader = Thread {
            collector.err = err.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        outReader.start()
        errReader.start()
        let deadline = DispatchTime.now() + timeout
        if done.wait(timeout: deadline) == .timedOut || done.wait(timeout: deadline) == .timedOut {
            p.terminate()
            throw StoreError.io("\(executable) \(args.first ?? "") timed out")
        }
        p.waitUntilExit()
        return Result(status: p.terminationStatus, stdout: collector.out, stderr: collector.err)
    }

    private final class OutputCollector: @unchecked Sendable {
        var out = Data()
        var err = Data()
    }
}

/// State of a git working tree at one moment.
public struct GitState: Codable, Sendable, Equatable {
    public var commit: String?
    public var branch: String?
    public var isDirty: Bool
    /// sha256 over commit, porcelain status, `git diff HEAD` and untracked file hashes.
    /// Equal fingerprints mean equal working-tree contents (for non-ignored files).
    public var fingerprint: String
    /// Repository-relative path → git blob hash of the *working-tree* content, for
    /// tracked and untracked (non-ignored) Swift files.
    public var swiftFileHashes: [String: String]
}

public enum GitInspector {
    static let git = "/usr/bin/git"
    // Avoid taking index.lock during builds (`git status` would otherwise refresh the index).
    static let env = ["GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C"]

    public static func repositoryRoot(containing dir: URL) -> URL? {
        guard let r = try? Subprocess.run(git, ["rev-parse", "--show-toplevel"], cwd: dir, env: env), r.status == 0 else { return nil }
        let path = r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    public static func state(of root: URL, maxFiles: Int = 20_000) throws -> GitState? {
        func run(_ args: [String], stdin: Data? = nil) throws -> Subprocess.Result {
            try Subprocess.run(git, args, cwd: root, stdin: stdin, env: env)
        }
        guard try run(["rev-parse", "--is-inside-work-tree"]).status == 0 else { return nil }
        let head = try run(["rev-parse", "--verify", "--quiet", "HEAD"])
        let commit = head.status == 0 ? head.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let branchR = try run(["symbolic-ref", "--quiet", "--short", "HEAD"])
        let branch = branchR.status == 0 ? branchR.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) : nil

        let status = try run(["status", "--porcelain=v1", "-z", "--untracked-files=all"]).stdout
        let diff = commit != nil ? try run(["diff", "HEAD", "--binary", "--no-color", "--no-ext-diff"]).stdout : Data()
        let untrackedList = try run(["ls-files", "--others", "--exclude-standard", "-z"]).stdout
        let untrackedPaths = split0(untrackedList).prefix(maxFiles)
        let untrackedHashes = try hashObjects(Array(untrackedPaths), root: root)

        var hasher = Data()
        hasher.append(Data((commit ?? "no-commit").utf8)); hasher.append(0)
        hasher.append(status); hasher.append(0)
        hasher.append(diff); hasher.append(0)
        for p in untrackedPaths.sorted() {
            hasher.append(Data("\(p)=\(untrackedHashes[p] ?? "?")\n".utf8))
        }

        let swiftList = try run(["ls-files", "-co", "--exclude-standard", "-z", "--", "*.swift"]).stdout
        let swiftPaths = Array(Set(split0(swiftList)).sorted().prefix(maxFiles))
        let swiftHashes = try hashObjects(swiftPaths, root: root)

        return GitState(commit: commit, branch: branch, isDirty: !status.isEmpty, fingerprint: Hashing.sha256Hex(hasher), swiftFileHashes: swiftHashes)
    }

    /// Blob hash of a single working-tree file (nil if missing).
    public static func hashFile(_ relativePath: String, root: URL) -> String? {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path) else { return nil }
        return (try? hashObjects([relativePath], root: root))?[relativePath]
    }

    static func hashObjects(_ paths: [String], root: URL) throws -> [String: String] {
        let existing = paths.filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
        guard !existing.isEmpty else { return [:] }
        let input = Data(existing.joined(separator: "\n").utf8 + [10])
        let r = try Subprocess.run(git, ["hash-object", "--no-filters", "--stdin-paths"], cwd: root, stdin: input, env: env, timeout: 60)
        guard r.status == 0 else { return [:] }
        let hashes = r.stdoutString.split(separator: "\n").map(String.init)
        guard hashes.count == existing.count else { return [:] }
        return Dictionary(uniqueKeysWithValues: zip(existing, hashes))
    }

    private static func split0(_ data: Data) -> [String] {
        data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.filter { !$0.isEmpty }
    }
}

/// What the build integration recorded about the source tree at build time.
/// Kept on the Mac; only the build ID, commit, dirty flag and fingerprint enter the app.
public struct BuildSnapshot: Codable, Sendable, Equatable {
    public var buildID: String
    public var projectID: String
    public var configuration: String
    public var appBundleIdentifier: String
    public var createdAt: Date
    public var git: GitState?
}

public struct BuildSnapshotStore: Sendable {
    public let home: SBHome
    public var retain = 100

    public init(home: SBHome) {
        self.home = home
    }

    public func save(_ s: BuildSnapshot) throws {
        guard Self.isSafeID(s.buildID) else { throw StoreError.invalid("Invalid build ID") }
        try home.prepare()
        try JSONFile.write(s, to: home.buildsDirectory.appendingPathComponent("\(s.buildID).json"), permissions: 0o644)
        prune()
    }

    public func load(_ buildID: String) -> BuildSnapshot? {
        guard Self.isSafeID(buildID) else { return nil }
        return try? JSONFile.read(BuildSnapshot.self, from: home.buildsDirectory.appendingPathComponent("\(buildID).json"))
    }

    static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    private func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: home.buildsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        guard files.count > retain else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        for f in sorted.prefix(files.count - retain) { try? fm.removeItem(at: f) }
    }
}

// MARK: - Consistency

public struct FileConsistency: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case unchanged
        case changedSinceBuild
        case missing
        case unknown
    }

    public var path: String
    public var status: Status
    public var note: String?
}

/// How the current repository relates to the source the app was built from.
public struct SourceConsistency: Codable, Sendable, Equatable {
    public enum Overall: String, Codable, Sendable {
        /// Same commit and identical working-tree contents.
        case exactMatch
        /// Same commit, but uncommitted changes differ from the build.
        case sameCommitWorkingTreeChanged
        /// HEAD moved since the build.
        case differentCommit
        /// Not enough information (no build snapshot, not a git repo, unconfigured build).
        case unknown
    }

    public var overall: Overall
    public var summary: String
    public var buildCommit: String?
    public var currentCommit: String?
    public var buildDirty: Bool?
    public var currentDirty: Bool?
    public var files: [FileConsistency]
    public var evaluatedAt: Date

    public static func evaluate(build: BuildInfo, snapshot: BuildSnapshot?, current: GitState?, anchorPaths: [String], now: Date = Date()) -> SourceConsistency {
        let paths = Array(Set(anchorPaths)).sorted()
        func files(_ status: FileConsistency.Status, _ note: String?) -> [FileConsistency] {
            paths.map { FileConsistency(path: $0, status: status, note: note) }
        }
        guard build.configured else {
            return SourceConsistency(overall: .unknown, summary: "The app was built without ScreenBridge build integration, so its source state is unknown.", buildCommit: nil, currentCommit: current?.commit, buildDirty: nil, currentDirty: current?.isDirty, files: files(.unknown, nil), evaluatedAt: now)
        }
        guard let current else {
            return SourceConsistency(overall: .unknown, summary: "The project is not a git repository (or git failed), so source consistency can't be checked.", buildCommit: build.gitCommit, currentCommit: nil, buildDirty: build.isDirty, currentDirty: nil, files: files(.unknown, nil), evaluatedAt: now)
        }
        guard let buildCommit = build.gitCommit, let currentCommit = current.commit else {
            return SourceConsistency(overall: .unknown, summary: "No commit recorded for the build or the repository has no commits.", buildCommit: build.gitCommit, currentCommit: current.commit, buildDirty: build.isDirty, currentDirty: current.isDirty, files: files(.unknown, nil), evaluatedAt: now)
        }

        let overall: Overall
        let summary: String
        if buildCommit != currentCommit {
            overall = .differentCommit
            summary = "HEAD is now \(currentCommit.prefix(10)); the app was built from \(buildCommit.prefix(10)). Linked lines may have moved."
        } else if let fp = build.workingTreeFingerprint, fp == current.fingerprint {
            overall = .exactMatch
            summary = (build.isDirty ?? false)
                ? "Same commit and the same uncommitted changes as the build."
                : "Same commit and a clean working tree, exactly as built."
        } else if build.workingTreeFingerprint == nil {
            overall = .unknown
            summary = "Same commit, but the build recorded no working-tree fingerprint."
        } else {
            overall = .sameCommitWorkingTreeChanged
            summary = "Same commit, but uncommitted changes differ from what was built."
        }

        let fileResults: [FileConsistency] = paths.map { path in
            guard let snap = snapshot?.git else {
                return FileConsistency(path: path, status: .unknown, note: "No build snapshot on this Mac.")
            }
            let now = current.swiftFileHashes[path]
            let then = snap.swiftFileHashes[path]
            switch (then, now) {
            case (nil, nil): return FileConsistency(path: path, status: .unknown, note: "Not tracked as a Swift source file.")
            case (_?, nil): return FileConsistency(path: path, status: .missing, note: "File no longer exists.")
            case (nil, _?): return FileConsistency(path: path, status: .unknown, note: "File did not exist at build time.")
            case (let a?, let b?): return FileConsistency(path: path, status: a == b ? .unchanged : .changedSinceBuild, note: nil)
            }
        }
        return SourceConsistency(overall: overall, summary: summary, buildCommit: buildCommit, currentCommit: currentCommit, buildDirty: build.isDirty, currentDirty: current.isDirty, files: fileResults, evaluatedAt: now)
    }
}
