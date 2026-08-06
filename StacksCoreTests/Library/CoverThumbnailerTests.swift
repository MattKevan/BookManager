import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import StacksCore

@Suite
struct CoverThumbnailerTests {
    /// Writes a solid-color JPEG of the given pixel size to a temp URL.
    private func makeJPEG(width: Int, height: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "cover-\(UUID().uuidString).jpg")
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.jpeg" as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw TestImageError.encodeFailed
        }
        return url
    }

    @Test
    func downsampleBoundsLongestSide() throws {
        // A 2:3 cover like a typical book cover: 1200 x 1800 px.
        let url = try makeJPEG(width: 1200, height: 1800)
        defer { try? FileManager.default.removeItem(at: url) }

        let thumbnail = try #require(CoverThumbnailer.downsample(url: url, maxPixelSize: 320))

        // The longest side is capped at maxPixelSize — never a full-res decode.
        #expect(max(thumbnail.width, thumbnail.height) <= 320)
        // Aspect ratio is preserved: 2:3 -> 213 x 320-ish.
        #expect(Double(thumbnail.height) / Double(thumbnail.width) > 1.4)
        #expect(thumbnail.width < 1200)
    }

    @Test
    func downsampleKeepsSmallImagesSmall() throws {
        // Images smaller than the target are not upscaled.
        let url = try makeJPEG(width: 100, height: 150)
        defer { try? FileManager.default.removeItem(at: url) }

        let thumbnail = try #require(CoverThumbnailer.downsample(url: url, maxPixelSize: 640))
        #expect(thumbnail.width <= 100)
        #expect(thumbnail.height <= 150)
    }

    @Test
    func downsampleMissingFileReturnsNil() {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "does-not-exist-\(UUID().uuidString).jpg")
        #expect(CoverThumbnailer.downsample(url: missing, maxPixelSize: 320) == nil)
    }
}

private enum TestImageError: Error {
    case encodeFailed
}
