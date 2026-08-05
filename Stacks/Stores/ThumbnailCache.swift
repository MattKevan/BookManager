import AppKit
import StacksCore
import Foundation
import QuickLookThumbnailing

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private var memory: [String: NSImage] = [:]

    func thumbnail(for book: IndexedBook, repository: LibraryRepository?) async -> NSImage? {
        let key = cacheKey(for: book)
        if let cached = memory[key] { return cached }

        // Prefer the materialized cover file.
        if let repository, !book.relativePath.isEmpty, book.coverHash != nil {
            let coverURL = repository.root
                .appending(path: book.relativePath, directoryHint: .isDirectory)
                .appending(path: "cover.jpg")
            if let image = NSImage(contentsOf: coverURL) {
                memory[key] = image
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
            memory[key] = image
        }
        return image
    }

    private func cacheKey(for book: IndexedBook) -> String {
        "\(book.id.uuidString)|\(book.coverHash ?? "")|\(book.formats.first?.contentHash ?? "")"
    }

    func remove(_ id: UUID) {
        let prefix = "\(id.uuidString)|"
        for key in memory.keys where key.hasPrefix(prefix) {
            memory.removeValue(forKey: key)
        }
    }
}
