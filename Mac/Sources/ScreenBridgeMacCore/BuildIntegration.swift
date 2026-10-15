import Foundation
import ScreenBridgeProtocol

/// Implements `screenbridge build-configure`, run from an Xcode Run Script phase.
///
/// It never fails the build: every problem becomes an Xcode `warning:` line and the
/// app simply launches without a Mac connection.
public enum BuildConfigurator {
    public struct Outcome {
        public var messages: [String]
        public var outputPath: String?
        public var config: ConnectionConfig?
    }

    public static let defaultConfigurations = ["Debug"]

    public static func run(environment env: [String: String], home: SBHome = .default()) -> Outcome {
        var messages: [String] = []
        let configuration = env["CONFIGURATION"] ?? "Debug"
        let enabledConfigs = (env["SCREENBRIDGE_CONFIGURATIONS"].map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }) ?? defaultConfigurations
        let output = outputPath(env)

        guard enabledConfigs.contains(configuration) else {
            if let output { try? FileManager.default.removeItem(atPath: output) }
            messages.append("note: ScreenBridge is disabled for the \(configuration) configuration; no connection file was generated.")
            return Outcome(messages: messages, outputPath: nil, config: nil)
        }
        guard let output else {
            messages.append("warning: ScreenBridge: TARGET_BUILD_DIR/UNLOCALIZED_RESOURCES_FOLDER_PATH are not set. Run this from an Xcode Run Script phase.")
            return Outcome(messages: messages, outputPath: nil, config: nil)
        }
        guard let bundleID = env["PRODUCT_BUNDLE_IDENTIFIER"], !bundleID.isEmpty else {
            messages.append("warning: ScreenBridge: PRODUCT_BUNDLE_IDENTIFIER is not set.")
            return Outcome(messages: messages, outputPath: nil, config: nil)
        }
        let srcRoot = URL(fileURLWithPath: env["SRCROOT"] ?? FileManager.default.currentDirectoryPath, isDirectory: true)

        do {
            let projectRoot = GitInspector.repositoryRoot(containing: srcRoot) ?? srcRoot
            let identity = try ReceiverIdentity.loadOrCreate(home)
            let project = try ProjectRegistry(home: home).register(root: projectRoot, buildAt: Date())
            let credential = try CredentialStore(home: home).issue(projectID: project.id, appBundleIdentifier: bundleID)
            let gitState = try? GitInspector.state(of: URL(fileURLWithPath: project.rootPath, isDirectory: true))
            if gitState == nil {
                messages.append("warning: ScreenBridge: \(project.rootPath) is not a git repository; reports will show source consistency as unknown.")
            }
            let buildID = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16)
            let snapshot = BuildSnapshot(buildID: String(buildID), projectID: project.id, configuration: configuration, appBundleIdentifier: bundleID, createdAt: Date(), git: gitState)
            try BuildSnapshotStore(home: home).save(snapshot)

            let build = BuildInfo(buildID: String(buildID), configuration: configuration, projectID: project.id, projectName: project.name,
                                  gitCommit: gitState?.commit, gitBranch: gitState?.branch, isDirty: gitState?.isDirty,
                                  workingTreeFingerprint: gitState?.fingerprint, builtAt: Date(), configured: true)
            let config = ConnectionConfig(receiverID: identity.receiverID, receiverName: identity.name, credentialID: credential.id,
                                          pskBase64: credential.keyBase64, projectID: project.id, projectName: project.name,
                                          projectRoot: project.rootPath, appBundleIdentifier: bundleID, build: build)
            let data = try ReportCoding.encoder(pretty: true).encode(config)
            try FileManager.default.createDirectory(atPath: (output as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: output), options: .atomic)

            let dirty = gitState.map { $0.isDirty ? ", uncommitted changes" : ", clean" } ?? ""
            messages.append("note: ScreenBridge: configured \(bundleID) for receiver “\(identity.name)” (project \(project.name), commit \(gitState?.commit?.prefix(10) ?? "unknown")\(dirty)).")
            if let status = HelperStatus.load(home), status.isRunning, status.receiverID == identity.receiverID {
                // Helper is running and will pick up new credentials automatically.
            } else {
                messages.append("warning: ScreenBridge helper is not running on this Mac. Open ScreenBridge.app; reports will queue on the device until it is reachable.")
            }
            return Outcome(messages: messages, outputPath: output, config: config)
        } catch {
            try? FileManager.default.removeItem(atPath: output)
            messages.append("warning: ScreenBridge could not configure this build (\(error)). The app will run without a Mac connection.")
            return Outcome(messages: messages, outputPath: nil, config: nil)
        }
    }

    static func outputPath(_ env: [String: String]) -> String? {
        if let declared = env["SCRIPT_OUTPUT_FILE_0"], !declared.isEmpty { return declared }
        guard let dir = env["TARGET_BUILD_DIR"], let res = env["UNLOCALIZED_RESOURCES_FOLDER_PATH"] else { return nil }
        return "\(dir)/\(res)/\(WireProtocol.connectionResourceName).\(WireProtocol.connectionResourceExtension)"
    }

    /// The Run Script phase body users paste into Xcode.
    public static let buildPhaseScript = #"""
    # ScreenBridge — generates the development connection file (Debug only).
    # Output Files: $(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/ScreenBridgeConnection.json
    # Uncheck "Based on dependency analysis": git state is not an Xcode-tracked input.
    SB="${HOME}/Library/Application Support/ScreenBridge/bin/screenbridge"
    if [ -x "$SB" ]; then
      "$SB" build-configure
    else
      echo "warning: ScreenBridge helper is not installed. Open ScreenBridge.app once, then rebuild. The app will run without a Mac connection."
      rm -f "${SCRIPT_OUTPUT_FILE_0}"
    fi
    """#
}

/// Installs the stable command paths the build phase and Claude use.
public enum ShimInstaller {
    public static func install(cli: [String], mcp: [String], home: SBHome = .default()) throws {
        try home.prepare()
        try write(home.binDirectory.appendingPathComponent("screenbridge"), command: cli)
        try write(home.binDirectory.appendingPathComponent("screenbridge-mcp"), command: mcp)
    }

    static func write(_ url: URL, command: [String]) throws {
        let quoted = command.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let script = "#!/bin/sh\n# Installed by ScreenBridge. Re-created each time the helper launches.\nexec \(quoted) \"$@\"\n"
        try Data(script.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    public static func mcpCommandPath(home: SBHome = .default()) -> String {
        home.binDirectory.appendingPathComponent("screenbridge-mcp").path
    }

    public static func claudeDesktopSnippet(home: SBHome = .default()) -> String {
        let obj: [String: Any] = ["mcpServers": ["screenbridge": ["command": mcpCommandPath(home: home), "args": [String]()]]]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Whether Claude Desktop's config mentions a `screenbridge` server (read-only check).
    public static func claudeDesktopConfigured() -> Bool {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = obj["mcpServers"] as? [String: Any] else { return false }
        return servers["screenbridge"] != nil
    }
}
