import SwiftUI

@main
struct BookManagerApp: App {
    @State private var session = LibrarySession()

    var body: some Scene {
        WindowGroup {
            ContentView(session: session)
                .task {
                    // Skip auto-reopen under UI testing so tests start from a
                    // deterministic welcome screen.
                    if !CommandLine.arguments.contains("--ui-testing") {
                        await session.openMostRecentLibrary()
                    }
                }
        }
        .defaultSize(width: 1_100, height: 720)
        .commands {
            AppCommands(session: session)
        }
    }
}

/// The app's menu commands. `@FocusedValue` resolves against the focused view
/// (the browser publishes its search-field focus binding), so Cmd-F can drive
/// it from here without touching the session.
private struct AppCommands: Commands {
    let session: LibrarySession

    @FocusedValue(\.searchFocus) private var searchFocus: FocusState<Bool>.Binding?

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Create Library…") { session.present(.create) }
                .keyboardShortcut("n", modifiers: .command)
            Divider()
            Button("Close Library") { session.closeLibrary() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }
        CommandMenu("Library") {
            Button("Open Library…") { session.present(.open) }
                .keyboardShortcut("o", modifiers: .command)
            Divider()
            Menu("Open Recent") {
                if session.recentLibraries.isEmpty {
                    Text("No Recent Libraries")
                }
                ForEach(session.recentLibraries) { entry in
                    Button(entry.name) {
                        Task { await session.openLibrary(at: entry.url) }
                    }
                }
            }
            Divider()
            Button("Edit Metadata…") {
                if let id = session.selection.first,
                   let book = session.books.first(where: { $0.id == id }) {
                    session.inspectorBook = book
                }
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(session.selection.count != 1 || session.isLibraryUnavailable)
        }
        CommandGroup(after: .textEditing) {
            Button("Find") {
                searchFocus?.wrappedValue = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(searchFocus == nil)
        }
    }
}
