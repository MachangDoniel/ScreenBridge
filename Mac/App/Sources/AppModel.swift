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
    }

    // MARK: Actions

    func delete(_ id: String) {
        try? ReportStore(home: home).delete(id)
        if selectedReportID == id { selectedReportID = nil }
        refresh()
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
        "Read ScreenBridge report \(id), inspect its screenshot and linked source, and propose a fix."
    }

    func copyRequest(for id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.claudeRequest(for: id), forType: .string)
        show("Copied the Claude request to the clipboard.")
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
