#if !SCREENBRIDGE_STRIPPED
import Foundation

public enum AnnotationTool: String, Codable, Sendable, CaseIterable {
    case pen
    case ellipse
    case arrow
    /// Opaque redaction. Pixels beneath it are destroyed in every exported image.
    case redaction
}

public struct SBColor: Codable, Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let markup = SBColor(red: 1.0, green: 0.23, blue: 0.19)
    public static let redaction = SBColor(red: 0, green: 0, blue: 0)
}

/// A vector annotation in screenshot pixel coordinates (origin top-left).
///
/// - `pen`: `points` is the stroke path.
/// - `ellipse`, `redaction`: `points[0]` and `points[1]` are opposite corners of the bounding rect.
/// - `arrow`: `points[0]` is the tail, `points[1]` is the head.
public struct Annotation: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var tool: AnnotationTool
    public var points: [SBPoint]
    public var strokeWidth: Double
    public var color: SBColor

    public init(id: UUID = UUID(), tool: AnnotationTool, points: [SBPoint], strokeWidth: Double = 6, color: SBColor? = nil) {
        self.id = id
        self.tool = tool
        self.points = points
        self.strokeWidth = strokeWidth
        self.color = color ?? (tool == .redaction ? .redaction : .markup)
    }

    /// Bounding rect for rect-based tools, or the bounds of the path for others.
    public var bounds: SBRect {
        guard let first = points.first else { return SBRect(x: 0, y: 0, width: 0, height: 0) }
        switch tool {
        case .ellipse, .redaction, .arrow:
            return SBRect(corner: first, corner: points.last ?? first)
        case .pen:
            let xs = points.map(\.x), ys = points.map(\.y)
            let minX = xs.min() ?? 0, minY = ys.min() ?? 0
            return SBRect(x: minX, y: minY, width: (xs.max() ?? 0) - minX, height: (ys.max() ?? 0) - minY)
        }
    }

    /// Whether the annotation carries enough geometry to be rendered.
    public var isRenderable: Bool {
        switch tool {
        case .pen: return points.count >= 1
        case .ellipse, .arrow, .redaction:
            guard points.count >= 2 else { return false }
            let b = bounds
            return b.width >= 1 || b.height >= 1
        }
    }
}
#endif
