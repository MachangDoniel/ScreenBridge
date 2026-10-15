import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import ScreenBridgeProtocol

/// A noisy test image so redaction can't accidentally "pass" on a uniform background.
func makeNoiseImage(width: Int = 120, height: Int = 80) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    for y in 0..<height {
        for x in 0..<width {
            ctx.setFillColor(red: CGFloat((x * 37 + y * 11) % 256) / 255, green: CGFloat((x * 13 + y * 29) % 256) / 255, blue: 0.9, alpha: 1)
            ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }
    return ctx.makeImage()!
}

/// Reads pixels in top-left coordinates as RGBA bytes.
struct Pixels {
    let width: Int, height: Int
    let bytes: [UInt8]

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(data: &buf, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = buf
    }

    /// `y` measured from the top. CGBitmapContext memory is top-row first.
    func rgb(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        let i = (y * width + x) * 4
        return (bytes[i], bytes[i + 1], bytes[i + 2])
    }
}

@Suite struct AnnotationRendererTests {
    @Test func redactionDestroysPixelsInEveryExportedVariant() throws {
        let base = makeNoiseImage()
        // Fractional coordinates must round outward.
        let redaction = Annotation(tool: .redaction, points: [SBPoint(x: 10.4, y: 20.6), SBPoint(x: 50.2, y: 40.1)])
        let mark = Annotation(tool: .pen, points: [SBPoint(x: 0, y: 30), SBPoint(x: 119, y: 30)], strokeWidth: 8)
        let exported = try AnnotationRenderer.export(base: base, annotations: [mark, redaction])
        #expect(exported.redactionApplied)

        for png in [exported.originalPNG, exported.annotatedPNG] {
            let px = Pixels(try AnnotationRenderer.decodeImage(png))
            for y in 20..<41 {
                for x in 10..<51 {
                    let (r, g, b) = px.rgb(x, y)
                    #expect(r == 0 && g == 0 && b == 0, "pixel (\(x),\(y)) not redacted")
                }
            }
            // A pixel outside the redaction keeps original noise.
            #expect(px.rgb(100, 70) != (0, 0, 0))
        }
        let allRedacted = exported.attachments().allSatisfy { $0.redacted }
        #expect(allRedacted)
    }

    @Test func originalIsUnmarkedAndAnnotatedHasMarks() throws {
        let base = makeNoiseImage()
        let mark = Annotation(tool: .pen, points: [SBPoint(x: 0, y: 40), SBPoint(x: 119, y: 40)], strokeWidth: 6)
        let exported = try AnnotationRenderer.export(base: base, annotations: [mark])
        #expect(!exported.redactionApplied)
        let original = Pixels(try AnnotationRenderer.decodeImage(exported.originalPNG))
        let annotated = Pixels(try AnnotationRenderer.decodeImage(exported.annotatedPNG))
        let source = Pixels(base)
        #expect(original.rgb(60, 40) == source.rgb(60, 40))
        let (r, g, _) = annotated.rgb(60, 40)
        #expect(r > 240 && g < 80, "expected markup red at the stroke")
        // Top-left coordinates: the stroke at y=40 must not appear at the vertically mirrored row.
        #expect(annotated.rgb(60, 10) == source.rgb(60, 10))
    }

    @Test func exportedPNGCarriesNoMetadata() throws {
        let exported = try AnnotationRenderer.export(base: makeNoiseImage(), annotations: [])
        let src = CGImageSourceCreateWithData(exported.annotatedPNG as CFData, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        // ImageIO synthesizes color space and dimensions; nothing else may be present.
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let allowedExif: Set<String> = ["ColorSpace", "PixelXDimension", "PixelYDimension"]
        #expect(Set(exif.keys.map { $0 as String }).isSubset(of: allowedExif))
        #expect(props[kCGImagePropertyMakerAppleDictionary] == nil)
        #expect(props[kCGImagePropertyGPSDictionary] == nil)
        #expect(props[kCGImagePropertyTIFFDictionary] == nil)
        #expect(CGImageSourceGetCount(src) == 1)
    }

    @Test func redactionRectIsClampedToImage() {
        let a = Annotation(tool: .redaction, points: [SBPoint(x: -20, y: -5), SBPoint(x: 500, y: 10.2)])
        #expect(AnnotationRenderer.redactionPixelRect(a, imageWidth: 120, imageHeight: 80) == CGRect(x: 0, y: 0, width: 120, height: 11))
    }

    @Test func aspectFitMappingRoundTrips() {
        // 1179x2556 pixel screenshot shown in a 300x400 point canvas.
        let m = AspectFitMapping(imagePixelSize: CGSize(width: 1179, height: 2556), viewSize: CGSize(width: 300, height: 400))
        #expect(abs(m.displayRect.height - 400) < 0.001)
        #expect(m.displayRect.minX > 0) // letterboxed horizontally
        let img = CGPoint(x: 589.5, y: 1278)
        let view = m.viewPoint(fromImage: img)
        #expect(abs(view.x - 150) < 0.001 && abs(view.y - 200) < 0.001)
        let back = m.imagePoint(fromView: view)
        #expect(abs(back.x - img.x) < 0.001 && abs(back.y - img.y) < 0.001)
        // Points in the letterbox clamp to the image edge.
        #expect(m.imagePoint(fromView: CGPoint(x: 0, y: 0)) == CGPoint(x: 0, y: 0))
    }

    @Test func screenshotGeometryConvertsPointsToPixels() {
        let g = ScreenshotGeometry(pixelWidth: 1179, pixelHeight: 2556, scale: 3, interfaceOrientation: "portrait")
        #expect(g.pixelRect(fromPoints: SBRect(x: 10, y: 20, width: 30, height: 40)) == SBRect(x: 30, y: 60, width: 90, height: 120))
    }

    @Test func downscaleBoundsLongestEdge() throws {
        let img = try AnnotationRenderer.downscaled(makeNoiseImage(width: 400, height: 100), maxDimension: 200)
        #expect(img.width == 200 && img.height == 50)
    }
}
