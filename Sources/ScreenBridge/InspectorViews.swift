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
                    Button("Delete all", systemImage: "trash", role: .destructive) {
                        model.deleteAll()
                        model.onClose()
                    }
                    .disabled(model.annotations.isEmpty && model.selection == nil && model.selectedRegion == nil)
                }
                Section("Color") {
                    AnnotationColorPicker(color: $model.annotationColor)
                }
                Section("Drawing") {
                    Button("Select area", systemImage: "rectangle.dashed") {
                        model.workspaceMode = .area
                        model.onClose()
                    }
                    Button("Redact", systemImage: "rectangle.fill") {
                        model.tool = .redaction
                        model.workspaceMode = .draw
                        model.onClose()
                    }
                }
                if let selected = model.selection {
                    Section("Selected object") {
                        NavigationLink(value: InspectorRoute.selectedSource) {
                            MenuRow(symbol: "scope", title: selected.title, subtitle: selected.subtitle)
                        }
                        .accessibilityIdentifier("screenbridge.selection")
                    }
                }
                Section {
                    NavigationLink(value: InspectorRoute.logs) {
                        MenuRow(symbol: "text.alignleft", title: "App logs", subtitle: "Live debug messages and connection activity")
                    }
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
        Group {
            switch route {
            case .logs:
                AppLogsView()
            case .selectedSource:
                if let selection = model.selection {
                    SourceDetailList(model: model, resolved: selection, isScreen: false).navigationTitle("Selected object")
                }
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
        .toolbar { CloseToolbar(action: model.onClose) }
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

            if let properties = resolved.element?.properties, !properties.isEmpty {
                Section("Properties") {
                    ForEach(properties.keys.sorted(), id: \.self) { key in
                        LabeledContent(key, value: properties[key] ?? "").font(.footnote.monospaced())
                    }
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
                    AnnotationCanvas(image: capture.image, pixelSize: CGSize(width: capture.cgImage.width, height: capture.cgImage.height), scale: capture.scale, annotations: $model.annotations, tool: model.tool, color: model.annotationColor)
                        .frame(height: 380)
                        .frame(maxWidth: .infinity)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                HStack(spacing: 8) {
                    Picker("Tool", selection: $model.tool) {
                        Image(systemName: "scribble").accessibilityLabel("Pen").tag(AnnotationTool.pen)
                        Image(systemName: "rectangle").accessibilityLabel("Rectangle").tag(AnnotationTool.rectangle)
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
                    .disabled(!model.canUndo)
                    .accessibilityLabel("Undo")
                    Button { model.redo() } label: {
                        Image(systemName: "arrow.uturn.forward").frame(minWidth: 44, minHeight: 32)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.canRedo)
                    .accessibilityLabel("Redo")
                }
                AnnotationColorPicker(color: $model.annotationColor)
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

                if model.includeSource, let ctx = model.reportContext {
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

                VStack(alignment: .leading, spacing: 10) {
                    Text("Include in report").font(.headline)
                    Toggle("App logs (\(model.availableLogCount) entries)", isOn: $model.includeLogs)
                    Toggle("Selected view and screen details", isOn: $model.includeViewDetails)
                    Toggle("Current view file and related files", isOn: $model.includeSource)
                    Toggle("Screenshots and annotations", isOn: $model.includeScreenshots)
                    Picker("Open on Mac", selection: $model.destination) {
                        ForEach(ClaudeDestination.allCases) { Text($0.title).tag($0) }
                    }
                    Text(model.destination == .browser
                         ? "Your Mac opens Claude in a browser and an export folder. Paste the copied report and attach its PNG files."
                         : model.destination == .inbox
                         ? "Save to the ScreenBridge inbox on your Mac."
                         : "Your Mac opens \(model.destination.title) with a prepared prompt. Review it and press Send in Claude. Configure the ScreenBridge connector on your Mac to read the report and screenshots.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

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
                    Text(model.destination == .inbox ? "Send to Mac" : "Send to Claude").frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("screenbridge.submit")
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
    var color: SBColor = .markup
    var mode: InspectorModel.WorkspaceMode = .draw
    var selectedRegion: SBRect?
    var selectedFrame: SBRect?
    var onSelect: (SBPoint) -> Void = { _ in }
    var onRegion: (SBRect) -> Void = { _ in }
    @State private var draft: Annotation?
    @State private var selectedAnnotationID: UUID?
    @State private var movingAnnotation: Annotation?
    @State private var moveOffset = CGSize.zero
    @State private var resizingAnnotation: Annotation?
    @State private var resizeFactor = 1.0
    @State private var suppressDrag = false

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
                        let displayed = resizingAnnotation?.id == a.id ? a.resized(by: resizeFactor)
                            : (movingAnnotation?.id == a.id
                               ? a.translated(dx: Double(moveOffset.width), dy: Double(moveOffset.height)) : a)
                        Self.draw(displayed, in: &ctx, mapping: mapping)
                        if mode == .editAnnotations, a.id == selectedAnnotationID {
                            let b = displayed.bounds
                            let start = mapping.viewPoint(fromImage: CGPoint(x: b.x, y: b.y))
                            let end = mapping.viewPoint(fromImage: CGPoint(x: b.x + b.width, y: b.y + b.height))
                            ctx.stroke(Path(CGRect(corner: start, corner: end).insetBy(dx: -6, dy: -6)),
                                       with: .color(.blue), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        }
                    }
                    for rect in [selectedRegion, selectedFrame].compactMap({ $0 }) {
                        let first = mapping.viewPoint(fromImage: CGPoint(x: rect.x, y: rect.y))
                        let last = mapping.viewPoint(fromImage: CGPoint(x: rect.x + rect.width, y: rect.y + rect.height))
                        let path = Path(CGRect(corner: first, corner: last))
                        ctx.fill(path, with: .color(.cyan.opacity(0.12)))
                        ctx.stroke(path, with: .color(.cyan), style: StrokeStyle(lineWidth: 2, dash: [6, 3]))
                    }
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard mapping.displayRect.contains(value.startLocation) else { return }
                        guard !suppressDrag, resizingAnnotation == nil else { return }
                        if mode == .inspect { return }
                        if mode == .editAnnotations {
                            if movingAnnotation == nil {
                                let start = SBPoint(mapping.imagePoint(fromView: value.startLocation))
                                movingAnnotation = annotations.reversed().first { $0.contains(start, tolerance: Double(12 / mapping.pointsPerPixel)) }
                                if let movingAnnotation { selectedAnnotationID = movingAnnotation.id }
                            }
                            moveOffset = CGSize(width: value.translation.width / mapping.pointsPerPixel,
                                                height: value.translation.height / mapping.pointsPerPixel)
                            return
                        }
                        let p = SBPoint(mapping.imagePoint(fromView: value.location))
                        if draft == nil {
                            let start = SBPoint(mapping.imagePoint(fromView: value.startLocation))
                            draft = Annotation(tool: mode == .area ? .rectangle : tool, points: [start], strokeWidth: Double(scale) * 3, color: mode == .area ? SBColor(red: 0, green: 0.8, blue: 1) : (tool == .redaction ? .redaction : color))
                        }
                        if mode == .draw && tool == .pen {
                            draft?.points.append(p)
                        } else if draft!.points.count == 1 {
                            draft?.points.append(p)
                        } else {
                            draft?.points[1] = p
                        }
                    }
                    .onEnded { value in
                        if suppressDrag {
                            suppressDrag = false
                            movingAnnotation = nil
                            draft = nil
                            moveOffset = .zero
                            return
                        }
                        if mode == .inspect, mapping.displayRect.contains(value.location) {
                            selectedAnnotationID = nil
                            onSelect(SBPoint(mapping.imagePoint(fromView: value.location)))
                        } else if mode == .editAnnotations {
                            if let moving = movingAnnotation,
                               let index = annotations.firstIndex(where: { $0.id == moving.id }) {
                                if hypot(value.translation.width, value.translation.height) > 3 {
                                    annotations[index] = moving.translated(dx: Double(moveOffset.width), dy: Double(moveOffset.height))
                                }
                            } else if mapping.displayRect.contains(value.location) {
                                selectedAnnotationID = nil
                            }
                        } else if let d = draft, d.isRenderable {
                            if mode == .area { onRegion(d.bounds) } else { annotations.append(d) }
                        }
                        draft = nil
                        movingAnnotation = nil
                        moveOffset = .zero
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { factor in
                        guard mode == .editAnnotations else { return }
                        if resizingAnnotation == nil {
                            resizingAnnotation = annotations.first { $0.id == selectedAnnotationID }
                        }
                        guard resizingAnnotation != nil else { return }
                        suppressDrag = true
                        movingAnnotation = nil
                        draft = nil
                        resizeFactor = min(10, max(0.1, Double(factor)))
                    }
                    .onEnded { factor in
                        if let original = resizingAnnotation,
                           let index = annotations.firstIndex(where: { $0.id == original.id }) {
                            annotations[index] = original.resized(by: min(10, max(0.1, Double(factor))))
                        }
                        resizingAnnotation = nil
                        resizeFactor = 1
                        moveOffset = .zero
                    }
            )
            .overlay(alignment: .topLeading) {
                if mode == .editAnnotations, movingAnnotation == nil, resizingAnnotation == nil,
                   let selected = annotations.first(where: { $0.id == selectedAnnotationID }) {
                    let b = selected.bounds
                    let anchor = mapping.viewPoint(fromImage: CGPoint(x: b.x + b.width / 2, y: b.y))
                    HStack(spacing: 0) {
                        Button {
                            annotations.removeAll { $0.id == selected.id }
                            selectedAnnotationID = nil
                        } label: {
                            Image(systemName: "trash").foregroundStyle(.red).frame(width: 40, height: 40)
                        }
                        .accessibilityLabel("Delete annotation")
                    }
                    .font(.system(size: 15, weight: .medium))
                    .buttonStyle(.plain)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.12)))
                    .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
                    .position(x: max(24, min(geo.size.width - 24, anchor.x)),
                              y: anchor.y >= 52 ? anchor.y - 28 : min(geo.size.height - 24, anchor.y + CGFloat(b.height) * mapping.pointsPerPixel + 28))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Screenshot")
            .accessibilityValue(annotationAccessibilityValue)
            .accessibilityHint(mode == .inspect ? "Tap to inspect a view." : mode == .editAnnotations ? "Tap an annotation to select it. Drag to move; pinch to resize." : "Drag to draw with the selected tool.")
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var annotationAccessibilityValue: String {
        let count = "\(annotations.count) annotation\(annotations.count == 1 ? "" : "s")"
        guard let selected = annotations.first(where: { $0.id == selectedAnnotationID }) else { return count }
        return count + ". Selected \(selected.tool.rawValue), width \(Int(selected.bounds.width)), height \(Int(selected.bounds.height))"
    }

    static func draw(_ a: Annotation, in ctx: inout GraphicsContext, mapping: AspectFitMapping) {
        let k = mapping.pointsPerPixel
        let pts = a.points.map { mapping.viewPoint(fromImage: $0.cgPoint) }
        let color = Color(red: a.color.red, green: a.color.green, blue: a.color.blue)
        let style = StrokeStyle(lineWidth: max(1.5, CGFloat(a.strokeWidth) * k), lineCap: .round, lineJoin: .round)
        switch a.tool {
        case .pen:
            if let point = pts.first, pts.count == 1 {
                let diameter = style.lineWidth
                let rect = CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2, width: diameter, height: diameter)
                ctx.fill(Path(ellipseIn: rect), with: .color(color))
                return
            }
            var path = Path()
            path.addLines(pts)
            ctx.stroke(path, with: .color(color), style: style)
        case .rectangle:
            guard pts.count >= 2 else { return }
            ctx.stroke(Path(CGRect(corner: pts[0], corner: pts[pts.count - 1])), with: .color(color), style: style)
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
                if !payload.report.images.isEmpty {
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
                }
                Section("Description") {
                    Text(payload.report.description.isEmpty ? "No description" : payload.report.description)
                        .foregroundStyle(payload.report.description.isEmpty ? .secondary : .primary)
                }
                Section("Source context") {
                    if let el = payload.report.selection {
                        LabeledContent("Element", value: el.displayName)
                    }
                    if let properties = payload.report.selection?.properties {
                        ForEach(properties.keys.sorted(), id: \.self) { key in
                            LabeledContent(key, value: properties[key] ?? "").font(.footnote.monospaced())
                        }
                    }
                    if let region = payload.report.selectedRegion {
                        LabeledContent("Selected area", value: "\(Int(region.width)) × \(Int(region.height)) px at \(Int(region.x)), \(Int(region.y))")
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
                Text(duplicate ? "Your Mac already had this report. Open its inbox to prepare it again." : model.destination == .inbox ? "Open the ScreenBridge inbox on your Mac." : "Check \(model.destination.title) on your Mac. Review and send the prepared prompt. If it could not open, use the report in the ScreenBridge inbox.")
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
                Text("Back to tools").frame(maxWidth: .infinity)
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
