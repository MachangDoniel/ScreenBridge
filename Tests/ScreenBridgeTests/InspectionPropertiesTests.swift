#if SCREENBRIDGE_ENABLED && canImport(UIKit)
import UIKit
import Testing
@testable import ScreenBridge

@MainActor
@Suite struct InspectionPropertiesTests {
    @Test func labelAndButtonExposeUsefulValues() {
        let label = UILabel()
        label.text = "Account overview"
        #expect(ElementInspector.properties(of: label)["text"] == "Account overview")
        let button = UIButton(type: .system)
        button.setTitle("Transfer", for: .normal)
        button.isEnabled = false
        #expect(ElementInspector.properties(of: button)["title"] == "Transfer")
        #expect(ElementInspector.properties(of: button)["enabled"] == "false")
    }

    @Test func secureTextDoesNotLeaveTheView() {
        let field = UITextField()
        field.isSecureTextEntry = true
        field.text = "private-password"
        field.accessibilityLabel = "private-password"
        field.accessibilityValue = "private-password"
        let values = ElementInspector.properties(of: field)
        #expect(!values.values.contains { $0.contains("private-password") })
        #expect(values["text"] == "Secure input (omitted)")
    }
}
#endif

#if SCREENBRIDGE_ENABLED && canImport(UIKit)
import ScreenBridgeProtocol

@MainActor
@Suite struct InspectorPayloadTests {
    private func model() -> InspectorModel {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 60), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 60))
        }
        let capture = CapturedScreen(image: image, cgImage: image.cgImage!, pointSize: image.size, scale: 1,
                                     orientation: "portrait", capturedAt: Date())
        return InspectorModel(connection: ConnectionManager(config: nil, configProblem: "test", outboxCapacity: 1),
                              capture: capture, screen: nil)
    }

    @Test func annotationUndoRedoPreservesStrokeAndClearsRedoOnNewEdit() {
        let model = model()
        let stroke = Annotation(tool: .pen, points: [SBPoint(x: 1, y: 1), SBPoint(x: 5, y: 5)])
        #expect(!model.hasEdits && !model.canUndo && !model.canRedo)
        model.annotations.append(stroke)
        #expect(model.hasEdits && model.canUndo)
        model.undo()
        #expect(model.annotations.isEmpty && model.canRedo && !model.hasEdits)
        model.redo()
        #expect(model.annotations == [stroke] && !model.canRedo)
        model.undo()
        model.annotations.append(Annotation(tool: .arrow, points: [SBPoint(x: 2, y: 2), SBPoint(x: 8, y: 8)]))
        #expect(!model.canRedo)
    }

    @Test func deleteAllRestoresSelectionModeAndIsOneUndoStep() {
        let model = model()
        let stroke = Annotation(tool: .pen, points: [SBPoint(x: 1, y: 1), SBPoint(x: 5, y: 5)])
        model.annotations = [stroke]
        model.selectArea(SBRect(x: 1, y: 2, width: 3, height: 4))
        model.workspaceMode = .draw
        model.deleteAll()
        #expect(!model.hasEdits && model.workspaceMode == .inspect)
        model.undo()
        #expect(model.annotations == [stroke] && model.selectedRegion != nil)
        model.redo()
        #expect(!model.hasEdits)
    }

    @Test func selectedAreaEnablesActionsAndSupportsUndoRedo() {
        let model = model()
        let area = SBRect(x: 1, y: 2, width: 3, height: 4)
        model.selectedRegion = area
        #expect(model.hasEdits && model.canUndo)
        model.undo()
        #expect(model.selectedRegion == nil && !model.hasEdits)
        model.redo()
        #expect(model.selectedRegion == area && model.hasEdits)
    }

    @Test func selectedAreaIsOutlinedInExportAndCodeIsDefault() throws {
        let model = model()
        let area = SBRect(x: 5, y: 10, width: 20, height: 30)
        model.selectedRegion = area
        let payload = try model.buildPayload()
        #expect(payload.report.claudeDestination == .code)
        #expect(payload.report.selectedRegion == area)
        #expect(payload.report.annotations.last?.tool == .rectangle)
        #expect(payload.report.annotations.last?.bounds == area)
        #expect(payload.exported.annotatedPNG != payload.exported.originalPNG)
    }

    @Test func disablingScreenshotsAndLogsRemovesThemFromPreparedReport() throws {
        let model = model()
        model.selectedRegion = SBRect(x: 5, y: 10, width: 20, height: 30)
        model.includeScreenshots = false
        model.includeLogs = false
        let payload = try model.buildPayload()
        #expect(payload.report.images.isEmpty)
        #expect(payload.report.annotations.isEmpty)
        #expect(payload.report.selectedRegion == nil)
        #expect(payload.report.logs == nil)
    }
}
#endif
