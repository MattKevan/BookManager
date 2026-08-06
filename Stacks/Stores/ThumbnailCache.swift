import AppKit
import StacksCore
import Foundation
import QuickLookThumbnailing

/// Memory-bounded cache of downsampled cover thumbnails.
///
/// Best practices applied (WWDC 2018 "Image and Graphics Best Practices"):
/// - covers are decoded SMALL via ImageIO (`CoverThumbnailer.downsample`) —
///   never a full-resolution bitmap, so a 2k+ book library's covers stay at a
///   bounded footprint instead of GBs of decoded images;
/// - the decode runs off the main actor on a SERIAL queue — a fast scroll
///   must not spawn one decode thread per visible cell;
/// - the CGImage is wrapped into an NSImage on the main actor (NSImage is not
///   Sendable / unsafe cross-thread);
/// - `NSCache` (not a dictionary) auto-evicts under memory pressure, costed
///   in decoded pixel bytes.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    /// Longest-side cap for cover thumbnails — 2x the ~180pt grid column
    /// width (retina), matching the QL fallback's proportions.
    nonisolated private static let maxPixelSize: CGFloat = 640
    /// Serial: one decode at a time, so scrolling can't fan out a decode
    /// thread per visible cell (WWDC's thread-explosion warning).
    nonisolated private static let decodeQueue = DispatchQueue(
        label: "com.mattkevan.stacks.cover-thumbnail.decode", qos: .utility
    )

    private let cache = NSCache<NSString, NSImage>()

    init() {
        // ~256 MB of decoded pixels; NSCache evicts under memory pressure.
        cache.totalCostLimit = 256 * 1024 * 1024
        cache.countLimit = 1024
    }

    func thumbnail(for book: IndexedBook, repository: LibraryRepository?) async -> NSImage? {
        let key = cacheKey(for: book)
        if let cached = cache.object(forKey: key as NSString) { return cached }

        // Prefer the materialized cover file, downsampled off the main actor.
        if let repository, !book.relativePath.isEmpty, book.coverHash != nil {
            let coverURL = repository.root
                .appending(path: book.relativePath, directoryHint: .isDirectory)
                .appending(path: "cover.jpg")
            if let cgImage = await Self.decodeCover(url: coverURL) {
                let image = NSImage(
                    cgImage: cgImage,
                    size: NSSize(width: cgImage.width, height: cgImage.height)
                )
                cache.setObject(image, forKey: key as NSString, cost: Self.cost(of: cgImage))
                return image
            }
        }

        // Fall back to a QuickLook thumbnail of the first format file.
        guard let repository, let url = try? await repository.formatFileURL(id: book.id) else {
            return nil
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 240, height: 340),
            scale: 1,
            representationTypes: .thumbnail
        )
        let image = await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.nsImage)
            }
        }
        if let image {
            cache.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
        }
        return image
    }

    /// Decodes the cover downsampled, off the main actor on the serial decode
    /// queue. Returns the small decoded CGImage; the caller wraps it in an
    /// NSImage on the main actor.
    private nonisolated static func decodeCover(url: URL) async -> CGImage? {
        await withCheckedContinuation { continuation in
            decodeQueue.async {
                continuation.resume(
                    returning: CoverThumbnailer.downsample(url: url, maxPixelSize: maxPixelSize)
                )
            }
        }
    }

    /// Decoded pixel bytes — the NSCache cost.
    private static func cost(of cgImage: CGImage) -> Int {
        cgImage.bytesPerRow * cgImage.height
    }

    /// Conservative decoded-bytes estimate for a QL-provided image.
    private static func cost(of image: NSImage) -> Int {
        Int(image.size.width * image.size.height * 4)
    }

    /// Cache identity includes the cover + first-format content hashes, so an
    /// edited cover naturally produces a new entry (the old one is evicted by
    /// NSCache under pressure — no explicit invalidation needed).
    private func cacheKey(for book: IndexedBook) -> String {
        "\(book.id.uuidString)|\(book.coverHash ?? "")|\(book.formats.first?.contentHash ?? "")"
    }
}
