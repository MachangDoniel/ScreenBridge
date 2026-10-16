import Foundation
import AppKit
import UserNotifications
import ScreenBridgeMacCore
import ScreenBridgeProtocol
import ScreenBridgeTransport

/// UI state for the helper. Receiver callbacks arrive off the main thread and are
/// forwarded here.
@MainActor
final class AppModel: ObservableObject {
    enum SidebarItem: Hashable {
        case reports
        case connection
    }

    @Published var sidebar: SidebarItem? = .reports
    @Published var reports: [StoredReport] = []
    @Published var selectedReportID: String?
    @Published var sessions: [AppSession] = []
    @Published var listenerStatus: ReceiverListener.Status = .stopped
    @Published var startupError: String?
    @Published var projects: [RegisteredProject] = []
    @Published var credentials: [StoredCredential] = []
    @Published var notificationsAuthorized: Bool?
    @Published var toast: String?
    @Published var handoffMessages: [String: String] = [:]

    let home = SBHome.default()
    private(set) var identity: ReceiverIdentity?
    private var service: ReceiverService?

    var receiverName: String { identity?.name ?? Host.current().localizedName ?? "This Mac" }

    func start() {
        installCommandShims()
        var events = ReceiverService.Events()
        events.reportReceived = { [weak self] stored in
            Task { @MainActor in self?.reportArrived(stored) }
        }
        events.sessionsChanged = { [weak self] s in
            Task { @MainActor in self?.sessions = s }
        }
        events.statusChanged = { [weak self] status in
            Task { @MainActor in self?.listenerStatus = status }
        }
        do {
            let s = try ReceiverService(home: home, events: events)
            identity = s.identity
            try s.start()
            service = s
        } catch {
            startupError = "The receiver could not start: \(error)"
        }
        refresh()
        requestNotificationPermission()
    }

    func stop() {
        service?.stop()
    }

    func refresh() {
        reports = ReportStore(home: home).list()
        projects = (try? ProjectRegistry(home: home).all()) ?? []
        credentials = ((try? CredentialStore(home: home).all()) ?? []).sorted { $0.createdAt > $1.createdAt }
        if let sel = selectedReportID, !reports.contains(where: { $0.id == sel }) { selectedReportID = reports.first?.id }
        if selectedReportID == nil { selectedReportID = reports.first?.id }
    }

    var selectedReport: StoredReport? {
        reports.first { $0.id == selectedReportID }
    }

    func project(for report: StoredReport) -> RegisteredProject? {
        projects.first { $0.id == report.receipt.projectID }
    }

    private func reportArrived(_ stored: StoredReport) {
        refresh()
        selectedReportID = stored.id
        sidebar = .reports
        postNotification(for: stored)
        if let destination = stored.report.claudeDestination, destination != .inbox {
            openClaude(for: stored, destination: destination)
        }
    }

    // MARK: Actions

    func delete(_ id: String) {
        do {
            try ReportStore(home: home).delete(id)
            handoffMessages[id] = nil
            if selectedReportID == id { selectedReportID = nil }
            refresh()
        } catch { show("Could not delete report: \(error)") }
    }

    func revoke(_ credential: StoredCredential) {
        do {
            try CredentialStore(home: home).revoke(id: credential.id)
            service?.reloadCredentials()
            show("Revoked. Rebuild the app to issue a new credential.")
        } catch {
            show("Couldn't revoke: \(error)")
        }
        refresh()
    }

    func reveal(_ anchor: SourceAnchor, in report: StoredReport) {
        guard let path = anchor.path, anchor.pathStatus == .repositoryRelative else { return }
        let projectID = report.receipt.projectID
        let home = self.home
        Task.detached {
            let result = SourceRevealer.reveal(projectID: projectID, path: path, line: anchor.line, home: home)
            await MainActor.run { self.show(result.message) }
        }
    }

    static func claudeRequest(for id: String) -> String {
        ClaudeHandoff.request(for: id)
    }

    func copyRequest(for id: String) {
        NSPasteboard.general.clearContents()
        let stored = try? ReportStore(home: home).load(id)
        let reference = ClaudeHandoff.request(for: id, reportURL: stored?.directory.appendingPathComponent("report.json"))
        NSPasteboard.general.setString(reference, forType: .string)
        show("Copied report reference. Paste it into your AI coding tool.")
    }

    func copyScreenshot(for stored: StoredReport) {
        guard let url = stored.imageURL(.annotated), let image = NSImage(contentsOf: url) else {
            show("This report has no screenshot.")
            return
        }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.writeObjects([image]) else {
            show("Could not copy the screenshot.")
            return
        }
        show("Screenshot copied. Paste into Claude with ⌘V to attach it.")
    }

    func configureClaudeDesktop() {
        let config = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        do {
            try ClaudeHandoff.configureDesktop(command: ShimInstaller.mcpCommandPath(home: home), at: config)
            objectWillChange.send()
            show("ScreenBridge configured. Quit and reopen Claude Desktop to load the connector.")
        } catch { show("Could not configure Claude Desktop: \(error)") }
    }

    func deleteAllReports() {
        for id in reports.map(\.id) { delete(id) }
    }

    func openClaude(for stored: StoredReport, destination: ClaudeDestination = .desktop) {
        guard destination != .inbox else { return }
        if destination == .reference {
            copyRequest(for: stored.id)
            let message = FocusedReferencePaster.pasteFromClipboard()
            handoffMessages[stored.id] = message
            show(message)
            if notificationsAuthorized == true {
                let content = UNMutableNotificationContent()
                content.title = "ScreenBridge report \(stored.id)"
                content.body = message
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: stored.id, content: content, trigger: nil))
            }
            return
        }
        let root = project(for: stored)?.rootPath
        do {
            var prompt = ClaudeHandoff.request(for: stored.id, description: stored.report.description)
            if destination == .browser {
                let folder = try ClaudeHandoff.export(stored, projectRoot: root, home: home)
                prompt = try String(contentsOf: folder.appendingPathComponent("report.md"), encoding: .utf8)
                NSWorkspace.shared.open(folder)
            } else if destination == .code {
                prompt = ClaudeHandoff.request(for: stored.id,
                                               reportURL: stored.directory.appendingPathComponent("report.json"))
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(prompt, forType: .string)
            guard let url = ClaudeHandoff.url(destination: destination, prompt: prompt, projectRoot: root),
                  NSWorkspace.shared.urlForApplication(toOpen: url) != nil,
                  NSWorkspace.shared.open(url) else {
                let message = "Could not open \(destination.title). Install Claude Desktop or choose the browser option. Your report is saved and the handoff is copied to the clipboard."
                handoffMessages[stored.id] = message
                show(message)
                return
            }
            let message: String
            if destination == .code {
                message = "Opened Claude Code with a short report reference. Type what should change in its chat."
            } else if destination == .browser {
                message = "Opened Claude in your browser. Paste the copied report and attach PNG files from the export folder."
            } else if destination == .desktop && !claudeDesktopConfigured {
                message = "Opened Claude Desktop with a prepared prompt. Configure ScreenBridge in Connection, then restart Claude to enable report and screenshot access."
            } else {
                message = "Requested \(destination.title) with a prepared prompt. Review and send it in Claude."
            }
            handoffMessages[stored.id] = message
            show(message)
        } catch {
            let message = "Could not prepare Claude handoff: \(error). Your report remains in the inbox."
            handoffMessages[stored.id] = message
            show(message)
        }
    }

    func copyMCPConfig() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ShimInstaller.claudeDesktopSnippet(home: home), forType: .string)
        show("Copied the Claude Desktop MCP configuration.")
    }

    func openStoreFolder() {
        NSWorkspace.shared.open(home.root)
    }

    func show(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if toast == message { toast = nil }
        }
    }

    var mcpInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: ShimInstaller.mcpCommandPath(home: home))
    }

    var claudeDesktopConfigured: Bool { ShimInstaller.claudeDesktopConfigured() }

    /// The build phase and Claude call stable paths in the store's bin directory; point
    /// them at this app's binary every launch so moving the app keeps them working.
    private func installCommandShims() {
        guard let exe = Bundle.main.executablePath else { return }
        do {
            try ShimInstaller.install(cli: [exe, "cli"], mcp: [exe, "mcp"], home: home)
        } catch {
            startupError = "Couldn't install command shims: \(error)"
        }
    }

    // MARK: Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.notificationsAuthorized = granted }
        }
    }

    private func postNotification(for stored: StoredReport) {
        // The inbox works regardless; notifications are best-effort.
        guard notificationsAuthorized == true else { return }
        let content = UNMutableNotificationContent()
        content.title = "Report \(stored.id) received"
        content.body = stored.report.description.isEmpty ? "From \(stored.report.app.name) on \(stored.report.device.model)" : String(stored.report.description.prefix(140))
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: stored.id, content: content, trigger: nil))
    }
}
