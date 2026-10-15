import SwiftUI
import AppKit
import ScreenBridgeMacCore

/// One binary, three roles:
///   ScreenBridge            → menu-bar helper app
///   ScreenBridge cli …      → `screenbridge` command (build phase, doctor, revoke …)
///   ScreenBridge mcp        → MCP server on stdio for Claude
@main
enum EntryPoint {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "cli":
            exit(ScreenBridgeCLI.run(Array(args.dropFirst()), executablePath: CommandLine.arguments[0]))
        case "mcp":
            MCPServer.runStdio()
        default:
            ScreenBridgeHelperApp.main()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }
}

struct ScreenBridgeHelperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: delegate.model)
        } label: {
            MenuBarLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.menu)

        Window("ScreenBridge", id: "inbox") {
            InboxView(model: delegate.model)
                .frame(minWidth: 880, minHeight: 560)
                .onAppear { delegate.model.refresh() }
        }
        .defaultSize(width: 1100, height: 720)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Image(systemName: model.sessions.isEmpty ? "viewfinder" : "viewfinder.circle.fill")
            .accessibilityLabel("ScreenBridge")
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine)
        if let err = model.startupError { Text(err) }
        Divider()
        Button("Open Inbox") { open(nil) }
            .keyboardShortcut("i")
        if !model.reports.isEmpty {
            Section("Recent reports") {
                ForEach(model.reports.prefix(5)) { r in
                    Button("\(r.id) — \(r.report.description.isEmpty ? r.report.app.name : String(r.report.description.prefix(40)))") { open(r.id) }
                }
            }
        }
        Divider()
        Button("Connection…") {
            model.sidebar = .connection
            open(nil)
        }
        Button("Quit ScreenBridge") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch model.listenerStatus {
        case .ready: return "Receiving as “\(model.receiverName)” · \(model.sessions.count) app\(model.sessions.count == 1 ? "" : "s") connected"
        case .starting: return "Starting receiver…"
        case .failed(let e): return "Receiver failed: \(e)"
        case .stopped: return "Receiver stopped"
        }
    }

    private func open(_ id: String?) {
        if let id {
            model.sidebar = .reports
            model.selectedReportID = id
        }
        openWindow(id: "inbox")
        NSApp.activate(ignoringOtherApps: true)
    }
}
