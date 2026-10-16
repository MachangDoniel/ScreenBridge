#if SCREENBRIDGE_ENABLED && canImport(UIKit)
import UIKit
import SwiftUI
import Combine
import ScreenBridgeProtocol
import ScreenBridgeTransport

enum InspectorRoute: Hashable {
    case screenSource
    case report
    case preview
    case status
    case logs
    case selectedSource
}

/// State shared by the inspector sheets for one inspection.
@MainActor
final class InspectorModel: ObservableObject {
    let connection: ConnectionManager
    let capture: CapturedScreen?
    let screen: ResolvedSelection?

    @Published var path: [InspectorRoute] = []
    @Published var selection: ResolvedSelection? {
        didSet { var before = editState; before.selection = oldValue; record(before) }
    }
    weak var selectedView: UIView?

    @Published var revealInFlight = false
    @Published var revealMessage: String?

    // Report editor
    @Published var annotations: [Annotation] = [] {
        didSet {
            guard annotations != oldValue else { return }
            var before = editState; before.annotations = oldValue; record(before)
        }
    }
    @Published var tool: AnnotationTool = .pen
    @Published var reportDescription = ""
    @Published var includeLogs = false
    @Published var includeViewDetails = true
    @Published var includeSource = true
    @Published var includeScreenshots = true
    @Published var destination: ClaudeDestination = .reference
    @Published var annotationColor = SBColor.markup
    @Published var workspaceMode: WorkspaceMode = .inspect
    @Published var selectedRegion: SBRect? {
        didSet {
            guard selectedRegion != oldValue else { return }
            var before = editState; before.region = oldValue; record(before)
        }
    }

    private struct EditState {
        var annotations: [Annotation]
        var selection: ResolvedSelection?
        var region: SBRect?
        weak var view: UIView?
    }
    @Published private var undoHistory: [EditState] = []
    @Published private var redoHistory: [EditState] = []
    private var restoringHistory = false
    var canUndo: Bool { !undoHistory.isEmpty }
    var canRedo: Bool { !redoHistory.isEmpty }
    var hasEdits: Bool {
        !annotations.isEmpty || selection != nil || selectedRegion != nil
            || !reportDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var editState: EditState {
        EditState(annotations: annotations, selection: selection, region: selectedRegion, view: selectedView)
    }

    private func record(_ before: EditState) {
        guard !restoringHistory else { return }
        undoHistory.append(before)
        if undoHistory.count > 50 { undoHistory.removeFirst() }
        redoHistory.removeAll()
    }

    private func restore(_ state: EditState) {
        restoringHistory = true
        annotations = state.annotations
        selection = state.selection
        selectedRegion = state.region
        selectedView = state.view
        restoringHistory = false
    }

    func select(_ resolved: ResolvedSelection, view: UIView) {
        let before = editState
        restoringHistory = true
        selection = resolved
        selectedView = view
        selectedRegion = nil
        restoringHistory = false
        record(before)
    }

    func selectArea(_ region: SBRect) {
        let before = editState
        restoringHistory = true
        selection = nil
        selectedView = nil
        selectedRegion = region
        restoringHistory = false
        record(before)
    }

    func deleteAll() {
        let before = editState
        restoringHistory = true
        annotations = []
        selection = nil
        selectedRegion = nil
        selectedView = nil
        restoringHistory = false
        workspaceMode = .inspect
        record(before)
    }

    enum WorkspaceMode { case inspect, area, draw, editAnnotations }
    var onSelectPoint: (SBPoint) -> Void = { _ in }
    @Published var sendState: ConnectionManager.SendState?
    @Published var exportError: String?
    private var deliveryObserver: AnyCancellable?
    private var reportID = ReportID.make()
    private var reportCreatedAt = Date()

    var onInspectElement: () -> Void = {}
    var onClose: () -> Void = {}
    var onExit: () -> Void = {}
    var onSelectParent: () -> Void = {}
    var canSelectParent: () -> Bool = { false }

    init(connection: ConnectionManager, capture: CapturedScreen?, screen: ResolvedSelection?) {
        self.connection = connection
        self.capture = capture
        self.screen = screen
        deliveryObserver = connection.$lastDelivery.sink { [weak self] state in
            guard let self, let state else { return }
            switch state {
            case .acknowledged(let id, _) where id == self.reportID,
                 .failed(let id, _) where id == self.reportID:
                self.sendState = state
                self.announce(state)
            default: break
            }
        }
    }

    /// The context a report is about: the selected element, or the whole screen.
    var reportContext: ResolvedSelection? { selection ?? screen }

    var availableLogCount: Int { LogStore.shared.recent().count }

    // MARK: Reveal

    func reveal(_ anchor: SourceAnchor) {
        revealInFlight = true
        revealMessage = nil
        Task {
            let result = await connection.reveal(anchor)
            revealInFlight = false
            revealMessage = result.message
            UIAccessibility.post(notification: .announcement, argument: result.message)
        }
    }

    // MARK: Report

    func beginReport(annotateSelection: Bool) {
        reportID = ReportID.make()
        reportCreatedAt = Date()
        sendState = nil
        if annotateSelection, annotations.isEmpty, let frame = selection?.element?.frameInScreenshot, let capture {
            // Start with an ellipse around the element; the user can undo it.
            let pad = 12 * Double(capture.scale)
            annotations = [Annotation(tool: .ellipse, points: [
                SBPoint(x: frame.x - pad, y: frame.y - pad),
                SBPoint(x: frame.x + frame.width + pad, y: frame.y + frame.height + pad),
            ], strokeWidth: 3 * Double(capture.scale))]
        }
        path.append(.report)
    }

    func undo() {
        guard let previous = undoHistory.popLast() else { return }
        redoHistory.append(editState)
        restore(previous)
    }

    func redo() {
        guard let next = redoHistory.popLast() else { return }
        undoHistory.append(editState)
        restore(next)
    }

    var hasRedaction: Bool { annotations.contains { $0.tool == .redaction } }

    /// Builds exactly what will be sent. The preview uses this same function.
    func buildPayload() throws -> (report: DebugReport, exported: ExportedScreenshot) {
        guard let capture else { throw RenderError.imageCreationFailed }
        let region = selectedRegion ?? selection?.element?.frameInScreenshot
        let outline = region.map { rect in
            Annotation(tool: .rectangle, points: [SBPoint(x: rect.x, y: rect.y),
                                                  SBPoint(x: rect.x + rect.width, y: rect.y + rect.height)],
                       strokeWidth: 2 * Double(capture.scale), color: SBColor(red: 0, green: 0.7, blue: 1))
        }
        let exportAnnotations = annotations + (outline.map { [$0] } ?? [])
        let exported = try AnnotationRenderer.export(base: capture.cgImage, annotations: exportAnnotations)
        let context = reportContext
        let build = connection.config?.build ?? .unconfigured
        var report = DebugReport(
            id: reportID,
            createdAt: reportCreatedAt,
            description: reportDescription.trimmingCharacters(in: .whitespacesAndNewlines),
            screenshot: capture.geometry,
            images: exported.attachments(),
            annotations: exportAnnotations,
            redactionApplied: exported.redactionApplied,
            selection: selection?.element,
            screen: context?.screen,
            sourceAnchors: context?.allAnchors ?? [],
            app: DeviceMetadata.app(),
            device: DeviceMetadata.current(),
            build: build,
            logs: includeLogs ? LogStore.shared.recent() : nil,
            transfer: TransferMetadata(queuedAt: Date(), attempt: 0)
        )
        report.claudeDestination = destination
        report.selectedRegion = selectedRegion
        report = ReportEvidenceOptions(logs: includeLogs, viewDetails: includeViewDetails, source: includeSource,
                                       screenshots: includeScreenshots).applying(to: report)
        return (report, exported)
    }

    func send() {
        exportError = nil
        let payload: (report: DebugReport, exported: ExportedScreenshot)
        do { payload = try buildPayload() } catch {
            exportError = "Couldn't prepare the screenshot: \(error)"
            return
        }
        sendState = .sending
        if path.last != .status { path.append(.status) }
        let parts: [(name: String, data: Data)] = includeScreenshots ? [
            ("original.png", payload.exported.originalPNG),
            ("annotated.png", payload.exported.annotatedPNG),
        ] : []
        Task {
            let state = await connection.enqueueAndSend(report: payload.report, parts: parts)
            sendState = state
            announce(state)
        }
    }

    func retrySend() {
        switch sendState {
        case .failed(let id, _), .queued(let id, _): retry(id)
        default: break
        }
    }

    private func retry(_ id: String) {
        sendState = .sending
        Task {
            let state = await connection.retry(reportID: id)
            sendState = state
            announce(state)
        }
    }

    private func announce(_ state: ConnectionManager.SendState) {
        let text: String
        switch state {
        case .sending: return
        case .acknowledged(let id, _): text = "On your Mac. Report \(id) is ready."
        case .queued(_, let reason): text = "Report saved. \(reason)"
        case .failed(_, let err): text = "Sending failed. \(err)"
        }
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}
#endif
