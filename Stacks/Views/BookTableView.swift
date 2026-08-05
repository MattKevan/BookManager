import StacksCore
import Foundation
import SwiftUI

struct BookTableView<Browser: LibraryBrowser>: View {
    let browser: Browser

    var body: some View {
        Table(browser.books, selection: Binding(
            get: { browser.selection },
            set: { browser.selection = $0 }
        )) {
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
                browser.metadataEditQueue = browser.selectionBooks
            }
            .disabled(browser.isLibraryUnavailable)
            Button("Show in Finder") {
                if let id = ids.first { Task { await browser.reveal(id: id) } }
            }
            .disabled(browser.isLibraryUnavailable)
            Divider()
            Button("Delete Book", role: .destructive) {
                browser.requestDelete(ids: ids)
            }
        } primaryAction: { ids in
            // Double-click opens; the context menu intentionally has no
            // separate Open item (single-purpose actions only).
            if let id = ids.first { Task { await browser.open(id: id) } }
        }
        .overlay {
            if browser.books.isEmpty {
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
            guard !browser.selection.isEmpty else { return .ignored }
            browser.requestDelete(ids: browser.selection)
            return .handled
        }
    }

    /// Makes a row draggable onto a sidebar device row (sends that book's
    /// primary format file to the device).
    private func dragProvider(for book: IndexedBook) -> NSItemProvider {
        guard let url = browser.formatFileURL(for: book) else { return NSItemProvider() }
        return NSItemProvider(object: url as NSURL)
    }
}
