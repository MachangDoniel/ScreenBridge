import SwiftUI
import AppKit
import ScreenBridgeMacCore
import ScreenBridgeProtocol

struct InboxView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.sidebar) {
                Label("Reports", systemImage: "tray.full")
                    .badge(model.reports.count)
                    .tag(AppModel.SidebarItem.reports)
                Label("Connection", systemImage: "antenna.radiowaves.left.and.right")
                    .tag(AppModel.SidebarItem.connection)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } content: {
            switch model.sidebar ?? .reports {
            case .reports:
                ReportListView(model: model)
                    .navigationSplitViewColumnWidth(min: 260, ideal: 300)
            case .connection:
                ConnectionView(model: model)
                    .navigationSplitViewColumnWidth(min: 420, ideal: 520)
            }
        } detail: {
            if model.sidebar == .connection {
                Color.clear
            } else if let report = model.selectedReport {
                ReportDetailView(model: model, stored: report)
                    .id(report.id)
            } else {
                ContentUnavailableView("No report selected", systemImage: "tray", description: Text("Reports sent from the iPhone inspector appear here."))
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(.default, value: model.toast)
    }
}

struct ReportListView: View {
    @ObservedObject var model: AppModel
    @State private var confirmingDeleteAll = false

    var body: some View {
        Group {
            if model.reports.isEmpty {
                ContentUnavailableView {
                    Label("No reports yet", systemImage: "iphone.and.arrow.forward")
                } description: {
                    Text("Run your app from Xcode, tap the ScreenBridge button, choose Report a change, then Send to Mac.")
                }
            } else {
                List(selection: $model.selectedReportID) {
                    ForEach(model.reports) { r in
                        ReportRow(stored: r, projectName: model.project(for: r)?.name)
                            .tag(r.id)
                            .contextMenu {
                                Button("Copy report reference") { model.copyRequest(for: r.id) }
                                Button("Delete", role: .destructive) { model.delete(r.id) }
                            }
                    }
                    .onDelete { idx in
                        for i in idx { model.delete(model.reports[i].id) }
                    }
                }
            }
        }
        .navigationTitle("Reports")
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
            }
            ToolbarItem {
                Button("Delete all reports", systemImage: "trash", role: .destructive) {
                    confirmingDeleteAll = true
                }
                .disabled(model.reports.isEmpty)
            }
        }
        .confirmationDialog("Delete all reports and their saved screenshots?", isPresented: $confirmingDeleteAll) {
            Button("Delete all reports", role: .destructive) { model.deleteAllReports() }
        } message: {
            Text("This removes the inbox reports and their exported files from this Mac.")
        }
    }
}

struct ReportRow: View {
    let stored: StoredReport
    let projectName: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let url = stored.imageURL(.annotated), let img = NSImage(contentsOf: url) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 36, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(stored.report.description.isEmpty ? "(No description)" : stored.report.description)
                    .lineLimit(2)
                    .font(.body)
                Text("\(stored.id) · \(stored.receipt.receivedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text([projectName, stored.report.selection?.displayName ?? stored.report.screen?.owningController].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Detail

struct ReportDetailView: View {
    @ObservedObject var model: AppModel
    let stored: StoredReport
    @State private var showOriginal = false
    @State private var consistency: SourceConsistency?
    @State private var preparing = false

    private var report: DebugReport { stored.report }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                HStack {
                    Text("Saved files: \(stored.directory.path)")
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Button("Show saved files", systemImage: "folder") {
                        NSWorkspace.shared.open(stored.directory)
                    }
                }
                if let message = model.handoffMessages[stored.id] {
                    Label(message, systemImage: "paperplane").font(.callout).foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 24) {
                    screenshot
                        .frame(maxWidth: 360)
                    VStack(alignment: .leading, spacing: 20) {
                        descriptionSection
                        sourceSection
                        consistencySection
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                contextSection
            }
            .padding(24)
        }
        .navigationTitle(report.id)
        .toolbar {
            ToolbarItemGroup {
                Button("Reveal source", systemImage: "chevron.left.forwardslash.chevron.right") {
                    if let a = primaryAnchor { model.reveal(a, in: stored) }
                }
                .disabled(primaryAnchor == nil || model.project(for: stored) == nil)
                .help(primaryAnchor.map { "Open \($0.path ?? "")\($0.line.map { ":\($0)" } ?? "") in Xcode" } ?? "No registered source file")
                Button("AI tools", systemImage: "sparkles") { preparing = true }
                Button("Copy request", systemImage: "doc.on.doc") { model.copyRequest(for: report.id) }
                Button("Delete", systemImage: "trash", role: .destructive) { model.delete(report.id) }
            }
        }
        .sheet(isPresented: $preparing) {
            PrepareForClaudeSheet(model: model, reportID: report.id)
        }
        .task {
            // Recompute against the repository as it is now.
            guard let project = model.project(for: stored) else { return }
            let home = model.home
            let r = report
            consistency = await Task.detached { ReceiverService.consistency(for: r, root: project.rootPath, home: home) }.value
        }
    }

    private var primaryAnchor: SourceAnchor? {
        report.sourceAnchors.first { $0.pathStatus == .repositoryRelative && $0.path != nil }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(report.selection?.displayName ?? report.screen?.owningController ?? "Screen report")
                .font(.title2.weight(.semibold))
            Text("\(report.app.name) \(report.app.version) (\(report.app.build)) · \(report.device.model) · \(report.device.systemName) \(report.device.systemVersion)\(report.device.isSimulator ? " Simulator" : "") · received \(stored.receipt.receivedAt.formatted(date: .abbreviated, time: .standard))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var screenshot: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Image", selection: $showOriginal) {
                Text("Annotated").tag(false)
                Text(report.redactionApplied ? "No markup (redacted)" : "No markup").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if let url = stored.imageURL(showOriginal ? .original : .annotated), let img = NSImage(contentsOf: url) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary))
                    .accessibilityLabel(showOriginal ? "Screenshot without markup" : "Annotated screenshot")
            }
            Text("\(report.annotations.count) annotation\(report.annotations.count == 1 ? "" : "s") · \(report.screenshot.pixelWidth)×\(report.screenshot.pixelHeight) px @\(Int(report.screenshot.scale))x\(report.redactionApplied ? " · redaction applied on device" : "")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var descriptionSection: some View {
        DetailSection("Description") {
            Text(report.description.isEmpty ? "No description." : report.description)
                .textSelection(.enabled)
                .foregroundStyle(report.description.isEmpty ? .secondary : .primary)
        }
    }

    private var sourceSection: some View {
        DetailSection("Source") {
            if let el = report.selection {
                LabeledContent("Selected element") {
                    Text("\(el.displayName) — \(el.className)\(el.accessibilityIdentifier.map { " #\($0)" } ?? "")").textSelection(.enabled)
                }
            }
            if let properties = report.selection?.properties {
                ForEach(properties.keys.sorted(), id: \.self) { key in
                    LabeledContent(key) { Text(properties[key] ?? "").textSelection(.enabled) }
                }
            }
            if let s = report.screen {
                LabeledContent("Screen owner") { Text(s.owningController).textSelection(.enabled) }
            }
            if report.sourceAnchors.isEmpty {
                Text("No registered source anchors.").foregroundStyle(.secondary)
            }
            ForEach(report.sourceAnchors, id: \.self) { a in
                MacAnchorRow(anchor: a, canReveal: model.project(for: stored) != nil) { model.reveal(a, in: stored) }
            }
            if !stored.receipt.inferredCandidates.isEmpty {
                Text("Unverified candidates").font(.subheadline.weight(.semibold)).padding(.top, 6)
                ForEach(stored.receipt.inferredCandidates, id: \.self) { a in
                    MacAnchorRow(anchor: a, canReveal: model.project(for: stored) != nil) { model.reveal(a, in: stored) }
                }
            }
            Text("Registration anchors mark where UI was registered in code, not necessarily the line responsible for the bug.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var consistencySection: some View {
        DetailSection("Build / source consistency") {
            let c = consistency ?? stored.receipt.consistencyAtReceipt
            if let c {
                HStack(spacing: 8) {
                    ConsistencyBadge(overall: c.overall)
                    Text(c.summary).font(.callout)
                }
                LabeledContent("Built from") {
                    Text("\(c.buildCommit.map { String($0.prefix(10)) } ?? "unknown")\(c.buildDirty == true ? " + uncommitted changes" : "")").font(.callout.monospaced())
                }
                LabeledContent("Repository now") {
                    Text("\(c.currentCommit.map { String($0.prefix(10)) } ?? "unknown")\(c.currentDirty == true ? " + uncommitted changes" : "")").font(.callout.monospaced())
                }
                ForEach(c.files, id: \.path) { f in
                    HStack {
                        Text(f.path).font(.caption.monospaced())
                        Spacer()
                        Text(f.status.label).font(.caption).foregroundStyle(f.status == .unchanged ? .green : f.status == .unknown ? .secondary : .orange)
                    }
                }
                Text(consistency == nil ? "As evaluated when the report arrived." : "Evaluated just now against the working tree.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.project(for: stored) == nil {
                Text("The project for this report is not registered on this Mac.").foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var contextSection: some View {
        DetailSection("Attached context") {
            if let s = report.screen {
                LabeledContent("Controllers") { Text(s.controllerChain.joined(separator: " › ")).textSelection(.enabled) }
                if let stack = s.navigationStack { LabeledContent("Navigation stack") { Text(stack.joined(separator: " › ")) } }
                if let t = s.tabSelectedIndex, let n = s.tabCount { LabeledContent("Tab") { Text("\(t + 1) of \(n)") } }
                if let p = s.presentation { LabeledContent("Presentation") { Text(p) } }
                ForEach(s.containment, id: \.self) { Text($0).font(.callout) }
            }
            if let el = report.selection, !el.hierarchy.isEmpty {
                DisclosureGroup("View hierarchy (\(el.hierarchy.count))") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(el.hierarchy.enumerated()), id: \.offset) { i, node in
                            Text(String(repeating: "  ", count: i) + node.className + (node.registeredSymbol.map { "  ← \($0)" } ?? "") + (node.accessibilityIdentifier.map { "  #\($0)" } ?? ""))
                                .font(.caption.monospaced())
                        }
                    }
                    .textSelection(.enabled)
                }
                ForEach(el.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            }
            LabeledContent("Build") {
                Text("\(report.build.configuration ?? "unknown") · \(report.build.gitBranch ?? "no branch") · build \(report.build.buildID ?? "unconfigured")").font(.callout.monospaced())
            }
            if let logs = report.logs {
                DisclosureGroup("App logs (\(logs.count), sanitized on device)") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(logs.enumerated()), id: \.offset) { _, e in
                            Text("\(e.timestamp.formatted(date: .omitted, time: .standard)) [\(e.level)] \(e.category): \(e.message)").font(.caption.monospaced())
                        }
                    }
                    .textSelection(.enabled)
                }
            }
        }
    }
}

struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MacAnchorRow: View {
    let anchor: SourceAnchor
    let canReveal: Bool
    let reveal: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(anchor.symbol).fontWeight(.semibold)
                    Text(anchor.role).font(.caption).foregroundStyle(.secondary)
                    EvidenceTag(evidence: anchor.evidence)
                }
                Text(anchor.path.map { "\($0)\(anchor.line.map { ":\($0)" } ?? "")" } ?? "No registered file")
                    .font(.callout.monospaced())
                    .foregroundStyle(anchor.path == nil ? .secondary : .primary)
                    .textSelection(.enabled)
                if let note = anchor.note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if anchor.pathStatus == .repositoryRelative {
                Button("Reveal", action: reveal)
                    .controlSize(.small)
                    .disabled(!canReveal)
            }
        }
    }
}

struct EvidenceTag: View {
    let evidence: SourceEvidence

    var body: some View {
        let (label, color): (String, Color) = switch evidence {
        case .registered: ("Registered", .blue)
        case .generatedMapping: ("Generated", .teal)
        case .inferredCandidate: ("Inferred", .orange)
        }
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

struct ConsistencyBadge: View {
    let overall: SourceConsistency.Overall

    var body: some View {
        let (label, color, symbol): (String, Color, String) = switch overall {
        case .exactMatch: ("Matches build", .green, "checkmark.seal.fill")
        case .sameCommitWorkingTreeChanged: ("Working tree changed", .orange, "pencil.circle.fill")
        case .differentCommit: ("Different commit", .orange, "arrow.triangle.branch")
        case .unknown: ("Unknown", .secondary, "questionmark.circle")
        }
        Label(label, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

extension FileConsistency.Status {
    var label: String {
        switch self {
        case .unchanged: return "unchanged since build"
        case .changedSinceBuild: return "changed since build"
        case .missing: return "missing"
        case .unknown: return "unknown"
        }
    }
}

struct PrepareForClaudeSheet: View {
    @ObservedObject var model: AppModel
    let reportID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AI tools").font(.title2.weight(.semibold))
            Text("Copy a report reference for any AI coding tool with local file access, or open a supported Claude destination. Browser chats require exported files.")
                .foregroundStyle(.secondary)
            GroupBox {
                Text(AppModel.claudeRequest(for: reportID))
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
            }
            VStack(alignment: .leading, spacing: 6) {
                StatusLine(ok: model.mcpInstalled, text: model.mcpInstalled ? "MCP server installed at \(ShimInstaller.mcpCommandPath(home: model.home))" : "MCP command not installed (restart ScreenBridge).")
                StatusLine(ok: model.claudeDesktopConfigured, text: model.claudeDesktopConfigured ? "Claude Desktop is configured for ScreenBridge." : "Claude Desktop is not configured yet. Copy the configuration, add it to claude_desktop_config.json and restart Claude Desktop.")
            }
            if let stored = try? ReportStore(home: model.home).load(reportID) {
                HStack {
                    ForEach([ClaudeDestination.reference, .code, .desktop, .browser]) { destination in
                        Button(destination.title) { model.openClaude(for: stored, destination: destination) }
                    }
                }
                if stored.imageURL(.annotated) != nil {
                    Button("Copy screenshot") { model.copyScreenshot(for: stored) }
                    Text("Paste into the Claude draft with ⌘V to attach the image. Desktop links prefill text; they cannot attach screenshots.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message = model.handoffMessages[reportID] {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("Claude Code: write your request beside the short report reference. Browser: paste the report and attach the exported PNG files.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if !model.claudeDesktopConfigured {
                    Button("Configure Claude Desktop") { model.configureClaudeDesktop() }
                }
                Spacer()
                Button("Close") { dismiss() }
                Button("Copy reference") {
                    model.copyRequest(for: reportID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

struct StatusLine: View {
    let ok: Bool
    let text: String

    var body: some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
            .foregroundStyle(ok ? .green : .orange)
            .font(.callout)
    }
}
