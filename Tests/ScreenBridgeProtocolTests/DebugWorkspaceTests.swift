import Foundation
import CoreGraphics
import Testing
@testable import ScreenBridgeProtocol

@Suite struct DebugWorkspaceTests {
    @Test func independentAxisStretchPreservesOtherAxisAndStroke() {
        let shape = Annotation(tool: .rectangle, points: [SBPoint(x: 10, y: 20), SBPoint(x: 110, y: 60)])
        let wide = shape.stretched(horizontal: 2, vertical: 1)
        #expect(wide.bounds.width == 200 && wide.bounds.height == 40)
        #expect(wide.bounds.x + wide.bounds.width / 2 == 60)
        let short = wide.stretched(horizontal: 1, vertical: 0.5)
        #expect(short.bounds.width == 200 && short.bounds.height == 20)
        #expect(short.bounds.y + short.bounds.height / 2 == 40)
        #expect(short.id == shape.id && short.strokeWidth == shape.strokeWidth)
        #expect(wide.stretched(horizontal: 0.5, vertical: 1) == shape)
        #expect(shape.stretched(horizontal: 0, vertical: 1) == shape)
    }

    @Test func resizingPreservesCenterAndIdentity() {
        let arrow = Annotation(tool: .arrow, points: [SBPoint(x: 10, y: 20), SBPoint(x: 110, y: 60)])
        let large = arrow.resized(by: 1.25)
        #expect(large.id == arrow.id)
        #expect(large.bounds.width == 125)
        #expect(large.bounds.x + large.bounds.width / 2 == 60)
        #expect(large.resized(by: 0.8).points == arrow.points)
        #expect(arrow.resized(by: -1) == arrow)
    }

    @Test func annotationSelectionAndTranslation() {
        let arrow = Annotation(tool: .arrow, points: [SBPoint(x: 10, y: 10), SBPoint(x: 100, y: 100)])
        #expect(arrow.contains(SBPoint(x: 50, y: 52), tolerance: 8))
        #expect(!arrow.contains(SBPoint(x: 10, y: 90), tolerance: 8))
        let moved = arrow.translated(dx: 20, dy: -5)
        #expect(moved.id == arrow.id)
        #expect(moved.points == [SBPoint(x: 30, y: 5), SBPoint(x: 120, y: 95)])
        let rect = Annotation(tool: .rectangle, points: [SBPoint(x: 0, y: 0), SBPoint(x: 100, y: 100)])
        #expect(rect.contains(SBPoint(x: 0, y: 50), tolerance: 8))
        #expect(!rect.contains(SBPoint(x: 50, y: 50), tolerance: 8))
    }

    @Test func destinationAndRegionSurviveTransport() throws {
        var report = makeReport()
        report.claudeDestination = .desktop
        report.selectedRegion = SBRect(x: 10, y: 20, width: 40, height: 60)
        report.selection = SelectedElement(className: "UILabel", displayName: "Title", accessibilityIdentifier: nil,
                                           isSwiftUIMarker: false, frameInScreenshot: SBRect(x: 0, y: 0, width: 10, height: 10),
                                           hierarchy: [], properties: ["text": "Example", "enabled": "true"])
        let decoded = try ReportCoding.decode(ReportCoding.encode(report))
        #expect(decoded.claudeDestination == .desktop)
        #expect(decoded.selectedRegion == report.selectedRegion)
        #expect(decoded.selection?.properties?["text"] == "Example")
    }

    @Test func olderReportsHaveNoHandoffOrProperties() throws {
        let report = try ReportCoding.decode(ReportCoding.encode(makeReport()))
        #expect(report.claudeDestination == nil)
        #expect(report.selectedRegion == nil)
        #expect(report.selection?.properties == nil)
    }

    @Test func excludedEvidenceIsAbsentFromWireReport() throws {
        var report = makeReport()
        report.logs = [LogEntry(timestamp: Date(), level: "info", category: "test", message: "hello")]
        report.annotations = [Annotation(tool: .pen, points: [SBPoint(x: 1, y: 1)])]
        report.selectedRegion = SBRect(x: 0, y: 0, width: 10, height: 10)
        let options = ReportEvidenceOptions(logs: false, viewDetails: false, source: false, screenshots: false)
        let filtered = options.applying(to: report)
        #expect(filtered.logs == nil)
        #expect(filtered.selection == nil && filtered.screen == nil)
        #expect(filtered.sourceAnchors.isEmpty)
        #expect(filtered.images.isEmpty && filtered.annotations.isEmpty)
        #expect(filtered.selectedRegion == nil)
        #expect(filtered.description == report.description)
    }

    @Test func rectangleRemainsReadableByVersionOneReceivers() throws {
        struct LegacyAnnotation: Decodable {
            enum Tool: String, Decodable { case pen, ellipse, arrow, redaction }
            var tool: Tool
            var points: [SBPoint]
        }
        let rectangle = Annotation(tool: .rectangle, points: [SBPoint(x: 10, y: 20), SBPoint(x: 50, y: 60)],
                                   color: SBColor(red: 0, green: 1, blue: 0))
        let data = try ReportCoding.encoder().encode(rectangle)
        let legacy = try ReportCoding.decoder().decode(LegacyAnnotation.self, from: data)
        #expect(legacy.tool == .pen)
        #expect(legacy.points.count == 5)
        #expect(legacy.points.first == legacy.points.last)
        #expect(try ReportCoding.decoder().decode(Annotation.self, from: data) == rectangle)
    }

    @Test func rectangleUsesChosenColorAndLeavesInteriorUntouched() throws {
        let base = makeNoiseImage()
        let rectangle = Annotation(tool: .rectangle, points: [SBPoint(x: 20, y: 20), SBPoint(x: 90, y: 60)], strokeWidth: 6,
                                   color: SBColor(red: 0, green: 1, blue: 0))
        let exported = try AnnotationRenderer.export(base: base, annotations: [rectangle])
        let pixels = Pixels(try AnnotationRenderer.decodeImage(exported.annotatedPNG))
        let (r, g, b) = pixels.rgb(50, 20)
        #expect(r < 10 && g > 240 && b < 10)
        #expect(pixels.rgb(50, 40) == Pixels(base).rgb(50, 40))
        #expect(Pixels(try AnnotationRenderer.decodeImage(exported.originalPNG)).rgb(50, 20) == Pixels(base).rgb(50, 20))
    }
}
