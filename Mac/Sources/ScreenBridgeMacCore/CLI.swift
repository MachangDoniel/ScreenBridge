import Foundation
import ScreenBridgeProtocol

/// `screenbridge` command-line interface. Shared by the SPM executable and the helper
/// app binary (`ScreenBridge.app/Contents/MacOS/ScreenBridge cli …`).
public enum ScreenBridgeCLI {
    public static let usage = """
    usage: screenbridge <command> [options]

    Build integration
      build-configure          Generate ScreenBridgeConnection.json (run from an Xcode Run Script phase)
      print-build-phase        Print the Run Script phase to add to your app target
      doctor [--plist PATH] [--app PATH.app]
                               Check the helper, store, Info.plist keys and a built app

    Receiver state
      projects                 List registered project roots
      credentials              List development credentials
      revoke <credential-id>   Revoke a credential (the next build issues a new one)
      reports                  List received reports
      delete-report <id>       Delete a report

    Claude
      mcp                      Run the MCP server on stdio
      mcp-config               Print the Claude Desktop configuration snippet
      install                  Install command shims pointing at this executable

    Environment: SCREENBRIDGE_HOME overrides ~/Library/Application Support/ScreenBridge
    """

    public static func run(_ args: [String], executablePath: String = CommandLine.arguments[0]) -> Int32 {
        let home = SBHome.default()
        guard let command = args.first else {
            print(usage)
            return 0
        }
        let rest = Array(args.dropFirst())
        do {
            switch command {
            case "build-configure":
                let outcome = BuildConfigurator.run(environment: ProcessInfo.processInfo.environment, home: home)
                outcome.messages.forEach { print($0) }
                return 0 // never fail the host app's build

            case "print-build-phase":
                print(BuildConfigurator.buildPhaseScript)
                print("")
                print("Output Files:  $(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/ScreenBridgeConnection.json")
                print("Build setting: ENABLE_USER_SCRIPT_SANDBOXING = NO (the script reads git state and the ScreenBridge store)")
                return 0

            case "doctor":
                return doctor(rest, home: home)

            case "projects":
                for p in try ProjectRegistry(home: home).all() {
                    print("\(p.id)\t\(p.name)\t\(p.rootPath)")
                }
                return 0

            case "credentials":
                let projects = Dictionary(uniqueKeysWithValues: try ProjectRegistry(home: home).all().map { ($0.id, $0.name) })
                for c in try CredentialStore(home: home).all() {
                    print("\(c.id)\t\(c.isActive ? "active" : "revoked")\t\(projects[c.projectID] ?? c.projectID)\t\(c.appBundleIdentifier)")
                }
                return 0

            case "revoke":
                guard let id = rest.first else { fputs("usage: screenbridge revoke <credential-id>\n", stderr); return 2 }
                try CredentialStore(home: home).revoke(id: id)
                print("Revoked \(id). Rebuild the app to issue a new credential.")
                return 0

            case "reports":
                for r in ReportStore(home: home).list() {
                    print("\(r.id)\t\(ISO8601DateFormatter().string(from: r.receipt.receivedAt))\t\(r.report.description.prefix(60))")
                }
                return 0

            case "delete-report":
                guard let id = rest.first else { fputs("usage: screenbridge delete-report <id>\n", stderr); return 2 }
                try ReportStore(home: home).delete(id)
                return 0

            case "mcp":
                MCPServer.runStdio(home: home)

            case "mcp-config":
                print(ShimInstaller.claudeDesktopSnippet(home: home))
                return 0

            case "install":
                let exe = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path
                try ShimInstaller.install(cli: [exe], mcp: [exe, "mcp"], home: home)
                print("Installed \(home.binDirectory.path)/screenbridge and screenbridge-mcp → \(exe)")
                return 0

            case "help", "-h", "--help":
                print(usage)
                return 0

            default:
                fputs("Unknown command \(command).\n\n\(usage)\n", stderr)
                return 2
            }
        } catch {
            fputs("error: \(error)\n", stderr)
            return 1
        }
    }

    static func doctor(_ args: [String], home: SBHome) -> Int32 {
        var ok = true
        func check(_ pass: Bool, _ label: String, _ fix: String? = nil) {
            print("\(pass ? "✓" : "✗") \(label)")
            if !pass, let fix { print("    → \(fix)") }
            if !pass { ok = false }
        }
        check(FileManager.default.fileExists(atPath: home.root.path), "Store exists at \(home.root.path)", "Open ScreenBridge.app once.")
        let identity = try? ReceiverIdentity.load(home)
        check(identity != nil, "Receiver identity \(identity.map { "“\($0.name)” \($0.receiverID)" } ?? "")", "Open ScreenBridge.app once.")
        let shim = home.binDirectory.appendingPathComponent("screenbridge").path
        check(FileManager.default.isExecutableFile(atPath: shim), "Build command installed at \(shim)", "Open ScreenBridge.app (it installs the command on launch).")
        let status = HelperStatus.load(home)
        check(status?.isRunning == true, "Helper running\(status?.port.map { " on port \($0)" } ?? "")", "Open ScreenBridge.app.")
        let projects = (try? ProjectRegistry(home: home).all()) ?? []
        print("• \(projects.count) registered project(s)")
        print("• Claude Desktop config mentions screenbridge: \(ShimInstaller.claudeDesktopConfigured() ? "yes" : "no (run `screenbridge mcp-config`)")")

        var i = 0
        while i < args.count {
            let flag = args[i]
            let value = i + 1 < args.count ? args[i + 1] : nil
            i += 2
            guard let value else { break }
            if flag == "--plist" {
                let plist = NSDictionary(contentsOfFile: value) as? [String: Any] ?? [:]
                check(plist["NSLocalNetworkUsageDescription"] is String, "Info.plist has NSLocalNetworkUsageDescription", "Add a Local Network usage description.")
                let services = plist["NSBonjourServices"] as? [String] ?? []
                check(services.contains(WireProtocol.serviceType), "Info.plist NSBonjourServices contains \(WireProtocol.serviceType)", "Add \(WireProtocol.serviceType) to NSBonjourServices.")
            } else if flag == "--app" {
                let url = URL(fileURLWithPath: value).appendingPathComponent("\(WireProtocol.connectionResourceName).\(WireProtocol.connectionResourceExtension)")
                if let data = try? Data(contentsOf: url), let config = try? ConnectionConfig.decode(data) {
                    check(config.receiverID == identity?.receiverID, "Built app targets this receiver (\(config.receiverName))", "Rebuild the app on this Mac.")
                    let cred = try? CredentialStore(home: home).credential(id: config.credentialID)
                    check(cred?.isActive == true, "App credential \(config.credentialID) is active", "Rebuild to issue a new credential.")
                } else {
                    check(false, "Built app contains ScreenBridgeConnection.json", "Add the build phase (`screenbridge print-build-phase`) and rebuild in Debug.")
                }
            }
        }
        return ok ? 0 : 1
    }
}
