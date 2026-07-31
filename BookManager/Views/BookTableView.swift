import BookManagerCore
import SwiftUI

struct BookTableView: View {
    let books: [IndexedBook]
    @State private var selection = Set<IndexedBook.ID>()

    var body: some View {
        Table(books, selection: $selection) {
            TableColumn("Title", value: \.title)
            TableColumn("Authors") { book in
                Text(book.authors.joined(separator: ", "))
                    .foregroundStyle(.secondary)
            }
        }
        .overlay {
            if books.isEmpty {
                ContentUnavailableView(
                    "No Books",
                    systemImage: "books.vertical",
                    description: Text("Book import arrives in the next delivery slice.")
                )
            }
        }
    }
}
