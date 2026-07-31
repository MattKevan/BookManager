import SwiftUI
import UniformTypeIdentifiers

struct LibraryWelcomeView: View {
    let createLibrary: () -> Void
    let openLibrary: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Book Manager", systemImage: "books.vertical")
        } description: {
            Text("Your books, in a library you control.")
        } actions: {
            HStack {
                Button("Create Library", action: createLibrary)
                    .buttonStyle(.borderedProminent)
                Button("Open Library", action: openLibrary)
            }
        }
    }
}
