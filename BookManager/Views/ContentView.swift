import BookManagerCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var session: LibrarySession
    @State private var pickerPurpose: PickerPurpose?

    private enum PickerPurpose: Identifiable {
        case create
        case open

        var id: Self { self }
    }

    var body: some View {
        Group {
            switch session.state {
            case .welcome:
                LibraryWelcomeView(
                    createLibrary: { pickerPurpose = .create },
                    openLibrary: { pickerPurpose = .open }
                )
            case .loading:
                ProgressView("Opening Library…")
                    .controlSize(.large)
            case let .loaded(name, books):
                NavigationSplitView {
                    List {
                        Label("All Books", systemImage: "books.vertical")
                    }
                    .listStyle(.sidebar)
                    .navigationTitle(name)
                } detail: {
                    BookTableView(books: books)
                        .searchable(text: $session.searchText, prompt: "Search books")
                }
                .toolbar {
                    ToolbarItem {
                        Button("Close Library", systemImage: "xmark.circle") {
                            session.closeLibrary()
                        }
                    }
                }
            case let .failed(message):
                ContentUnavailableView {
                    Label("Couldn’t Open Library", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Choose Another Library") {
                        session.closeLibrary()
                    }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 500)
        .fileImporter(
            isPresented: Binding(
                get: { pickerPurpose != nil },
                set: { if !$0 { pickerPurpose = nil } }
            ),
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            let purpose = pickerPurpose
            pickerPurpose = nil
            guard case let .success(urls) = result, let url = urls.first else { return }
            Task {
                switch purpose {
                case .create:
                    await session.createLibrary(at: url)
                case .open:
                    await session.openLibrary(at: url)
                case nil:
                    break
                }
            }
        }
    }
}
