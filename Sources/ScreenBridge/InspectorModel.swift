#if SCREENBRIDGE_ENABLED && canImport(UIKit)
import UIKit
import SwiftUI
import ScreenBridgeProtocol
import ScreenBridgeTransport

enum InspectorRoute: Hashable {
    case screenSource
    case report
    case preview
    case status
}

/// State shared by the inspector sheets for one inspection.
@MainActor
final class InspectorModel: ObservableObject {
    let connection: ConnectionManager
    let capture: CapturedScreen?
    let screen: ResolvedSelection?

    @Published var path: [InspectorRoute] = []
    @Published var selection: ResolvedSelection?
    weak var selectedView: UIView?

    @Published var revealInFlight = false
    @Published var revealMessage: String?

    // Report editor
    @Published var annotations: [Annotation] = []
    @Published var tool: AnnotationTool = .pen
    @Published var reportDescription = ""
    @Published var includeLogs = false
    @Published var sendState: ConnectionManager.SendState?
    @Published var exportError: String?
    private var reportID = ReportID.make()
    private var reportCreatedAt = Date()

    var onInspectElement: () -> Void = {}
    var onClose: () -> Void = {}
    var onSelectParent: () -> Void = {}
    var canSelectParent: () -> Bool = { false }

    init(connection: ConnectionManager, capture: CapturedScreen?, screen: ResolvedSelection?) {
        self.connection = connection
        self.capture = capture
        self.screen = screen
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
        annotations = []
        sendState = nil
        if annotateSelection, let frame = selection?.element?.frameInScreenshot, let capture {
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
        _ = annotations.popLast()
    }

    var hasRedaction: Bool { annotations.contains { $0.tool == .redaction } }

    /// Builds exactly what will be sent. The preview uses this same function.
    func buildPayload() throws -> (report: DebugReport, exported: ExportedScreenshot) {
        guard let capture else { throw RenderError.imageCreationFailed }
        let exported = try AnnotationRenderer.export(base: capture.cgImage, annotations: annotations)
        let context = reportContext
        let build = connection.config?.build ?? .unconfigured
        let report = DebugReport(
            id: reportID,
            createdAt: reportCreatedAt,
            description: reportDescription.trimmingCharacters(in: .whitespacesAndNewlines),
            screenshot: capture.geometry,
            images: exported.attachments(),
            annotations: annotations,
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
        let parts: [(name: String, data: Data)] = [
            ("original.png", payload.exported.originalPNG),
            ("annotated.png", payload.exported.annotatedPNG),
        ]
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
