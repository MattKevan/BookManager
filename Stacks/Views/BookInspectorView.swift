import AppKit
import StacksCore
import SwiftUI

/// Right-side inspector: cover + metadata for the single selected book, plus a
/// collapsible Calibre source-data section rendered from the raw payload.
struct BookInspectorView: View {
    @Bindable var session: LibrarySession
    @State private var coverImage: NSImage?

    private var book: IndexedBook? {
        guard let id = session.selection.first else { return nil }
        return session.books.first { $0.id == id }
    }

    private var rawRows: [CalibreRawRow] {
        book?.rawMetadata.map(CalibreRawPresenter.rows(from:)) ?? []
    }

    var body: some View {
        Group {
            if let book {
                contents(book)
            } else {
                ContentUnavailableView("No Selection", systemImage: "sidebar.trailing")
            }
        }
        // Keyed on the cover hash so a metadata edit that replaces the cover
        // restarts the load (book.id is stable across edits). The state
        // assignment happens AFTER the cancellation guard: a cancelled task
        // must never overwrite a newer selection's cover.
        .task(id: book?.coverHash) {
            guard let book else {
                coverImage = nil
                return
            }
            let image = await ThumbnailCache.shared.thumbnail(for: book, repository: session.repository)
            guard !Task.isCancelled else { return }
            coverImage = image
        }
        .frame(minWidth: 280, idealWidth: 320)
    }

    private func contents(_ book: IndexedBook) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                cover(book)
                Group {
                    LabeledContent("Title", value: book.title)
                    LabeledContent("Authors", value: book.authors.joined(separator: ", "))
                    if let series = book.series {
                        LabeledContent("Series", value: book.seriesIndex.map { "\(series) #\($0)" } ?? series)
                    }
                    if let rating = book.rating {
                        LabeledContent("Rating", value: String(repeating: "★", count: rating))
                    }
                    if let publisher = book.publisher {
                        LabeledContent("Publisher", value: publisher)
                    }
                    if let date = book.publicationDate {
                        LabeledContent("Published", value: date.formatted(date: .abbreviated, time: .omitted))
                    }
                    LabeledContent("Added", value: (book.addedDate ?? .now).formatted(date: .abbreviated, time: .omitted))
                    if !book.languages.isEmpty {
                        LabeledContent("Languages", value: book.languages.joined(separator: ", "))
                    }
                    if !book.tags.isEmpty {
                        LabeledContent("Tags", value: book.tags.joined(separator: ", "))
                    }
                    if !book.identifiers.isEmpty {
                        LabeledContent("Identifiers", value: book.identifiers.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n"))
                    }
                    if !book.formats.isEmpty {
                        LabeledContent("Formats", value: book.formats.map { "\($0.kind) (\(Self.byteString($0.size)))" }.joined(separator: ", "))
                    }
                    if let comments = book.comments, !comments.isEmpty {
                        Text(comments)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .labelStyle(.titleAndIcon)

                if !rawRows.isEmpty {
                    DisclosureGroup("Calibre Source Data") {
                        ForEach(rawRows) { row in
                            LabeledContent(row.label, value: row.value)
                        }
                        .labelStyle(.titleAndIcon)
                    }
                }

                Button("Edit Metadata…") {
                    session.metadataEditQueue = [book]
                }
                .disabled(session.metadataEditQueue != nil)

                Button("Fetch Metadata…") {
                    Task { await session.fetchMetadata(for: book.id) }
                }
                .disabled(session.isFetchingMetadata)
                if let error = session.metadataLookupError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func cover(_ book: IndexedBook) -> some View {
        if let coverImage {
            Image(nsImage: coverImage)
                .resizable()
                .scaledToFit()
                .frame(height: 220)
                .frame(maxWidth: .infinity)
        } else {
            Image(systemName: "book.closed")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .frame(height: 220)
                .frame(maxWidth: .infinity)
        }
    }

    private static func byteString(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
