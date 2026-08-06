import CoreGraphics
import Foundation
import ImageIO

/// Downsampled cover decoding (WWDC 2018 "Image and Graphics Best
/// Practices"): `CGImageSourceCreateThumbnailAtIndex` with
/// `kCGImageSourceThumbnailMaxPixelSize` decodes the image AT the target
/// size instead of materializing a full-resolution bitmap. Scrolling a large
/// library then decodes only a small thumbnail per visible cover — no
/// gigabytes of full-res buffers, no per-cell main-thread decode stall.
public enum CoverThumbnailer {
    /// Decodes a downsampled version of the image at `url`, with the longest
    /// side capped at `maxPixelSize` (aspect ratio preserved). Never decodes
    /// the full image; returns nil for a missing/unreadable file. Thread-safe
    /// (ImageIO) — safe to call from a background queue.
    public static func downsample(url: URL, maxPixelSize: CGFloat) -> CGImage? {
        // Don't let the source cache the full-resolution image.
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
    }
}
