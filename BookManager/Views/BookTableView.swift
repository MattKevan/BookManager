import BookManagerCore
import SwiftUI

struct BookTableView: View {
    @Bindable var session: LibrarySession

    var body: some View {
        Table(session.books, selection: $session.selection) {
            TableColumn("Title", value: \.title)
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
            Button("Open") {
                if let id = ids.first { Task { await session.open(id: id) } }
            }
            Button("Reveal in Finder") {
                if let id = ids.first { Task { await session.reveal(id: id) } }
            }
            Button("Edit Metadata…") {
                if let id = ids.first, let book = session.books.first(where: { $0.id == id }) {
                    session.inspectorBook = book
                }
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                Task { await session.delete(ids: ids) }
            }
        } primaryAction: { ids in
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
    }
}
