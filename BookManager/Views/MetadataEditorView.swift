import BookManagerCore
import SwiftUI

/// Placeholder — real metadata editor arrives in Task 8.
struct MetadataEditorView: View {
    let book: IndexedBook
    let onSave: (BookEdit) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack {
            Text("Edit Metadata")
                .font(.headline)
            Text(book.title)
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancel", action: onCancel)
                Button("Save") {
                    onSave(BookEdit())
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .padding()
        .frame(minWidth: 420, minHeight: 300)
    }
}
