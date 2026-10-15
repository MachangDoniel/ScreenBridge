#if !SCREENBRIDGE_STRIPPED
import Foundation
import CoreGraphics

/// A point in a named coordinate space. Report geometry always uses screenshot
/// image pixels with the origin at the top-left corner unless documented otherwise.
public struct SBPoint: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public init(_ point: CGPoint) {
        self.init(x: Double(point.x), y: Double(point.y))
    }

    public var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

public struct SBSize: Codable, Sendable, Hashable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public init(_ size: CGSize) {
        self.init(width: Double(size.width), height: Double(size.height))
    }

    public var cgSize: CGSize { CGSize(width: width, height: height) }
}

public struct SBRect: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) {
        let r = rect.standardized
        self.init(x: Double(r.origin.x), y: Double(r.origin.y), width: Double(r.width), height: Double(r.height))
    }

    /// Rect spanning two corner points in any order.
    public init(corner a: SBPoint, corner b: SBPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// Describes how screenshot pixels relate to the device screen.
public struct ScreenshotGeometry: Codable, Sendable, Equatable {
    /// Always `"image-pixels-top-left"` in schema 1.x: x grows right, y grows down, units are pixels.
    public var coordinateSpace: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Screen scale (pixels per point) at capture time.
    public var scale: Double
    public var interfaceOrientation: String

    public static let imagePixelsTopLeft = "image-pixels-top-left"

    public init(pixelWidth: Int, pixelHeight: Int, scale: Double, interfaceOrientation: String) {
        self.coordinateSpace = Self.imagePixelsTopLeft
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.interfaceOrientation = interfaceOrientation
    }

    /// Converts a rect in screen points into screenshot pixels.
    public func pixelRect(fromPoints rect: SBRect) -> SBRect {
        SBRect(x: rect.x * scale, y: rect.y * scale, width: rect.width * scale, height: rect.height * scale)
    }
}

/// Maps between a view that displays an image aspect-fit and the image's pixel space.
public struct AspectFitMapping: Sendable, Equatable {
    public let imagePixelSize: CGSize
    public let viewSize: CGSize
    /// Where the image is drawn inside the view, in view points.
    public let displayRect: CGRect
    /// View points per image pixel.
    public let pointsPerPixel: CGFloat

    public init(imagePixelSize: CGSize, viewSize: CGSize) {
        self.imagePixelSize = imagePixelSize
        self.viewSize = viewSize
        guard imagePixelSize.width > 0, imagePixelSize.height > 0, viewSize.width > 0, viewSize.height > 0 else {
            displayRect = .zero
            pointsPerPixel = 0
            return
        }
        let s = min(viewSize.width / imagePixelSize.width, viewSize.height / imagePixelSize.height)
        let size = CGSize(width: imagePixelSize.width * s, height: imagePixelSize.height * s)
        displayRect = CGRect(
            x: (viewSize.width - size.width) / 2,
            y: (viewSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        pointsPerPixel = s
    }

    /// View point → image pixel, clamped to the image bounds.
    public func imagePoint(fromView p: CGPoint) -> CGPoint {
        guard pointsPerPixel > 0 else { return .zero }
        let x = (p.x - displayRect.minX) / pointsPerPixel
        let y = (p.y - displayRect.minY) / pointsPerPixel
        return CGPoint(
            x: min(max(x, 0), imagePixelSize.width),
            y: min(max(y, 0), imagePixelSize.height)
        )
    }

    /// Image pixel → view point.
    public func viewPoint(fromImage p: CGPoint) -> CGPoint {
        CGPoint(x: displayRect.minX + p.x * pointsPerPixel, y: displayRect.minY + p.y * pointsPerPixel)
    }
}
#endif
