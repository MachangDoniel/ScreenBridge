#if !SCREENBRIDGE_STRIPPED
import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

public enum RenderError: Error, CustomStringConvertible {
    case contextCreationFailed
    case imageCreationFailed
    case encodingFailed
    case decodingFailed

    public var description: String {
        switch self {
        case .contextCreationFailed: return "Could not create a drawing context."
        case .imageCreationFailed: return "Could not create an image from the drawing context."
        case .encodingFailed: return "Could not encode PNG data."
        case .decodingFailed: return "Could not decode image data."
        }
    }
}

/// The image variants that may leave the device.
///
/// When any redaction is present, *both* variants have redactions burned into their
/// pixels. No unredacted original and no thumbnail are produced.
public struct ExportedScreenshot: Sendable {
    public var originalPNG: Data
    public var annotatedPNG: Data
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var redactionApplied: Bool

    public init(originalPNG: Data, annotatedPNG: Data, pixelWidth: Int, pixelHeight: Int, redactionApplied: Bool) {
        self.originalPNG = originalPNG
        self.annotatedPNG = annotatedPNG
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.redactionApplied = redactionApplied
    }

    public func attachments() -> [ImageAttachment] {
        [
            ImageAttachment(role: .original, fileName: "original.png", pixelWidth: pixelWidth, pixelHeight: pixelHeight, byteCount: originalPNG.count, sha256: Hashing.sha256Hex(originalPNG), redacted: redactionApplied),
            ImageAttachment(role: .annotated, fileName: "annotated.png", pixelWidth: pixelWidth, pixelHeight: pixelHeight, byteCount: annotatedPNG.count, sha256: Hashing.sha256Hex(annotatedPNG), redacted: redactionApplied),
        ]
    }

    public func data(for role: ImageRole) -> Data {
        role == .original ? originalPNG : annotatedPNG
    }
}

public enum Hashing {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(_ string: String) -> String {
        sha256Hex(Data(string.utf8))
    }
}

/// Flattens vector annotations onto a screenshot with CoreGraphics.
///
/// Images are redrawn into a fresh opaque sRGB bitmap and re-encoded as PNG without
/// any properties, so no capture metadata survives export.
public enum AnnotationRenderer {
    public static func export(base: CGImage, annotations: [Annotation]) throws -> ExportedScreenshot {
        let renderable = annotations.filter(\.isRenderable)
        let hasRedaction = renderable.contains { $0.tool == .redaction }
        let original = try render(base: base, annotations: renderable, includeMarks: false)
        let annotated = try render(base: base, annotations: renderable, includeMarks: true)
        return ExportedScreenshot(
            originalPNG: try pngData(original),
            annotatedPNG: try pngData(annotated),
            pixelWidth: base.width,
            pixelHeight: base.height,
            redactionApplied: hasRedaction
        )
    }

    /// Renders `base` with redactions always applied and markup optionally applied.
    /// Redactions are drawn last so no markup can sit above a redacted region.
    public static func render(base: CGImage, annotations: [Annotation], includeMarks: Bool) throws -> CGImage {
        let w = base.width, h = base.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw RenderError.contextCreationFailed }

        ctx.interpolationQuality = .none
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Switch to a top-left origin so annotation coordinates map directly.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)

        if includeMarks {
            for a in annotations where a.tool != .redaction {
                drawMark(a, in: ctx)
            }
        }
        for a in annotations where a.tool == .redaction {
            fillRedaction(a, in: ctx, imageWidth: w, imageHeight: h)
        }
        guard let image = ctx.makeImage() else { throw RenderError.imageCreationFailed }
        return image
    }

    /// The integral pixel rect a redaction covers: rounded outward and clamped to the image.
    public static func redactionPixelRect(_ a: Annotation, imageWidth: Int, imageHeight: Int) -> CGRect {
        let r = a.bounds.cgRect
        let minX = max(0, floor(r.minX)), minY = max(0, floor(r.minY))
        let maxX = min(CGFloat(imageWidth), ceil(r.maxX)), maxY = min(CGFloat(imageHeight), ceil(r.maxY))
        guard maxX > minX, maxY > minY else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func fillRedaction(_ a: Annotation, in ctx: CGContext, imageWidth: Int, imageHeight: Int) {
        let rect = redactionPixelRect(a, imageWidth: imageWidth, imageHeight: imageHeight)
        guard !rect.isNull else { return }
        ctx.saveGState()
        ctx.setShouldAntialias(false)
        ctx.setBlendMode(.copy)
        // Redaction is always fully opaque regardless of the stored color's alpha.
        ctx.setFillColor(red: CGFloat(a.color.red), green: CGFloat(a.color.green), blue: CGFloat(a.color.blue), alpha: 1)
        ctx.fill(rect)
        ctx.restoreGState()
    }

    private static func drawMark(_ a: Annotation, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setStrokeColor(red: CGFloat(a.color.red), green: CGFloat(a.color.green), blue: CGFloat(a.color.blue), alpha: CGFloat(a.color.alpha))
        ctx.setLineWidth(CGFloat(a.strokeWidth))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let pts = a.points.map(\.cgPoint)
        switch a.tool {
        case .pen:
            if pts.count == 1 {
                let d = CGFloat(a.strokeWidth)
                ctx.setFillColor(red: CGFloat(a.color.red), green: CGFloat(a.color.green), blue: CGFloat(a.color.blue), alpha: CGFloat(a.color.alpha))
                ctx.fillEllipse(in: CGRect(x: pts[0].x - d / 2, y: pts[0].y - d / 2, width: d, height: d))
            } else {
                ctx.addLines(between: pts)
                ctx.strokePath()
            }
        case .ellipse:
            ctx.strokeEllipse(in: a.bounds.cgRect)
        case .arrow:
            guard let tail = pts.first, let head = pts.last else { break }
            ctx.move(to: tail)
            ctx.addLine(to: head)
            let angle = atan2(head.y - tail.y, head.x - tail.x)
            let length = max(18, CGFloat(a.strokeWidth) * 4)
            for delta in [CGFloat.pi * 0.83, -CGFloat.pi * 0.83] {
                ctx.move(to: head)
                ctx.addLine(to: CGPoint(x: head.x + cos(angle + delta) * length, y: head.y + sin(angle + delta) * length))
            }
            ctx.strokePath()
        case .redaction:
            break
        }
        ctx.restoreGState()
    }

    public static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else {
            throw RenderError.encodingFailed
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw RenderError.encodingFailed }
        return data as Data
    }

    public static func decodeImage(_ data: Data) throws -> CGImage {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw RenderError.decodingFailed }
        return img
    }

    /// Downscales so the longest edge is at most `maxDimension`. Returns the input when already small enough.
    public static func downscaled(_ image: CGImage, maxDimension: Int) throws -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxDimension, maxDimension > 0 else { return image }
        let s = Double(maxDimension) / Double(longest)
        let w = max(1, Int((Double(image.width) * s).rounded())), h = max(1, Int((Double(image.height) * s).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw RenderError.contextCreationFailed }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { throw RenderError.imageCreationFailed }
        return out
    }
}
#endif
