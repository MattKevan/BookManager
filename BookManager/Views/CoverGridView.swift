import AppKit
import BookManagerCore
import SwiftUI

struct CoverGridView: View {
    @Bindable var session: LibrarySession

    private let columns = [
        GridItem(.adaptive(minimum: 120, maximum: 180), spacing: 16)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(session.books) { book in
                    CoverTile(book: book)
                        .environment(\.librarySession, session)
                }
            }
            .padding(16)
        }
        .overlay {
            if session.books.isEmpty {
                ContentUnavailableView(
                    "No Books",
                    systemImage: "books.vertical",
                    description: Text("Drag ebook files here or use Add Books to import.")
                )
            }
        }
    }
}

private struct CoverTile: View {
    let book: IndexedBook
    @Environment(\.librarySession) private var session
    @State private var image: NSImage?
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            cover
                .frame(height: 160)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary.opacity(0.4))
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            session?.selection.contains(book.id) ?? false ? Color.accentColor : .clear,
                            lineWidth: 3
                        )
                )
                .onTapGesture(count: 2) {
                    Task { await session?.open(id: book.id) }
                }
                .onTapGesture {
                    toggleSelection()
                }
                .onHover { hovering in
                    isHovering = hovering
                }
            Text(book.title)
                .font(.caption)
                .lineLimit(2)
                .foregroundStyle(.primary)
            Text(book.authors.joined(separator: ", "))
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovering ? Color.accentColor.opacity(0.08) : .clear)
        )
        .task {
            image = await ThumbnailCache.shared.thumbnail(for: book, repository: session?.repository)
        }
    }

    @ViewBuilder
    private var cover: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "book.closed")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
        }
    }

    private func toggleSelection() {
        guard let session else { return }
        if session.selection.contains(book.id) {
            session.selection.remove(book.id)
        } else {
            session.selection.insert(book.id)
        }
    }
}
