#if SCREENBRIDGE_ENABLED && canImport(UIKit)
import UIKit
import SwiftUI
import ScreenBridgeProtocol

// MARK: - Shared pieces

struct ConnectionStatusRow: View {
    @ObservedObject var connection: ConnectionManager

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.status.shortText)
                    .font(.subheadline.weight(.medium))
                if let detail = connection.status.detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if connection.queuedCount > 0 {
                    Text("\(connection.queuedCount) report\(connection.queuedCount == 1 ? "" : "s") waiting to send")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection: \(connection.status.shortText)")
    }

    private var color: Color {
        switch connection.status {
        case .connected: return .green
        case .searching, .connecting: return .orange
        case .notConfigured: return .gray
        default: return .red
        }
    }
}

struct EvidenceBadge: View {
    let evidence: SourceEvidence

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
            .accessibilityLabel("Evidence: \(label)")
    }

    private var label: String {
        switch evidence {
        case .registered: return "Registered"
        case .generatedMapping: return "Generated mapping"
        case .inferredCandidate: return "Inferred candidate"
        }
    }

    private var tint: Color {
        switch evidence {
        case .registered: return .blue
        case .generatedMapping: return .teal
        case .inferredCandidate: return .orange
        }
    }
}

struct AnchorRow: View {
    let anchor: SourceAnchor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(anchor.symbol).font(.body.weight(.semibold))
                Spacer(minLength: 4)
                EvidenceBadge(evidence: anchor.evidence)
            }
            Text(location)
                .font(.footnote.monospaced())
                .foregroundStyle(anchor.path == nil ? .secondary : .primary)
                .textSelection(.enabled)
            Text(anchor.role.capitalized)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let note = anchor.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var location: String {
        switch anchor.pathStatus {
        case .repositoryRelative:
            return "\(anchor.path ?? "?")" + (anchor.line.map { ":\($0)" } ?? "")
        case .outsideProject:
            return "\(anchor.path ?? "?") (outside project root)"
        case .unknown:
            return "File not registered"
        }
    }
}

struct CloseToolbar: ToolbarContent {
    let action: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Close", action: action)
        }
    }
}

// MARK: - Home

struct InspectorHomeView: View {
    @ObservedObject var model: InspectorModel

    var body: some View {
        NavigationStack(path: $model.path) {
            List {
                Section {
                    ConnectionStatusRow(connection: model.connection)
                }
                Section {
                    Button {
                        model.onInspectElement()
                    } label: {
                        MenuRow(symbol: "scope", title: "Inspect an element", subtitle: "Tap any view to find its source")
                    }
                    NavigationLink(value: InspectorRoute.screenSource) {
                        MenuRow(symbol: "doc.text.magnifyingglass", title: "Screen source", subtitle: model.screen?.title ?? "Visible screen")
                    }
                    .disabled(model.screen == nil)
                    Button {
                        model.beginReport(annotateSelection: false)
                    } label: {
                        MenuRow(symbol: "square.and.pencil", title: "Report a change", subtitle: "Annotate this screen and send it to your Mac")
                    }
                    .disabled(model.capture == nil)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("ScreenBridge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { CloseToolbar(action: model.onClose) }
            .navigationDestination(for: InspectorRoute.self) { route in
                InspectorDestination(route: route, model: model)
            }
        }
        .tint(.blue)
    }
}

struct MenuRow: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.blue)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Color.primary)
                Text(subtitle).font(.footnote).foregroundStyle(Color.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct InspectorDestination: View {
    let route: InspectorRoute
    @ObservedObject var model: InspectorModel

    var body: some View {
        switch route {
        case .screenSource:
            if let screen = model.screen {
                SourceDetailList(model: model, resolved: screen, isScreen: true)
                    .navigationTitle("Screen source")
            }
        case .report:
            ReportEditorView(model: model)
        case .preview:
            SendPreviewView(model: model)
        case .status:
            SendStatusView(model: model)
        }
    }
}

// MARK: - Source

struct SourceSheetView: View {
    @ObservedObject var model: InspectorModel

    var body: some View {
        NavigationStack(path: $model.path) {
            Group {
                if let selection = model.selection {
                    SourceDetailList(model: model, resolved: selection, isScreen: false)
                } else {
                    Text("Nothing selected").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Element source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { CloseToolbar(action: model.onClose) }
            .navigationDestination(for: InspectorRoute.self) { route in
                InspectorDestination(route: route, model: model)
            }
        }
        .tint(.blue)
    }
}

struct SourceDetailList: View {
    @ObservedObject var model: InspectorModel
    let resolved: ResolvedSelection
    let isScreen: Bool

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(resolved.title).font(.title3.weight(.semibold))
                    Text(resolved.subtitle).font(.subheadline).foregroundStyle(.secondary)
                    if let id = resolved.element?.accessibilityIdentifier {
                        Label(id, systemImage: "number").font(.footnote.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                if !isScreen {
                    Button("Select parent element", systemImage: "arrow.up.left.square") { model.onSelectParent() }
                        .disabled(!model.canSelectParent())
                    Button("Pick another element", systemImage: "scope") { model.onInspectElement() }
                }
            }

            if !isScreen {
                Section {
                    if resolved.elementAnchors.isEmpty {
                        Text("No source is registered for this element or its containers. Register it with `screenBridgeSource()` to link it.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(resolved.elementAnchors, id: \.self) { AnchorRow(anchor: $0) }
                } header: {
                    Text("Source")
                } footer: {
                    Text("A registration anchor marks where this was registered in code. It is not necessarily the line that causes the issue.")
                }
            }

            Section("Owning screen") {
                if let owner = resolved.screen?.owningController {
                    LabeledContent("Controller", value: owner)
                }
                if resolved.screenAnchors.isEmpty {
                    Text("This screen has no registered source.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(resolved.screenAnchors, id: \.self) { AnchorRow(anchor: $0) }
            }

            if !resolved.relatedAnchors.isEmpty {
                Section("Related") {
                    ForEach(resolved.relatedAnchors, id: \.self) { AnchorRow(anchor: $0) }
                }
            }

            if let screen = resolved.screen {
                Section("Navigation") {
                    Text(screen.controllerChain.joined(separator: " › "))
                        .font(.footnote.monospaced())
                    if let stack = screen.navigationStack {
                        LabeledContent("Navigation stack", value: "\((screen.navigationIndex ?? 0) + 1) of \(stack.count)")
                    }
                    if let tab = screen.tabSelectedIndex, let count = screen.tabCount {
                        LabeledContent("Tab", value: "\(tab + 1) of \(count)")
                    }
                    if let p = screen.presentation { Text(p).font(.footnote) }
                    ForEach(screen.containment, id: \.self) { Text($0).font(.footnote) }
                }
            }

            if let notes = resolved.element?.notes, !notes.isEmpty {
                Section("Notes") {
                    ForEach(notes, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
                }
            }

            Section {
                Button {
                    model.beginReport(annotateSelection: !isScreen)
                } label: {
                    Label(isScreen ? "Annotate this screen" : "Annotate this element", systemImage: "pencil.tip.crop.circle")
                }
                .disabled(model.capture == nil)

                Button {
                    if let a = resolved.primaryRevealAnchor { model.reveal(a) }
                } label: {
                    HStack {
                        Label("Reveal source on Mac", systemImage: "macbook.and.iphone")
                        if model.revealInFlight { Spacer(); ProgressView() }
                    }
                }
                .disabled(resolved.primaryRevealAnchor == nil || !model.connection.status.isConnected || model.revealInFlight)
            } footer: {
                if let msg = model.revealMessage {
                    Text(msg)
                } else if resolved.primaryRevealAnchor == nil {
                    Text("Reveal needs a registered file inside the project.")
                } else if !model.connection.status.isConnected {
                    Text("Reveal needs a connection to \(model.connection.macName). It opens the file in Xcode.")
                } else if let a = resolved.primaryRevealAnchor {
                    Text("Opens \(a.path ?? "")\(a.line.map { ":\($0)" } ?? "") in Xcode on \(model.connection.macName).")
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - Report editor

struct ReportEditorView: View {
    @ObservedObject var model: InspectorModel
    @FocusState private var descriptionFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let capture = model.capture {
                    AnnotationCanvas(image: capture.image, pixelSize: CGSize(width: capture.cgImage.width, height: capture.cgImage.height), scale: capture.scale, annotations: $model.annotations, tool: model.tool)
                        .frame(height: 380)
                        .frame(maxWidth: .infinity)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                HStack(spacing: 8) {
                    Picker("Tool", selection: $model.tool) {
                        Image(systemName: "scribble").accessibilityLabel("Pen").tag(AnnotationTool.pen)
                        Image(systemName: "circle").accessibilityLabel("Ellipse").tag(AnnotationTool.ellipse)
                        Image(systemName: "arrow.up.right").accessibilityLabel("Arrow").tag(AnnotationTool.arrow)
                        Image(systemName: "rectangle.fill").accessibilityLabel("Redact").tag(AnnotationTool.redaction)
                    }
                    .pickerStyle(.segmented)
                    Button {
                        model.undo()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .frame(minWidth: 44, minHeight: 32)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.annotations.isEmpty)
                    .accessibilityLabel("Undo")
                }
                if model.tool == .redaction {
                    Label("Redaction permanently removes those pixels from everything that is sent.", systemImage: "eye.slash")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("What should change?").font(.headline)
                    TextField("Describe the bug or the change you want", text: $model.reportDescription, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($descriptionFocused)
                        .padding(10)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if let ctx = model.reportContext {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Attached source context").font(.headline)
                        if ctx.allAnchors.isEmpty {
                            Text("No registered source. Screen: \(ctx.screen?.owningController ?? "unknown").").font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(ctx.allAnchors.prefix(4), id: \.self) { a in
                            Text("\(a.symbol) — \(a.path ?? "file not registered")\(a.line.map { ":\($0)" } ?? "")")
                                .font(.footnote.monospaced())
                                .lineLimit(2)
                        }
                    }
                }

                Toggle(isOn: $model.includeLogs) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Attach recent app logs")
                        Text("\(model.availableLogCount) entries from ScreenBridge.log, sanitized").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .disabled(model.availableLogCount == 0)

                NavigationLink(value: InspectorRoute.preview) {
                    Label("Preview what will be sent", systemImage: "doc.viewfinder")
                }

                if let err = model.exportError {
                    Text(err).font(.footnote).foregroundStyle(.red)
                }

                Button {
                    descriptionFocused = false
                    model.send()
                } label: {
                    Text("Send to Mac").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.capture == nil)
            }
            .padding()
        }
        .navigationTitle("Report a change")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { descriptionFocused = false }
            }
        }
    }
}

/// Draws the screenshot aspect-fit and records gestures as image-pixel annotations.
struct AnnotationCanvas: View {
    let image: UIImage
    let pixelSize: CGSize
    let scale: CGFloat
    @Binding var annotations: [Annotation]
    let tool: AnnotationTool
    @State private var draft: Annotation?

    var body: some View {
        GeometryReader { geo in
            let mapping = AspectFitMapping(imagePixelSize: pixelSize, viewSize: geo.size)
            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: mapping.displayRect.width, height: mapping.displayRect.height)
                    .offset(x: mapping.displayRect.minX, y: mapping.displayRect.minY)
                    .accessibilityHidden(true)
                Canvas { ctx, _ in
                    for a in annotations + (draft.map { [$0] } ?? []) {
                        Self.draw(a, in: &ctx, mapping: mapping)
                    }
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let p = SBPoint(mapping.imagePoint(fromView: value.location))
                        if draft == nil {
                            let start = SBPoint(mapping.imagePoint(fromView: value.startLocation))
                            draft = Annotation(tool: tool, points: [start], strokeWidth: Double(scale) * (tool == .pen ? 3 : 3))
                        }
                        if tool == .pen {
                            draft?.points.append(p)
                        } else if draft!.points.count == 1 {
                            draft?.points.append(p)
                        } else {
                            draft?.points[1] = p
                        }
                    }
                    .onEnded { _ in
                        if let d = draft, d.isRenderable { annotations.append(d) }
                        draft = nil
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Screenshot")
            .accessibilityValue("\(annotations.count) annotation\(annotations.count == 1 ? "" : "s")")
            .accessibilityHint("Drag to draw with the selected tool.")
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    static func draw(_ a: Annotation, in ctx: inout GraphicsContext, mapping: AspectFitMapping) {
        let k = mapping.pointsPerPixel
        let pts = a.points.map { mapping.viewPoint(fromImage: $0.cgPoint) }
        let color = Color(red: a.color.red, green: a.color.green, blue: a.color.blue)
        let style = StrokeStyle(lineWidth: max(1.5, CGFloat(a.strokeWidth) * k), lineCap: .round, lineJoin: .round)
        switch a.tool {
        case .pen:
            var path = Path()
            path.addLines(pts)
            ctx.stroke(path, with: .color(color), style: style)
        case .ellipse:
            guard pts.count >= 2 else { return }
            ctx.stroke(Path(ellipseIn: CGRect(corner: pts[0], corner: pts[pts.count - 1])), with: .color(color), style: style)
        case .arrow:
            guard let tail = pts.first, let head = pts.last, pts.count >= 2 else { return }
            var path = Path()
            path.move(to: tail)
            path.addLine(to: head)
            let angle = atan2(head.y - tail.y, head.x - tail.x)
            let len = max(18 * k, style.lineWidth * 4)
            for d in [CGFloat.pi * 0.83, -CGFloat.pi * 0.83] {
                path.move(to: head)
                path.addLine(to: CGPoint(x: head.x + cos(angle + d) * len, y: head.y + sin(angle + d) * len))
            }
            ctx.stroke(path, with: .color(color), style: style)
        case .redaction:
            guard pts.count >= 2 else { return }
            ctx.fill(Path(CGRect(corner: pts[0], corner: pts[pts.count - 1])), with: .color(.black))
        }
    }
}

extension CGRect {
    init(corner a: CGPoint, corner b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

// MARK: - Preview

struct SendPreviewView: View {
    @ObservedObject var model: InspectorModel
    @State private var payload: (report: DebugReport, exported: ExportedScreenshot)?
    @State private var error: String?

    var body: some View {
        List {
            if let error {
                Text(error).foregroundStyle(.red)
            }
            if let payload {
                Section {
                    PreviewImage(data: payload.exported.annotatedPNG, label: "Annotated screenshot")
                    PreviewImage(data: payload.exported.originalPNG, label: payload.exported.redactionApplied ? "Screenshot without markup (redactions applied)" : "Screenshot without markup")
                } header: {
                    Text("Images")
                } footer: {
                    Text(payload.exported.redactionApplied
                         ? "Redacted pixels are removed from both images. No unredacted copy or thumbnail is sent."
                         : "Images are re-encoded as PNG without capture metadata.")
                }
                Section("Description") {
                    Text(payload.report.description.isEmpty ? "No description" : payload.report.description)
                        .foregroundStyle(payload.report.description.isEmpty ? .secondary : .primary)
                }
                Section("Source context") {
                    if let el = payload.report.selection {
                        LabeledContent("Element", value: el.displayName)
                    }
                    if let s = payload.report.screen {
                        LabeledContent("Screen", value: s.owningController)
                    }
                    ForEach(payload.report.sourceAnchors, id: \.self) { AnchorRow(anchor: $0) }
                }
                Section("App, device and build") {
                    LabeledContent("App", value: "\(payload.report.app.name) \(payload.report.app.version) (\(payload.report.app.build))")
                    LabeledContent("Device", value: "\(payload.report.device.model), \(payload.report.device.systemName) \(payload.report.device.systemVersion)")
                    LabeledContent("Commit", value: payload.report.build.gitCommit.map { String($0.prefix(10)) } ?? "unknown")
                    LabeledContent("Working tree", value: payload.report.build.isDirty.map { $0 ? "had uncommitted changes" : "clean" } ?? "unknown")
                    LabeledContent("Annotations", value: "\(payload.report.annotations.count)")
                }
                Section {
                    if let logs = payload.report.logs {
                        ForEach(Array(logs.enumerated()), id: \.offset) { _, entry in
                            Text("[\(entry.level)] \(entry.category): \(entry.message)").font(.caption.monospaced())
                        }
                        if logs.isEmpty { Text("No log entries.").foregroundStyle(.secondary) }
                    } else {
                        Text("Logs are not included.").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Logs")
                } footer: {
                    Text("Nothing else leaves this device. Paths are relative to your project; no tokens, network bodies or system logs are collected.")
                }
            } else if error == nil {
                ProgressView()
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("What will be sent")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { payload = try model.buildPayload() } catch { self.error = "\(error)" }
        }
    }
}

struct PreviewImage: View {
    let data: Data
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let ui = UIImage(data: data) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 260)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel(label)
            }
            Text("\(label) · \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Status

struct SendStatusView: View {
    @ObservedObject var model: InspectorModel

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 20)
            switch model.sendState {
            case .sending, .none:
                ProgressView().controlSize(.large)
                Text("Sending to \(model.connection.macName)…").font(.headline)
            case .acknowledged(let id, let duplicate):
                StatusIcon(symbol: "checkmark.circle.fill", color: .green)
                Text("On your Mac. Report \(id) is ready.")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(duplicate ? "Your Mac already had this report." : "Open the ScreenBridge inbox on your Mac, then use “Prepare for Claude” to ask Claude about it.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            case .queued(_, let reason):
                StatusIcon(symbol: "tray.and.arrow.up.fill", color: .orange)
                Text("Saved on this device").font(.title3.weight(.semibold))
                Text(reason).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try again now") { model.retrySend() }.buttonStyle(.bordered)
            case .failed(_, let error):
                StatusIcon(symbol: "exclamationmark.triangle.fill", color: .red)
                Text("Couldn't send the report").font(.title3.weight(.semibold))
                Text(error).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try again") { model.retrySend() }.buttonStyle(.bordered)
            }
            Spacer()
            Button {
                model.onClose()
            } label: {
                Text("Back to app").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(24)
        .navigationBarBackButtonHidden(model.sendState == .sending)
        .navigationTitle("Report")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct StatusIcon: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 52))
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
}
#endif
