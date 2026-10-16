#if !SCREENBRIDGE_STRIPPED
import Foundation

public enum AnnotationTool: String, Codable, Sendable, CaseIterable {
    case pen
    case ellipse
    case rectangle
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
/// - `ellipse`, `rectangle`, `redaction`: `points[0]` and `points[1]` are opposite corners of the bounding rect.
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

    private enum CodingKeys: String, CodingKey { case id, tool, points, strokeWidth, color, rectangle }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        tool = try c.decode(AnnotationTool.self, forKey: .tool)
        points = try c.decode([SBPoint].self, forKey: .points)
        strokeWidth = try c.decode(Double.self, forKey: .strokeWidth)
        color = try c.decode(SBColor.self, forKey: .color)
        if tool == .pen, let corners = try c.decodeIfPresent([SBPoint].self, forKey: .rectangle), corners.count >= 2 {
            tool = .rectangle
            points = corners
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(strokeWidth, forKey: .strokeWidth)
        try c.encode(color, forKey: .color)
        if tool == .rectangle {
            // Schema 1.0 readers understand pen paths and ignore unknown fields.
            // Preserve the rectangle's semantic tool/corners for newer readers.
            let rect = bounds
            let path = [SBPoint(x: rect.x, y: rect.y), SBPoint(x: rect.x + rect.width, y: rect.y),
                        SBPoint(x: rect.x + rect.width, y: rect.y + rect.height),
                        SBPoint(x: rect.x, y: rect.y + rect.height), SBPoint(x: rect.x, y: rect.y)]
            try c.encode(AnnotationTool.pen, forKey: .tool)
            try c.encode(path, forKey: .points)
            try c.encode(points, forKey: .rectangle)
        } else {
            try c.encode(tool, forKey: .tool)
            try c.encode(points, forKey: .points)
        }
    }

    /// Bounding rect for rect-based tools, or the bounds of the path for others.
    public var bounds: SBRect {
        guard let first = points.first else { return SBRect(x: 0, y: 0, width: 0, height: 0) }
        switch tool {
        case .ellipse, .rectangle, .redaction, .arrow:
            return SBRect(corner: first, corner: points.last ?? first)
        case .pen:
            let xs = points.map(\.x), ys = points.map(\.y)
            let minX = xs.min() ?? 0, minY = ys.min() ?? 0
            return SBRect(x: minX, y: minY, width: (xs.max() ?? 0) - minX, height: (ys.max() ?? 0) - minY)
        }
    }

    /// Hit testing uses screenshot pixels; callers scale touch tolerance to match.
    public func contains(_ point: SBPoint, tolerance: Double) -> Bool {
        let b = bounds
        let padding = max(tolerance, strokeWidth / 2)
        guard point.x >= b.x - padding, point.x <= b.x + b.width + padding,
              point.y >= b.y - padding, point.y <= b.y + b.height + padding else { return false }
        if tool == .redaction { return true }
        func nearSegment(_ a: SBPoint, _ z: SBPoint) -> Bool {
            let dx = z.x - a.x, dy = z.y - a.y
            let length = dx * dx + dy * dy
            let t = length == 0 ? 0 : min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length))
            return hypot(point.x - a.x - t * dx, point.y - a.y - t * dy) <= padding
        }
        switch tool {
        case .pen, .arrow:
            guard let first = points.first else { return false }
            if points.count == 1 { return nearSegment(first, first) }
            return zip(points, points.dropFirst()).contains { nearSegment($0.0, $0.1) }
        case .rectangle:
            return min(abs(point.x - b.x), abs(point.x - b.x - b.width),
                       abs(point.y - b.y), abs(point.y - b.y - b.height)) <= padding
        case .ellipse:
            let rx = b.width / 2, ry = b.height / 2
            guard rx > 0, ry > 0 else { return nearSegment(points[0], points[points.count - 1]) }
            let angle = atan2((point.y - b.y - ry) / ry, (point.x - b.x - rx) / rx)
            return hypot(point.x - b.x - rx - rx * cos(angle), point.y - b.y - ry - ry * sin(angle)) <= padding
        case .redaction: return true
        }
    }

    public func translated(dx: Double, dy: Double) -> Annotation {
        var result = self
        result.points = points.map { SBPoint(x: $0.x + dx, y: $0.y + dy) }
        return result
    }

    /// Resize around the annotation's center without changing its identity.
    public func resized(by factor: Double) -> Annotation {
        guard factor.isFinite, factor > 0 else { return self }
        let center = SBPoint(x: bounds.x + bounds.width / 2, y: bounds.y + bounds.height / 2)
        var result = self
        result.points = points.map {
            SBPoint(x: center.x + ($0.x - center.x) * factor,
                    y: center.y + ($0.y - center.y) * factor)
        }
        result.strokeWidth = min(100, max(1, strokeWidth * factor))
        return result
    }

    /// Whether the annotation carries enough geometry to be rendered.
    public var isRenderable: Bool {
        switch tool {
        case .pen: return points.count >= 1
        case .ellipse, .rectangle, .arrow, .redaction:
            guard points.count >= 2 else { return false }
            let b = bounds
            return b.width >= 1 || b.height >= 1
        }
    }
}
#endif
