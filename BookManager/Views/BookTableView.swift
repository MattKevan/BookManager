import BookManagerCore
import Foundation
import SwiftUI

struct BookTableView: View {
    @Bindable var session: LibrarySession

    var body: some View {
        Table(session.books, selection: $session.selection) {
            TableColumn("Title") { book in
                Text(book.title)
                    .onDrag { dragProvider(for: book) }
            }
            TableColumn("Authors") { book in
                Text(book.authors.joined(separator: ", ")).foregroundStyle(.secondary)
            }
            TableColumn("Series") { book in
                Text(book.series ?? "")
            }
            TableColumn("Formats") { book in
                Text(book.formats.map(\.kind).joined(separator: ", "))
            }
            TableColumn("Tags") { book in
                Text(book.tags.joined(separator: ", "))
            }
            TableColumn("Rating") { book in
                if let rating = book.rating {
                    Text(String(repeating: "★", count: rating)).foregroundStyle(.orange)
                }
            }
        }
        .contextMenu(forSelectionType: IndexedBook.ID.self) { ids in
            Button("Edit Metadata") {
                session.metadataEditQueue = session.selectionBooks
            }
            .disabled(session.isLibraryUnavailable)
            Button("Show in Finder") {
                if let id = ids.first { Task { await session.reveal(id: id) } }
            }
            .disabled(session.isLibraryUnavailable)
            Divider()
            Button("Delete Book", role: .destructive) {
                session.requestDelete(ids: ids)
            }
        } primaryAction: { ids in
            // Double-click opens; the context menu intentionally has no
            // separate Open item (single-purpose actions only).
            if let id = ids.first { Task { await session.open(id: id) } }
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
        // Delete/Backspace trashes the selected rows (mirrors the grid's
        // onKeyPress delete). Cmd+Delete (Edit > Delete) is the menu path.
        .focusable()
        .onKeyPress(.delete) {
            guard !session.selection.isEmpty else { return .ignored }
            session.requestDelete(ids: session.selection)
            return .handled
        }
    }

    /// Makes a row draggable onto a sidebar device row (sends that book's
    /// primary format file to the device).
    private func dragProvider(for book: IndexedBook) -> NSItemProvider {
        guard let url = session.formatFileURL(for: book) else { return NSItemProvider() }
        return NSItemProvider(object: url as NSURL)
    }
}
